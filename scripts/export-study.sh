#!/usr/bin/env bash
# Analysis export, one directory per study. Run this ON THE VM.
#
#   scripts/export-study.sh                 every study
#   scripts/export-study.sh <study-uuid>    one study
#   EXPORT_DIR=/somewhere scripts/export-study.sh
#
# This is NOT anonymised, and the export says so in its own README
# ---------------------------------------------------------------
# Anonymised means irreversibly non-attributable, and therefore outside GDPR.
# Nothing here is that: participants are linked across trials by a stable code,
# which is the entire point - the primary analysis is a partial correlation
# between one participant's practice accuracy and the same participant's post-test.
# Remove the link and there is no study.
#
# What this does instead is the honest, defensible version: PSEUDONYMISATION WITH
# THE KEY HELD SEPARATELY.
#
#   - Every participant becomes P01, P02, ... in the export.
#   - The crosswalk from P-code back to participant_id is written to a SEPARATE
#     file, mode 600, OUTSIDE the export directory. It must not travel with it.
#   - consent_records.metadata is dropped entirely. It holds the IP address and
#     user-agent captured for the IRB audit trail; both are personal data and
#     neither is an analysis variable.
#   - auth.users is never touched. Email addresses stay in the auth schema, which
#     is the one place Enclosure A says they live.
#
# So the export is shareable with a collaborator, and re-identifiable by you alone,
# for as long as you hold the crosswalk. If a genuinely anonymous dataset is ever
# needed for publication, that is a further step (drop the crosswalk, and satisfy
# yourself that the event timings themselves are not re-identifying) and it should
# be a deliberate decision, not a side effect of a backup script.
set -euo pipefail

ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"
EXPORT_DIR="${EXPORT_DIR:-$HOME/exports}"
DB_CONTAINER="supabase-db"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${POSTGRES_DB:?POSTGRES_DB missing from env}"

docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER" || die "$DB_CONTAINER is not running"

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -tAc "$1" </dev/null; }
copy_csv() { docker exec -i "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" \
               -c "\\copy ($1) TO STDOUT WITH CSV HEADER" </dev/null; }

TARGET="${1:-}"
if [ -n "$TARGET" ]; then
  STUDIES="$(q "select id from public.studies where id = '$TARGET';")"
  [ -n "$STUDIES" ] || die "no study with id $TARGET"
else
  STUDIES="$(q "select id from public.studies order by created_at;")"
  [ -n "$STUDIES" ] || die "no studies in the database"
fi

stamp="$(date +%Y%m%dT%H%M%S)"
root="$EXPORT_DIR/$stamp"
mkdir -p "$root"; chmod 700 "$EXPORT_DIR" "$root"

for sid in $STUDIES; do
  name="$(q "select regexp_replace(name, '[^A-Za-z0-9]+', '-', 'g') from public.studies where id='$sid';")"
  out="$root/$name"; mkdir -p "$out"

  # The P-code is assigned per study, ordered by when the participant first consented,
  # so it is stable for a given database and reproducible from it.
  code_sql="
    select p.id as participant_id,
           'P' || lpad((row_number() over (order by c.granted_at, p.id))::text, 2, '0') as code
    from public.participants p
    join public.consent_records c on c.participant_id = p.id
    where c.study_id = '$sid'"

  copy_csv "
    with codes as ($code_sql)
    select c.code as participant, e.event_type, e.ts, e.item_id, e.task_id,
           e.session_id, e.app_version, e.platform, e.payload
    from public.events e join codes c on c.participant_id = e.participant_id
    where e.study_id = '$sid' order by c.code, e.ts" > "$out/events.csv"

  # metadata is deliberately absent: it carries ip and user_agent.
  copy_csv "
    with codes as ($code_sql)
    select c.code as participant, r.consent_version, r.consent_status,
           r.granted_at, r.withdrawn_at
    from public.consent_records r join codes c on c.participant_id = r.participant_id
    where r.study_id = '$sid' order by c.code" > "$out/consent.csv"

  copy_csv "
    with codes as ($code_sql)
    select c.code as participant, s.started_at, s.ended_at, s.app_version, s.device
    from public.sessions s join codes c on c.participant_id = s.participant_id
    where s.study_id = '$sid' order by c.code, s.started_at" > "$out/sessions.csv"

  # The crosswalk lives OUTSIDE the study directory so that copying the directory
  # cannot take it along by accident.
  copy_csv "$code_sql order by 2" > "$root/CROSSWALK-$name.csv"
  chmod 600 "$root/CROSSWALK-$name.csv"

  n_ev="$(( $(wc -l < "$out/events.csv") - 1 ))"
  n_pt="$(( $(wc -l < "$root/CROSSWALK-$name.csv") - 1 ))"
  log "$name: $n_pt participants, $n_ev events"

  cat > "$out/README.txt" <<TXT
Study:      $name
Study id:   $sid
Exported:   $(date -Is)

THIS IS PSEUDONYMOUS DATA, NOT ANONYMOUS DATA.

Participants appear as P01, P02, ... Those codes link every row in these files to
one person, which is what the analysis requires. The mapping from code back to the
platform's participant_id is in CROSSWALK-$name.csv, one directory up. That file is
mode 600 and is deliberately NOT inside this directory: copying this directory does
not copy the key.

While the crosswalk exists anywhere, this data is personal data under GDPR and the
subject rights in Enclosure A apply to it.

Removed on export:
  - consent_records.metadata (IP address, user-agent). Captured for the IRB audit
    trail, not an analysis variable.
  - auth.users. Email addresses never leave the auth schema.

Files:
  events.csv    one row per recorded event, ordered by participant then timestamp
  consent.csv   one row per consent record: version, status, granted, withdrawn
  sessions.csv  one row per session
TXT
done

chmod -R go-rwx "$root"
log "wrote $root"
