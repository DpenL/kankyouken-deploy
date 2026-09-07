#!/usr/bin/env bash
# Nightly pg_dump of the pilot database.
#
# Retention-compliant by construction: participants were told data is kept until
# 2026-12-31 (Enclosure A / Consent rev8). Backups are part of "the data", so this
# script REFUSES to run past that date rather than quietly building an archive the
# consent form does not cover. Change RETENTION_END only with an ethics amendment.
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
  die "today ($today) is past the approved retention end ($RETENTION_END).
       Backups must not outlive the consent. Run the deletion procedure instead."
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

log "pruning dumps older than ${KEEP_DAYS}d"
find "$OUT_DIR" -name 'kankyouken-*.sql.gz' -type f -mtime "+$KEEP_DAYS" -print -delete

cat <<NOTE

  Restore rehearsal (do this once, before the study — an untested backup is a rumour):
    gunzip -c $out | docker exec -i $DB_CONTAINER psql -U postgres -d ${POSTGRES_DB}_restoretest

NOTE