#!/usr/bin/env bash
# Apply the KanKyouKen database schema. Run this ON THE VM.
#
#   scripts/migrate.sh             apply everything not yet applied
#   scripts/migrate.sh --status    show what is applied and what is pending
#   MIGRATIONS=/some/dir scripts/migrate.sh
#
# Why this script exists
# ----------------------
# docker-compose.yml brings up Postgres, PostgREST, GoTrue, Kong and the edge
# runtime. Nothing in it creates the application schema. Without this step the
# database holds only the Supabase bootstrap: PostgREST logs
#
#     Schema cache loaded 0 Relations, 0 Relationships, 1 RPCs
#
# and every edge function returns 500 on its first table lookup, with no error
# in its own log, because the failure is a 404 from PostgREST that the function
# turns into Errors.internal(). That is not hypothetical — it is exactly how
# this stack came up the first time, and it cost an evening to find.
#
# Migrations arrive from the laptop via scripts/push.sh, which mirrors
# KanKyouKen/supabase/migrations/ into ~/deploy/migrations/. There is no
# Supabase CLI on the VM and no clone of the app repo.
#
# Idempotent: each file is applied once, inside its own transaction, and
# recorded in supabase_migrations.schema_migrations — the same table the
# Supabase CLI keeps, so a later `supabase db push` against this database
# agrees with what is already here instead of trying to replay it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # repo root
ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"
MIGRATIONS="${MIGRATIONS:-$HOME/deploy/migrations}"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE"
[ -d "$MIGRATIONS" ] || die "no migrations at $MIGRATIONS
       run scripts/push.sh from the laptop, or set MIGRATIONS=/path/to/migrations"

DC=(docker compose --env-file "$ENV_FILE" -f "$HERE/docker-compose.yml")

# Every psql call gets </dev/null. docker compose exec -T still wires the
# caller's stdin through, and psql will happily eat the rest of THIS script
# if you let it — which silently truncates the run after the first query.
psql_q() { "${DC[@]}" exec -T db psql -U postgres -d postgres -tAc "$1" < /dev/null; }

"${DC[@]}" ps --format '{{.Name}} {{.State}}' | grep -q '^supabase-db running' \
  || die "the db container is not running — scripts/deploy.sh first"

# --- bookkeeping + default privileges -------------------------------------------
#
# Supabase grants ALL on every new table in `public` to anon, authenticated and
# service_role, and leans on RLS to narrow that again. Hosted Supabase and
# `supabase start` install those default privileges as part of their bootstrap;
# this self-hosted image does not, for the `postgres` role that runs migrations.
#
# So this has to happen BEFORE any migration runs, not after:
#   - before: each table picks up the grant as it is created, and a migration's
#     own REVOKE (002 revokes INSERT on events from anon/authenticated) lands
#     afterwards and sticks.
#   - after: a blanket GRANT would undo every REVOKE the migrations performed.
#
# Without it, PostgREST connects fine and sees the tables but every request
# fails with "permission denied", which looks nothing like a missing grant.
#
# Re-running is harmless; a `docker compose down -v` wipes it, which is why it
# lives here rather than in a one-off command someone has to remember.
log "bookkeeping table and default privileges"
"${DC[@]}" exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version    text primary key,
  statements text[],
  name       text
);
alter default privileges for role postgres in schema public
  grant all on tables    to postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to postgres, anon, authenticated, service_role;
SQL

# --- status -----------------------------------------------------------------------
if [ "${1:-}" = "--status" ]; then
  log "applied"
  psql_q "select version || '  ' || coalesce(name,'') from supabase_migrations.schema_migrations order by version;" \
    | sed 's/^/    /'
  log "pending"
  pending=0
  for f in "$MIGRATIONS"/*.sql; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .sql)"; ver="${base%%_*}"
    if [ "$(psql_q "select 1 from supabase_migrations.schema_migrations where version='$ver';" | tr -d '[:space:]')" != "1" ]; then
      echo "    $base"; pending=$((pending+1))
    fi
  done
  [ "$pending" -eq 0 ] && echo "    (none)"
  exit 0
fi

# --- apply -------------------------------------------------------------------------
# Filename convention is the Supabase CLI's: <version>_<name>.sql, version being
# everything before the first underscore. Shell glob order is lexicographic,
# which for these timestamps is also chronological order.
applied=0
for f in "$MIGRATIONS"/*.sql; do
  [ -e "$f" ] || die "no .sql files in $MIGRATIONS"
  base="$(basename "$f" .sql)"
  ver="${base%%_*}"
  name="${base#*_}"
  [ "$ver" != "$base" ] || warn "$base has no <version>_<name> split; using the whole name as the version"

  if [ "$(psql_q "select 1 from supabase_migrations.schema_migrations where version='$ver';" | tr -d '[:space:]')" = "1" ]; then
    echo "    skip   $base"
    continue
  fi

  log "applying $base"
  # --single-transaction so a migration that fails halfway leaves nothing behind.
  "${DC[@]}" exec -T db psql -v ON_ERROR_STOP=1 --single-transaction -U postgres -d postgres < "$f" \
    || die "$base failed — nothing from it was committed. Fix the file and re-run."
  "${DC[@]}" exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres </dev/null \
    -c "insert into supabase_migrations.schema_migrations(version, name) values ('$ver', '$name') on conflict (version) do nothing;" >/dev/null
  applied=$((applied+1))
done

# --- tell PostgREST ------------------------------------------------------------------
# PostgREST caches the schema at connect time. It does listen on the `pgrst`
# channel, but only a NOTIFY makes it re-read; otherwise the tables exist and
# every request still 404s with PGRST205 until the container is restarted.
if [ "$applied" -gt 0 ]; then
  log "reloading the PostgREST schema cache"
  psql_q "notify pgrst, 'reload schema';" >/dev/null
fi

log "$applied applied. Schema now holds $(psql_q "select count(*) from information_schema.tables where table_schema='public';" | tr -d '[:space:]') tables in public."
