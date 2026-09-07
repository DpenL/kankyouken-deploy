#!/usr/bin/env bash
# Nightly pg_dump of the pilot database.
#
# Retention. Participants were told data is kept until 2026-12-31 (Enclosure A /
# Consent rev8). The approved TU Graz application adds the carve-out verbatim:
# "Data are deleted by January 2027 unless the work is published or under review."
# So a pending publication is already covered and does NOT need an amendment.
# Past the date this script stops and asks for an explicit, recorded reason rather
# than either running silently or dying on a legitimate extension - a backup that
# refuses to run is also a way to lose data.
#
#   RETENTION_OVERRIDE="under review at <venue>, submitted <date>"  scripts/backup.sh
#
# Off-machine copies. The VM is decommissioned in January 2027 and a backup that
# only exists on the machine it backs up is not a backup. Set BACKUP_MIRROR to a
# TUM-side rsync destination and every dump is copied there immediately:
#
#   BACKUP_MIRROR="stiftl@<tum-host>:kankyouken-backups/"  scripts/backup.sh
#
# Leave it unset only while testing; the script says so loudly every run.
set -euo pipefail

ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"
OUT_DIR="${BACKUP_DIR:-$HOME/backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"
RETENTION_END="2026-12-31"
DB_CONTAINER="supabase-db"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

today="$(date +%F)"
if [[ "$today" > "$RETENTION_END" ]]; then
  if [ -z "${RETENTION_OVERRIDE:-}" ]; then
    die "today ($today) is past the approved retention end ($RETENTION_END).
       The approved application allows retention past this date only while the work
       is published or under review. If that applies, re-run with the reason recorded:
         RETENTION_OVERRIDE=\"under review at <venue>, submitted <date>\" $0
       If it does not, run the deletion procedure instead."
  fi
  log "RETENTION OVERRIDE: $RETENTION_OVERRIDE"
  printf '%s\t%s\n' "$(date -Is)" "$RETENTION_OVERRIDE" >> "${OUT_DIR}/RETENTION-OVERRIDES.log"
fi

[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${POSTGRES_DB:?POSTGRES_DB missing from env}"

docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER" || die "$DB_CONTAINER is not running"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
stamp="$(date +%Y%m%dT%H%M%S)"
out="$OUT_DIR/kankyouken-${stamp}.sql.gz"

log "dumping $POSTGRES_DB -> $out"
# PGPASSWORD is already set inside the container; nothing secret crosses the host.
docker exec "$DB_CONTAINER" pg_dump -U postgres -d "$POSTGRES_DB" --clean --if-exists \
  | gzip -9 > "$out"
chmod 600 "$out"

size="$(du -h "$out" | cut -f1)"
[ -s "$out" ] || die "dump is empty — investigate before trusting this backup"
log "wrote $size"

if [ -n "${BACKUP_MIRROR:-}" ]; then
  log "mirroring to $BACKUP_MIRROR"
  rsync -a --chmod=F600 "$out" "$BACKUP_MIRROR" \
    || die "mirror FAILED - the only copy of this dump is on the machine it backs up"
  log "mirrored"
else
  printf '\033[33mWARNING:\033[0m BACKUP_MIRROR is unset. This dump exists only on the VM,\n'
  printf '         which is decommissioned in January 2027. That is not a backup.\n'
fi

log "pruning dumps older than ${KEEP_DAYS}d"
find "$OUT_DIR" -name 'kankyouken-*.sql.gz' -type f -mtime "+$KEEP_DAYS" -print -delete

cat <<NOTE

  Restore rehearsal (do this once, before the study — an untested backup is a rumour):
    gunzip -c $out | docker exec -i $DB_CONTAINER psql -U postgres -d ${POSTGRES_DB}_restoretest

NOTE