#!/usr/bin/env bash
# Generate www/*/config.json from the database. Run this ON THE VM.
#
#   scripts/seed-config.sh                    look the studies up by name
#   PRESCREEN_STUDY="Prescreening" PILOT_STUDY="Pilot" scripts/seed-config.sh
#
# Why this exists
# ---------------
# The two client configs were the one part of this deployment that existed only as
# hand-typed files on the VM. Not in a repo (they are excluded from every push on
# purpose - the locally-built copy says mode "local" and syncing it would take the
# study offline while looking healthy), and not in a database dump either. So a
# rebuild reconstructed the whole system and then quietly served two clients that
# could not start.
#
# The study ids are already in the database. Reading them back is strictly better
# than copying UUIDs out of a URL by hand: it cannot transpose a character, and it
# cannot put the pilot id where the prescreening id belongs - which would send
# consent to the wrong study with nothing complaining.
#
# The anon key is read from ~/deploy/.env and written straight to the file. It is
# never printed; the summary at the end shows a placeholder.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"
WWW="${WWW:-$HERE/www}"
DB_CONTAINER="supabase-db"

PRESCREEN_STUDY="${PRESCREEN_STUDY:-Prescreening}"
PILOT_STUDY="${PILOT_STUDY:-Pilot}"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${ANON_KEY:?ANON_KEY missing from env}"
: "${SUPABASE_PUBLIC_URL:?SUPABASE_PUBLIC_URL missing from env}"
: "${POSTGRES_DB:?POSTGRES_DB missing from env}"

docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER" || die "$DB_CONTAINER is not running"
[ -d "$WWW/signup" ] || die "no $WWW/signup - run scripts/push.sh from the laptop first"
[ -d "$WWW/study" ]  || die "no $WWW/study - run scripts/push.sh from the laptop first"

study_id() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -tAc \
    "select id from public.studies where name = '$1' order by created_at limit 1;" </dev/null \
    | tr -d '[:space:]'
}

PRESCREEN_ID="$(study_id "$PRESCREEN_STUDY")"
PILOT_ID="$(study_id "$PILOT_STUDY")"

[ -n "$PRESCREEN_ID" ] || die "no study named \"$PRESCREEN_STUDY\".
       Create it in the dashboard, or set PRESCREEN_STUDY to the name you used."
[ -n "$PILOT_ID" ] || die "no study named \"$PILOT_STUDY\".
       Create it in the dashboard, or set PILOT_STUDY to the name you used."
[ "$PRESCREEN_ID" != "$PILOT_ID" ] || die "both names resolved to the same study ($PRESCREEN_ID)"

# signup carries BOTH ids. One act of consent writes a record against each study,
# so the client needs to know where the second one goes. study carries only the pilot.
cat > "$WWW/signup/config.json" <<JSON
{
  "mode": "remote",
  "apiBase": "$SUPABASE_PUBLIC_URL",
  "studyId": "$PRESCREEN_ID",
  "pilotStudyId": "$PILOT_ID",
  "anonKey": "$ANON_KEY"
}
JSON

cat > "$WWW/study/config.json" <<JSON
{
  "mode": "remote",
  "apiBase": "$SUPABASE_PUBLIC_URL",
  "studyId": "$PILOT_ID",
  "anonKey": "$ANON_KEY"
}
JSON

chmod 640 "$WWW/signup/config.json" "$WWW/study/config.json"

log "wrote both configs"
printf '    signup  studyId=%s  pilotStudyId=%s  anonKey=<%d chars>\n' \
  "$PRESCREEN_ID" "$PILOT_ID" "${#ANON_KEY}"
printf '    study   studyId=%s                                anonKey=<%d chars>\n' \
  "$PILOT_ID" "${#ANON_KEY}"

# Caddy serves these with Cache-Control: no-store, so the change is live on the next
# load. No restart, no cache to bust.
log "verifying over TLS"
for p in /signup/config.json /study/config.json; do
  code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' \
    --resolve "${SUPABASE_PUBLIC_URL#https://}:443:127.0.0.1" \
    "$SUPABASE_PUBLIC_URL$p" 2>/dev/null || echo 000)"
  printf '    %-22s %s\n' "$p" "$code"
  [ "$code" = "200" ] || die "$p is not being served - is caddy up?"
done
