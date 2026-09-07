#!/usr/bin/env bash
# Fetch the pinned Supabase support tree (kong config, db init SQL, functions router)
# into deploy/volumes/. Idempotent. Run once on the VM before the first `up`.
#
# The pin lives in UPSTREAM.md — keep PIN below in sync with it.
set -euo pipefail

PIN="9cf6ae1f6779efcef70dcc94d64e5d8e1cee8304"
REPO="supabase/supabase"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HERE/volumes"

echo "Fetching supabase docker/volumes @ ${PIN:0:7} into $DEST"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Sparse-checkout just docker/volumes to avoid cloning the whole monorepo.
git -C "$tmp" init -q
git -C "$tmp" remote add origin "https://github.com/$REPO.git"
git -C "$tmp" config core.sparseCheckout true
echo "docker/volumes/*" > "$tmp/.git/info/sparse-checkout"
git -C "$tmp" fetch -q --depth 1 origin "$PIN"
git -C "$tmp" checkout -q FETCH_HEAD

mkdir -p "$DEST"
# Copy everything EXCEPT the live postgres data dir (never overwrite that).
rsync -a --exclude 'db/data' "$tmp/docker/volumes/" "$DEST/"
mkdir -p "$DEST/db/data"

echo "Done. Support tree in place:"
find "$DEST" -maxdepth 2 -type f | sed "s|$DEST/|  volumes/|"
