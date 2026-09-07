#!/usr/bin/env bash
# Deploy the KN-202 pilot stack on the VM.
#
#   1. use the config already copied here by scripts/push.sh (no clone on the VM)
#   2. ensure the pinned upstream support tree exists
#   3. sync edge functions from the app repo into the runtime mount
#   4. docker compose up -d, then wait for health
#
# Idempotent. Safe to re-run. Never writes secrets and never echoes .env contents.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # repo root
ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"
# Functions arrive from the laptop via scripts/push.sh (there is no clone on the VM).
# KANKYOUKEN_FUNCTIONS  -> a directory of function dirs (what push.sh delivers)
# KANKYOUKEN_REPO       -> a full checkout, if you ever do clone it here
FN_SRC="${KANKYOUKEN_FUNCTIONS:-${KANKYOUKEN_REPO:+$KANKYOUKEN_REPO/supabase/functions}}"
FN_SRC="${FN_SRC:-$HOME/deploy/functions-src}"
FN_DST="$HERE/volumes/functions"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE (copy .env.example, fill it in, chmod 600)"
if [ "$(stat -c '%a' "$ENV_FILE")" != "600" ]; then
  die "$ENV_FILE must be mode 600 (currently $(stat -c '%a' "$ENV_FILE"))"
fi

# 1. source ---------------------------------------------------------------------
# Normal path: the laptop pushed here with scripts/push.sh, so there is nothing to
# pull. The git branch only fires if you chose to clone on the VM instead.
if [ -d "$HERE/.git" ]; then
  log "git checkout detected, pulling"
  git -C "$HERE" pull --ff-only
else
  log "copied tree (no .git) ? using what push.sh delivered"
fi

# 2. upstream support tree ----------------------------------------------------
# The stack will not start without volumes/api, volumes/db and volumes/functions/main.
# See UPSTREAM.md for why these are fetched at a pin rather than vendored.
if [ ! -f "$HERE/volumes/api/kong.yml" ] || [ ! -f "$HERE/volumes/functions/main/index.ts" ]; then
  log "fetching pinned upstream volumes"
  "$HERE/scripts/fetch-upstream-volumes.sh"
else
  log "upstream volumes present"
fi

# 3. sync our edge functions --------------------------------------------------
# Self-hosted edge-runtime serves whatever is mounted; there is no `functions deploy`.
# We copy each function beside the upstream `main` router, which must survive.
[ -d "$FN_SRC" ] || die "edge functions not found at $FN_SRC
       run scripts/push.sh from the laptop, or set KANKYOUKEN_FUNCTIONS=/path/to/functions"

log "syncing edge functions from $FN_SRC"
mkdir -p "$FN_DST"
for dir in "$FN_SRC"/*/; do
  name="$(basename "$dir")"
  [ "$name" = "main" ] && { echo "    skip  $name (upstream router)"; continue; }
  rm -rf "${FN_DST:?}/$name"
  cp -r "$dir" "$FN_DST/$name"
  echo "    sync  $name"
done
[ -f "$FN_DST/main/index.ts" ] || die "upstream main router missing from $FN_DST — re-run fetch-upstream-volumes.sh"

# 4. bring it up --------------------------------------------------------------
log "docker compose up -d"
docker compose --env-file "$ENV_FILE" -f "$HERE/docker-compose.yml" up -d --remove-orphans

log "waiting for health"
deadline=$(( $(date +%s) + 180 ))
while :; do
  unhealthy="$(docker compose --env-file "$ENV_FILE" -f "$HERE/docker-compose.yml" ps \
                 --format '{{.Name}} {{.Health}}' | awk '$2!="healthy" && $2!="" {print $1}')"
  [ -z "$unhealthy" ] && { log "all healthy"; break; }
  [ "$(date +%s)" -ge "$deadline" ] && die "still unhealthy after 180s: $unhealthy"
  sleep 5
done

# 5. schema ---------------------------------------------------------------------
# Compose starts Postgres; it does not create the application schema. Skipping
# this leaves a database with nothing in `public`, which surfaces much later and
# much less legibly as a 500 from the first edge function anyone calls. Runs
# after the health wait because it needs the db container up, and it is
# idempotent, so re-running deploy.sh is still free.
log "applying database migrations"
ENV_FILE="$ENV_FILE" "$HERE/scripts/migrate.sh"

log "done. smoke test:  scripts/smoke-test.sh"