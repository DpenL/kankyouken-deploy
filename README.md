# kankyouken-deploy

Deployment configuration for the KN-202 pilot backend on the TUM VM.

Rationale, constraints and ethics requirements live in the private KB repo at
`ClaudeKanKyouKen/handoffs/HANDOFF-PILOT-DEPLOYMENT.md`. **This** repo is the
*what actually runs*: config, scripts, and the static pages. No KB material.
See `LAYOUT.md` for where every file lives across laptop, VM and GitHub.

## Target

| | |
|---|---|
| VM | `ndxvm5.cit.tum.de` (alias **gr-stiftl.ndx.cit.tum.de**), TUM-controlled |
| Specs | Ubuntu 24.04.4 LTS, 4 vCPU, **3.8 GiB RAM** + 2 GiB swap, 93 GB disk |
| Access | SSH as `stiftl` (VPN/TUM network only); ports 22/80/443 open externally |
| Stack | Docker 29.x + Compose v5, self-hosted Supabase (pruned), Caddy on 443 |

The RAM situation is the handoff's "~4 GB: workable with Storage + analytics
containers off" row — the compose file here is the pilot-minimal service set:
Postgres, GoTrue, PostgREST, Kong, Edge Functions runtime (+ Realtime unless
RAM says otherwise). Storage, imgproxy, Studio, Inbucket, pooler, analytics: OFF.

## Layout

```
deploy/
  README.md            ← this file (doubles as RUNBOOK — see below)
  docker-compose.yml   ← pruned Supabase stack
  .env.example         ← every required secret/setting, placeholder values
  caddy/Caddyfile      ← TLS termination → Kong
  scripts/
    deploy.sh          <- on the VM: sync functions + compose up -d
    backup.sh          ← nightly pg_dump (retention-compliant)
    smoke-test.sh      ← health + signed test event against event-collector
    push.sh            <- on the LAPTOP: build + rsync everything to the VM
```

## Version-control workflow (single source of truth)

This repo is private and the VM has **no clone, no deploy key and no git**. Delivery
is a copy: run `scripts/push.sh` on the laptop (from WSL, it needs rsync). It builds
both clients, rsyncs config, scripts, pages, bundles and edge functions to the VM,
and writes `DEPLOYED.txt` recording the commit SHA behind every piece of what is
live. Then `scripts/deploy.sh` on the VM brings the stack up.

Commit here first anyway: `push.sh` flags any repo that was dirty at push time, and
a DIRTY line means the SHAs do not describe what is actually running.

**Never commit:** real `.env`, TLS private keys, JWT secrets, dumps. `.gitignore`
in this directory enforces the obvious ones. Real secrets exist only in
`~/deploy/.env` on the VM, mode 600.

## Runbook (filled in as the deployment lands)

- **Start/stop:** `docker compose --env-file ~/deploy/.env up -d` / `down`
- **Logs:** `docker compose logs -f <service>`
- **Backup:** `scripts/backup.sh` (cron, nightly) — TODO: wire up + rehearse restore
- **Deletion by 2026-12-31:** TODO (one-paragraph procedure per handoff DoD #3)
- **TLS cert:** TODO — location + renewal owner (Sven/TUM IT) once delivered
- **Who to call:** Sven (TUM IT, VM/cert), David (study owner)

## Status log

- 2026-07-08: VM inventoried (specs above). Docker + Compose preinstalled,
  outbound registry/GitHub access OK, 80/443 reachable (nothing listening yet).
  No TLS cert found in user-accessible paths yet — cert delivery still pending
  confirmation from TUM IT. `docker` group membership for `stiftl` pending.

- 2026-09-06: Recon re-run and the July gaps closed. TLS cert **found** at
  `/var/lib/rbg-cert/live` (RBG-issued, CN `ndxvm5.cit.tum.de`, SAN also covers
  `gr-stiftl.ndx.cit.tum.de`, valid to 2027-02-08) � supersedes the 07-08 note.
  `stiftl` can run docker; sudo works but **prompts** (not passwordless).
  DNS confirmed: both names -> 131.159.113.14. Egress to Docker Hub OK (`/v2/`
  returns 401 by design, which is a pass). 80/443 still free.
  Caddyfile now also serves static content; cert mount corrected to the identical
  absolute path. **Open:** an ad-hoc nginx stack is currently running from
  `~/srv` and holds :443 � it must be retired before this compose can start.