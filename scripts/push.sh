#!/usr/bin/env bash
# Run this ON THE LAPTOP (from WSL — it needs rsync). Builds both clients, copies
# everything the VM needs, and records exactly which commits were deployed.
#
#   scripts/push.sh              build + push
#   scripts/push.sh --no-build   push what is already in dist/
#   DRY=1 scripts/push.sh        show what rsync would do, change nothing
#
# There is no git clone on the VM and no deploy key: this is the whole delivery path.
set -euo pipefail

VM="${VM:-stiftl@gr-stiftl.ndx.cit.tum.de}"
REMOTE="${REMOTE:-deploy}"   # relative: rsync and ssh both resolve it against ~ on the VM
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # kankyouken-deploy
PROJECTS="$(cd "$HERE/.." && pwd)"                        # ~/projects
ENROL="$PROJECTS/EnrolmentApp"
FLASH="$PROJECTS/FlashCardApp"
PLATFORM="$PROJECTS/KanKyouKen"
# --chmod is not cosmetic. The source lives on /mnt/c, and WSL reports every file
# there as 0777; rsync -a preserves that faithfully, so without this the compose
# file, the Caddyfile and every script land on the VM world-writable. That machine
# will hold participant data.
RSYNC=(rsync -az --info=stats1 --chmod=D750,F640)
[ -n "${DRY:-}" ] && RSYNC+=(--dry-run)

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v rsync >/dev/null || die "rsync not found — run this from WSL, not PowerShell"
for p in "$ENROL" "$FLASH" "$PLATFORM"; do [ -d "$p" ] || die "missing repo: $p"; done

sha() { git -C "$1" rev-parse --short HEAD 2>/dev/null || echo "uncommitted"; }
dirty() { [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ] && echo " (DIRTY)" || echo ""; }

# --- build ---------------------------------------------------------------------
if [ "${1:-}" != "--no-build" ]; then
  log "building EnrolmentApp for /signup/"
  (cd "$ENROL" && VITE_BASE_PATH=/signup/ npm run build >/dev/null)
  log "building FlashCardApp for /study/"
  (cd "$FLASH" && VITE_BASE_PATH=/study/ npm run build >/dev/null)
fi
[ -f "$ENROL/dist/index.html" ] || die "EnrolmentApp/dist is empty — drop --no-build"
[ -f "$FLASH/dist/index.html" ] || die "FlashCardApp/dist is empty — drop --no-build"

# --- provenance ----------------------------------------------------------------
# This is what we get instead of submodules: the exact commits behind what is live.
cat > "$HERE/DEPLOYED.txt" <<EOF
Deployed $(date -u +%Y-%m-%dT%H:%M:%SZ) from $(hostname)

kankyouken-deploy  $(sha "$HERE")$(dirty "$HERE")
EnrolmentApp       $(sha "$ENROL")$(dirty "$ENROL")
FlashCardApp       $(sha "$FLASH")$(dirty "$FLASH")
KanKyouKen         $(sha "$PLATFORM")$(dirty "$PLATFORM")

A DIRTY marker means that repo had uncommitted changes when this was pushed,
so the SHA does not fully describe what is running. Fix before recruiting.
EOF
log "provenance:"; sed 's/^/    /' "$HERE/DEPLOYED.txt"

# --- push ----------------------------------------------------------------------
# --delete keeps the VM honest, but volumes/ holds the fetched upstream tree and the
# postgres data directory. Deleting that would be a very bad afternoon.
log "ensuring $REMOTE/ exists on the VM"
ssh "$VM" "mkdir -p '$REMOTE'" || die "cannot create $REMOTE on $VM"

log "config, scripts, static pages"
"${RSYNC[@]}" --delete \
  --exclude '.git/' --exclude 'volumes/' \
  --exclude 'www/signup/' --exclude 'www/study/' \
  "$HERE/" "$VM:$REMOTE/kankyouken-deploy/"

log "client bundles"
# config.json is EXCLUDED from both syncs, deliberately.
#
# Each client ships a dist/config.json built from its local .env, and locally that
# says mode "local" with an empty apiBase. The VM's copy is the live one - it points
# at the real backend and is edited there. Without this exclude, --delete would
# overwrite the live config with the local one on every push, and both clients would
# quietly fall back to local mode: the flow still works, the participant sees nothing
# wrong, and not one event reaches the server. Caddy already serves these two paths
# with Cache-Control: no-store so an edit on the VM takes effect immediately.
CFG_EXCLUDE=(--exclude 'config.json')

"${RSYNC[@]}" "${CFG_EXCLUDE[@]}" --delete "$ENROL/dist/" "$VM:$REMOTE/kankyouken-deploy/www/signup/"
"${RSYNC[@]}" "${CFG_EXCLUDE[@]}" --delete "$FLASH/dist/" "$VM:$REMOTE/kankyouken-deploy/www/study/"

# First deploy has no config on the VM yet, and an excluded file is not a missing
# file the script would otherwise notice. Say so rather than leaving a 404.
for path in signup study; do
  if ! ssh "$VM" "test -f $REMOTE/kankyouken-deploy/www/$path/config.json" 2>/dev/null; then
    printf '\033[33mWARNING:\033[0m www/%s/config.json does not exist on the VM.\n' "$path"
    printf '         The client cannot start without it. Seed it once:\n'
    printf '           ssh %s\n' "$VM"
    printf '           cat > %s/kankyouken-deploy/www/%s/config.json <<JSON\n' "$REMOTE" "$path"
    printf '           {"mode":"remote","apiBase":"https://gr-stiftl.ndx.cit.tum.de","studyId":"<uuid>","anonKey":"<jwt>"}\n'
    printf '           JSON\n'
  fi
done

# The scripts have to be executable, and F640 just took that away.
ssh "$VM" "chmod 750 '$REMOTE'/kankyouken-deploy/scripts/*.sh 2>/dev/null; chmod 750 '$REMOTE' '$REMOTE'/kankyouken-deploy" \
  || die "could not fix permissions on $VM"

log "edge function sources"
"${RSYNC[@]}" --delete "$PLATFORM/supabase/functions/" "$VM:$REMOTE/functions-src/"

cat <<NEXT

  Pushed. On the VM:

    cd ~/deploy/kankyouken-deploy
    KANKYOUKEN_FUNCTIONS=~/deploy/functions-src scripts/deploy.sh

  Static-only (no Supabase yet) — just reload the proxy:

    docker compose exec web nginx -s reload     # while nginx still owns :443

NEXT