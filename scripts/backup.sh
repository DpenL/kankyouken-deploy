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
#
# Deliberately NOT --clean --if-exists. That combination emits, among 231 DROPs,
# 37 of this shape:
#
#   DROP POLICY IF EXISTS study_script_config_write ON public.study_script_config;
#
# IF EXISTS guards the POLICY, not the TABLE. Restore that into an empty database -
# a new machine, a fresh volume, precisely the case a backup exists for - and
# Postgres raises `relation "public.study_script_config" does not exist` and the
# restore stops on statement 23 of 231. Caught by scripts/restore.sh on the first
# rehearsal, 2026-09-08, which is the entire argument for rehearsing.
#
# A plain dump restores into an empty database cleanly. Rolling back a database
# that still has objects in it means giving it an empty one first:
#   docker compose --env-file ~/deploy/.env down -v   # destroys the volume
#   docker compose --env-file ~/deploy/.env up -d db
#   scripts/restore.sh <dump> --into-live
docker exec "$DB_CONTAINER" pg_dump -U postgres -d "$POSTGRES_DB" \
  | gzip -9 > "$out"
chmod 600 "$out"

size="$(du -h "$out" | cut -f1)"
[ -s "$out" ] || die "dump is empty — investigate before trusting this backup"
log "wrote $size"

# Analysis export alongside the dump. The dump is for restoring a machine; the export
# is the pseudonymous, analysis-shaped copy - and it is the one that survives being
# looked at by someone who is not you. Non-fatal: a failed export must not cost you
# the dump.
if [ -x "$(dirname "$0")/export-study.sh" ]; then
  log "exporting study data (pseudonymous; the crosswalk stays separate)"
  "$(dirname "$0")/export-study.sh" 2>&1 | sed 's/^/    /' \
    || printf '\033[33mWARNING:\033[0m export failed; the dump above is unaffected.\n'
fi

if [ -n "${BACKUP_MIRROR:-}" ]; then
  log "mirroring to $BACKUP_MIRROR"
  rsync -a --chmod=F600 "$out" "$BACKUP_MIRROR" \
    || die "mirror FAILED - the only copy of this dump is on the machine it backs up"
  log "mirrored"
else
  # Stopgap while BACKUP_MIRROR is undecided. A second directory on the same disk
  # survives an accidental rm on ~/backups and survives the 14-day prune below -
  # and nothing else. It does not survive the disk, the VM, or January 2027. It is
  # a seatbelt, not a backup, and the warning stays until a real mirror is set.
  archive="${BACKUP_ARCHIVE:-$HOME/backup-archive}"
  mkdir -p "$archive"; chmod 700 "$archive"
  cp -p "$out" "$archive/" && log "second local copy: $archive/$(basename "$out")"
  printf '\033[33mWARNING:\033[0m BACKUP_MIRROR is unset. Both copies are on this VM,\n'
  printf '         which is decommissioned in January 2027. That is not yet a backup.\n'
fi

log "pruning dumps older than ${KEEP_DAYS}d"
# Only OUT_DIR is pruned. The archive copy is deliberately left alone: the point of
# a second copy is to outlive a mistake made in the first.
find "$OUT_DIR" -name 'kankyouken-*.sql.gz' -type f -mtime "+$KEEP_DAYS" -print -delete

cat <<NOTE

  Restore rehearsal (do this once, before the study — an untested backup is a rumour):
    gunzip -c $out | docker exec -i $DB_CONTAINER psql -U postgres -d ${POSTGRES_DB}_restoretest

NOTE