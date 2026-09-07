# Upstream provenance & the support tree

`docker-compose.yml` here is a **pruned copy** of the official self-hosted Supabase
compose. Pinned to:

    repo:   github.com/supabase/supabase
    path:   docker/
    commit: 9cf6ae1f6779efcef70dcc94d64e5d8e1cee8304   (master, 2026-07-08)

Image versions this pin implies (keep these in sync if you re-pin):
kong 3.9.1 · gotrue v2.189.0 · postgrest v14.12 · realtime v2.102.3 ·
edge-runtime v1.74.0 · postgres 17.6.1.136.

## Why we don't run the upstream compose directly

The stack won't start without a support tree that lives in `docker/volumes/` upstream,
NOT in our compose file:

- `volumes/api/kong.yml` + `kong-entrypoint.sh` — Kong's declarative routes for
  `/auth`, `/rest`, `/realtime`, `/functions`.
- `volumes/db/roles.sql` — creates `authenticator`, `supabase_auth_admin`,
  `supabase_admin`, `supabase_storage_admin`. **auth/rest/realtime log in as these
  roles**; without this init the stack authenticates nothing.
- `volumes/db/{realtime,webhooks,jwt,_supabase,logs,pooler}.sql` — schema init the
  postgres image runs on first boot.
- `volumes/functions/main/` — the edge-runtime router.

We keep these **pinned-fetched, not committed**, to avoid vendoring upstream code
into the KB. `scripts/fetch-upstream-volumes.sh` pulls exactly the pin above into
`deploy/volumes/` on the VM. The pin (this file) is the version-controlled part;
the fetched tree is git-ignored.

> If the VM must be able to redeploy with zero network access to GitHub, switch to
> vendoring: run the fetch once, then `git add -f deploy/volumes/` (minus
> `volumes/db/data`). Trade-off: bigger KB, upstream code under its own licence.

## Prune diff (what we changed vs the pinned upstream compose)

Removed services: `studio`, `storage`, `imgproxy`, `meta`, `supavisor`.
(This pin has no `analytics`/`vector` services — already gone upstream.)
Edits to surviving services, each marked `# PILOT:` in the compose:

- `kong`: dropped `depends_on: studio`; removed host port publishing (8000/8443).
- added `caddy` service for TLS (upstream ships this as a separate
  `docker-compose.caddy.yml` overlay; we inlined a minimal version).

To bump the pin: fetch the new upstream compose, diff against this pin, re-apply
only the `# PILOT:` edits, update the commit + image versions above.

## Edge functions (the one repo-specific wiring still open)

The KN-202 functions live in the app repo at `KanKyouKen/supabase/functions/<name>/`.
Self-hosted edge-runtime doesn't use `supabase functions deploy`; it runs whatever is
mounted at `./volumes/functions`, dispatching through `volumes/functions/main/`.
`scripts/deploy.sh` syncs the repo's functions into that mount alongside the upstream
`main` router. The router's import map / per-function routing for our specific
function set still needs a first-run check — see the deploy script's TODO.
