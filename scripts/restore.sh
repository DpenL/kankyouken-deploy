#!/usr/bin/env bash
# Restore a backup. Run this ON THE VM.
#
#   scripts/restore.sh                       rehearse: newest dump into a scratch DB, compare, drop
#   scripts/restore.sh --keep                rehearse but leave the scratch DB for inspection
#   scripts/restore.sh <dump.sql.gz>         rehearse a specific dump
#   scripts/restore.sh <dump> --into-live    the real thing. Guarded, see below.
#
# Why the default is a rehearsal
# ------------------------------
# An untested backup is a rumour. This exists so the rehearsal is one command
# rather than a paragraph in a README that nobody runs until the day it matters.
# It restores into a scratch database, counts the rows that matter, prints them
# beside the live counts, and drops the scratch database again.
#
# What a dump actually contains
# -----------------------------
# backup.sh runs a plain `pg_dump -d $POSTGRES_DB` as supabase_admin, so the
# dump carries EVERY schema: public (participants, consent_records, events),
# auth (the researcher account), and supabase_migrations (which migrations had run).
# That last one matters more than it looks: restoring an old dump into a fresh
# stack and then running scripts/migrate.sh applies exactly the migrations the
# dump had not seen. Old data, new schema, nothing lost. That is the answer to
# "what if we need to change the schema mid-study".
#
# What a dump does NOT contain
# ----------------------------
#   ~/deploy/.env          secrets, deliberately never in a dump or a repo
#   www/*/config.json      regenerate with scripts/seed-config.sh AFTER restoring
#
# Restoring into the live database
# --------------------------------
# The dump is a plain one (backup.sh explains why it is not --clean), so it ADDS
# objects rather than replacing them, and therefore needs an EMPTY database - which
# in practice means a fresh volume:
#
#   docker compose --env-file ~/deploy/.env down -v      # destroys the data volume
#   docker compose --env-file ~/deploy/.env up -d db
#   CONFIRM_DESTROY=yes scripts/restore.sh <dump> --into-live
#   docker compose --env-file ~/deploy/.env up -d
#   scripts/migrate.sh          # any migrations newer than the dump
#   scripts/seed-config.sh      # www/*/config.json, which no dump carries
#
# --into-live refuses if the target already holds participants, unless
# CONFIRM_DESTROY=yes: restoring on top of live rows fails half way through on
# duplicate keys and leaves the database in a state nobody planned.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
DB_CONTAINER="supabase-db"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${POSTGRES_DB:?POSTGRES_DB missing from env}"

docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER" || die "$DB_CONTAINER is not running"

DUMP=""; MODE="rehearse"; KEEP=""
for arg in "$@"; do
  case "$arg" in
    --into-live) MODE="live" ;;
    --keep)      KEEP=1 ;;
    -*)          die "unknown option: $arg" ;;
    *)           DUMP="$arg" ;;
  esac
done

if [ -z "$DUMP" ]; then
  DUMP="$(find "$BACKUP_DIR" -name 'kankyouken-*.sql.gz' -type f -print0 2>/dev/null \
          | xargs -0 ls -t 2>/dev/null | head -1)"
  [ -n "$DUMP" ] || die "no dumps in $BACKUP_DIR — run scripts/backup.sh first"
  log "newest dump: $DUMP"
fi
[ -f "$DUMP" ] || die "no such dump: $DUMP"
[ -s "$DUMP" ] || die "$DUMP is empty"

# Reads go as postgres; writes that recreate Supabase-owned schemas must go as
# supabase_admin, the only superuser in this image.
psql_db() { docker exec -i "$DB_CONTAINER" psql -U postgres -d "$1" -tAc "$2" </dev/null; }
psql_admin() { docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d "$1" -tAc "$2" </dev/null; }

# The tables worth counting: everything a participant produces, plus the setup rows
# that a rebuild would otherwise need re-entering by hand.
counts() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d "$1" -tAc "
    select 'auth_users '||count(*) from auth.users
    union all select 'projects '||count(*) from public.projects
    union all select 'studies '||count(*) from public.studies
    union all select 'event_schemas '||count(*) from public.event_schemas
    union all select 'participants '||count(*) from public.participants
    union all select 'consent_records '||count(*) from public.consent_records
    union all select 'events '||count(*) from public.events
    union all select 'migrations '||count(*) from supabase_migrations.schema_migrations;
  " </dev/null 2>/dev/null || echo "  (could not read $1)"
}

# --- live -------------------------------------------------------------------------
if [ "$MODE" = "live" ]; then
  live_participants="$(psql_db "$POSTGRES_DB" "select count(*) from public.participants;" | tr -d '[:space:]')"
  if [ "${live_participants:-0}" != "0" ] && [ "${CONFIRM_DESTROY:-}" != "yes" ]; then
    die "the live database holds $live_participants participant(s).
       A plain dump restored on top of them fails on duplicate keys part way
       through, which is worse than not starting. Give it an empty database
       first (see the header), or if you are certain:
         CONFIRM_DESTROY=yes $0 $DUMP --into-live"
  fi
  warn "restoring into the LIVE database ($POSTGRES_DB)"
  log "before:"; counts "$POSTGRES_DB" | sed 's/^/    /'
  gunzip -c "$DUMP" | docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U supabase_admin -d "$POSTGRES_DB" >/dev/null
  log "after:";  counts "$POSTGRES_DB" | sed 's/^/    /'
  psql_db "$POSTGRES_DB" "notify pgrst, 'reload schema';" >/dev/null
  cat <<NEXT

  Restored. Two things the dump could not carry:
    1. scripts/seed-config.sh          regenerate www/*/config.json from the restored studies
    2. scripts/migrate.sh              apply any migrations newer than the dump
NEXT
  exit 0
fi

# --- rehearsal --------------------------------------------------------------------
SCRATCH="${POSTGRES_DB}_restoretest_$(date +%H%M%S)"
log "rehearsing into scratch database $SCRATCH"
psql_admin postgres "CREATE DATABASE \"$SCRATCH\";" >/dev/null

cleanup() {
  if [ -z "$KEEP" ]; then
    docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres \
      -c "DROP DATABASE IF EXISTS \"$SCRATCH\" WITH (FORCE);" </dev/null >/dev/null 2>&1 || true
  else
    log "kept: $SCRATCH  (drop it with: docker exec -i $DB_CONTAINER psql -U postgres -d postgres -c 'DROP DATABASE \"$SCRATCH\" WITH (FORCE);')"
  fi
}
trap cleanup EXIT

if ! gunzip -c "$DUMP" | docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U supabase_admin -d "$SCRATCH" >/tmp/restore-rehearsal.log 2>&1; then
  tail -20 /tmp/restore-rehearsal.log >&2
  die "restore FAILED. Full log: /tmp/restore-rehearsal.log
       This is the point of rehearsing. Fix it now, not during the study."
fi

echo
printf '  %-22s %-14s %s\n' "" "LIVE" "RESTORED"
paste <(counts "$POSTGRES_DB") <(counts "$SCRATCH") \
  | awk '{ n=$1; l=$2; r=$4; printf "  %-22s %-14s %s%s\n", n, l, r, (l==r ? "" : "   <-- DIFFERS") }'
echo
log "restore completed without error. Differences above are expected only if the"
log "dump predates rows added since; anything else is worth understanding now."
