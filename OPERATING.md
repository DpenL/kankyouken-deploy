# Operating KanKyouKen — KN-202 pilot

How to change things, check they worked, get at the data, and rebuild it from
nothing. Written for the person doing this at 23:00 having forgotten everything,
which will at some point be you.

Companions: `LAYOUT.md` (where files live), `README.md` (what this repo is),
`UPSTREAM.md` (which Supabase commit is pinned).

## 1. The three places

Confusing these is the commonest source of wasted time here.

| | Path | What it is |
|---|---|---|
| **Laptop** | `C:\Users\david\projects\kankyouken-deploy` | The git repo. You edit here. |
| **VM** | `~/deploy/kankyouken-deploy` | A copy made by `scripts/push.sh`. Never hand-edited except `www/*/config.json`. |
| **VM, beside it** | `~/deploy/.env`, `~/backups/` | Secrets and dumps. Outside the synced tree on purpose: nothing secret is one `git add -A` from a commit, and `rsync --delete` cannot reach them. |

There is no git clone on the VM and no `git pull`. The copy **is** the delivery.

## 2. The everyday loop

```powershell
# Windows - build. WSL cannot: node_modules holds rollup's win32 native binary.
cd C:\Users\david\projects\EnrolmentApp; $env:VITE_BASE_PATH="/signup/"; npm run build
cd C:\Users\david\projects\FlashCardApp;  $env:VITE_BASE_PATH="/study/";  npm run build
```
```bash
# WSL
cd ~/projects/kankyouken-deploy && scripts/push.sh --no-build
```

That is the whole loop for anything static - code, prescreen items, questionnaire,
consent text. Served off disk; no container restart. `push.sh` refuses to run if
`dist/` is older than `src/`, `public/` or `package.json`, and names the offending
file. Forgetting the build used to be silent.

| Change | Extra step |
|---|---|
| Edge function | `scripts/deploy.sh` on the VM, or restart the `functions` container |
| compose / Caddyfile | `docker compose --env-file ~/deploy/.env up -d` - recreates only what changed |
| DB schema | write a migration in `KanKyouKen/supabase/migrations/`, push, then `scripts/migrate.sh` on the VM |

**Schema changes.** Add a file named `<timestamp>_<name>.sql` to
`KanKyouKen/supabase/migrations/` — the same directory the Supabase CLI uses, so
local dev, CI and the VM stay on one history. `push.sh` mirrors that directory
into `~/deploy/migrations/`; `scripts/migrate.sh` on the VM applies whatever has
not run yet, one transaction per file, and records it in
`supabase_migrations.schema_migrations`. `scripts/migrate.sh --status` lists
applied and pending without changing anything. `deploy.sh` calls it for you.

Nothing in `docker-compose.yml` creates the schema. A stack brought up without
this step has an empty `public`, and the only symptom you see is a 500 from the
first edge function you call — see the traps at the bottom.

`config.json` is **excluded** from the sync. The VM's copies are authoritative; the
locally-built ones say `mode: "local"` and would take the deployment offline while
looking perfectly healthy.

## 3. Access

**There is no Supabase Studio.** The stack is `db auth rest kong realtime functions
caddy`. `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` in `.env` are vestigial.

The admin UI is the KanKyouKen Next.js frontend, run on your laptop against the VM:

```bash
# KanKyouKen/frontend/.env.local - keep a copy of your local-dev values first
NEXT_PUBLIC_SUPABASE_URL=https://gr-stiftl.ndx.cit.tum.de
NEXT_PUBLIC_SUPABASE_ANON_KEY=<ANON_KEY from ~/deploy/.env>
SUPABASE_SERVICE_ROLE_KEY=<SERVICE_ROLE_KEY from ~/deploy/.env>
npm run dev
```
The service-role key bypasses row-level security. Fine on your laptop, never in a
deployed frontend.

```bash
docker exec -it supabase-db psql -U postgres -d postgres
```
```sql
select id, name from studies;
select action, target, timestamp from audit_log order by timestamp desc limit 20;
select event_type, count(*) from events group by 1 order by 2 desc;
select p.id, count(distinct c.study_id) as studies
  from participants p join consent_records c on c.participant_id = p.id group by 1;
```
```bash
cd ~/deploy/kankyouken-deploy
docker compose --env-file ~/deploy/.env logs -f --tail=100 functions
docker compose --env-file ~/deploy/.env ps
```

Clients: `/signup/` (enrolment + prescreening), `/study/` (five-day protocol),
`/study/#/operator` (queue, force-send, unblock a day - local to one browser, not a
server admin surface).
## 4. Testing

On the laptop, before deploying:
```bash
npx vitest run        # EnrolmentApp 26 tests, FlashCardApp 195
npx tsc --noEmit
node scripts/verify-content.mjs        # EnrolmentApp only
```
`verify-content.mjs` fails on unresolved placeholders reaching participants,
eligibility rules pointing at unknown questions, more than one consent checkbox, and
any prescreen item that is not a single CJK codepoint - that last one exists because
a generated placeholder set once shipped with French and Ukrainian words in it.
Expected: `0 error(s), 0 warning(s), 2 expected placeholder(s)`. The two are
placeholders inside the approved documents; you fill them in the pages and mails
that embed those documents, never in the verbatim copies.

```bash
DRY=1 scripts/push.sh --no-build       # shows what would move, changes nothing
```
A dry run cannot catch everything - it never calls `mkdir`, which is how a broken
remote path once survived one.

On the VM, structural checks that cost seconds:
```bash
cd ~/deploy/kankyouken-deploy
docker compose --env-file ~/deploy/.env config >/dev/null && echo "compose OK"

set -a; . ~/deploy/.env; set +a
docker run --rm -e SITE_ADDRESS="$SITE_ADDRESS" \
  -v ~/deploy/kankyouken-deploy/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v /var/lib/rbg-cert:/var/lib/rbg-cert:ro \
  caddy:2.8-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```
The Caddy check also proves the certificate loads. Expect `Valid configuration` plus
a line saying certificates are already loaded for `gr-stiftl.ndx.cit.tum.de`.

The consent probe - the contract that was broken once, worth re-checking after any
platform change:
```bash
set -a; . ~/deploy/.env; set +a
curl -sS -X POST "http://localhost:8000/functions/v1/consent" \
  -H "Content-Type: application/json" -H "apikey: $ANON_KEY" \
  -d "{\"participant_id\":\"$(uuidgen)\",\"study_id\":\"$STUDY_ID\",\"consent_version\":\"probe\",\"consent_text\":\"{}\"}"
```
`201` and `{"success":true,"record":{...}}`. `400` means the contract drifted; `404`
means the study id is not a row in `studies`.

The event guard, once `patches/001` is applied:
```bash
curl -sS -X POST "http://localhost:8000/functions/v1/event-collector" \
  -H "Content-Type: application/json" -H "apikey: $ANON_KEY" \
  -d "{\"participant_id\":\"$PID\",\"study_id\":\"$SID\",\"event_type\":\"consent_recorded\"}"
# should be rejected, and should appear in audit_log
```

End to end before recruiting: two full dry runs, one against the real backend.
Events land, no third-party requests leave the page, no email address leaves the
client, and closing the prescreen tab halfway then reopening resumes at the same
item. The five-day protocol rolls days at Europe/Vienna midnight from the server
clock by design - you cannot compress it into an evening; use `#/operator` to
unblock a day, and the override logs itself as `researcher_override`.

## 5. Replicating and moving

Everything except secrets and data is in git.

```bash
# 1. laptop
scripts/push.sh
# 2. VM - secrets. ANON_KEY and SERVICE_ROLE_KEY are JWTs SIGNED WITH JWT_SECRET,
#    not random strings. Generated like passwords, the stack starts cleanly and
#    rejects every request.
cp ~/deploy/kankyouken-deploy/.env.example ~/deploy/.env
nano ~/deploy/.env && chmod 600 ~/deploy/.env
# 3. VM
cd ~/deploy/kankyouken-deploy
scripts/fetch-upstream-volumes.sh
docker compose --env-file ~/deploy/.env up -d db auth rest kong functions
# 4. VM - schema. Nothing above creates it. Skip this and step 5 has no tables
#    to write into, and the edge functions answer 500 without logging why.
scripts/migrate.sh
# 5. researcher auth user, then project + studies + study_roles rows
# 6. www/signup/config.json and www/study/config.json
# 7. event_schemas rows, one per study
# 8. psql < patches/001_event_type_guard.sql
# 9. scripts/deploy.sh   (brings up Caddy too)
```

Moving the whole thing - the VM is decommissioned January 2027. `participants`, both
sets of `consent_records` and every event live in one database linked by foreign
keys, so a dump carries the lot intact:
```bash
scripts/backup.sh
gunzip -c kankyouken-<stamp>.sql.gz | docker exec -i supabase-db psql -U postgres -d postgres
```

Backups:
```bash
BACKUP_MIRROR="stiftl@<tum-host>:kankyouken-backups/" scripts/backup.sh
```
Without `BACKUP_MIRROR` the dump lives only on the machine it backs up, which is not
a backup; the script says so every run, and fails hard if the mirror copy fails -
a silent mirror failure is worse than no mirror.

Retention: participants were told 2026-12-31. The approved application adds,
verbatim, *"Data are deleted by January 2027 unless the work is published or under
review."* Past the date the script asks for a recorded reason rather than refusing,
and appends it to `RETENTION-OVERRIDES.log`:
```bash
RETENTION_OVERRIDE="under review at <venue>, submitted <date>" scripts/backup.sh
```

Rehearse a restore once, before the study. An untested backup is a rumour.
```bash
docker exec -i supabase-db psql -U postgres -c "CREATE DATABASE kankyouken_restoretest;"
gunzip -c ~/backups/$(ls -t ~/backups | head -1) \
  | docker exec -i supabase-db psql -U postgres -d kankyouken_restoretest
```
## 6. Traps, all of which have already happened

**Bringing up the stack does not create the schema.** `docker-compose.yml` starts
Postgres with the Supabase bootstrap only. Every edge function then returns
`500 Internal Server Error` on its first table lookup, and its own log says
nothing, because the underlying failure is a PostgREST 404 that the function
converts into `Errors.internal()`. The tell is in the `rest` container, not the
`functions` one:

```
Schema cache loaded 0 Relations, 0 Relationships, 1 RPCs
```

Fix: `scripts/migrate.sh`. Cost an evening, chasing an edge-function bug that was
never in the edge function.

**Supabase's table grants are part of the bootstrap, and this image does not
install them for `postgres`.** Hosted Supabase and `supabase start` grant ALL on
every new table in `public` to `anon`, `authenticated` and `service_role` and let
RLS do the narrowing. Here that has to be set explicitly, and it has to happen
*before* the migrations run — a blanket GRANT afterwards would undo the REVOKEs
the migrations themselves perform (002 revokes INSERT on `events`).
`migrate.sh` does this. Without it PostgREST connects, sees the tables, and
answers `permission denied` to everything.

**Those same default grants are load-bearing for anything without RLS.** Four
objects in the schema have RLS off, so the grant is the only control on them:
`study_invitations` (single-use tokens that grant a role up to `owner`) and the
`my_events` / `my_studies` / `my_projects` views, which are owned by `postgres`,
so they see past RLS, and which Postgres treats as auto-updatable. Migration
`20260907001_grant_hardening` revokes both. If you add a table without RLS,
revoke by hand in the same migration — the default is open, not closed.

**PostgREST caches the schema at connect time.** After a migration the tables
exist and every request still 404s with `PGRST205` until something sends
`NOTIFY pgrst, 'reload schema'`. `migrate.sh` does it; a container restart also
works, and is what you will reach for if you applied SQL by hand.

**The RBG certificate symlinks are absolute.** `/var/lib/rbg-cert/live/*.pem` point
at `/var/lib/rbg-cert/<timestamp>/...`, so the mount inside the container must be
that identical path: `/var/lib/rbg-cert:/var/lib/rbg-cert:ro`. Mounting the parent
somewhere tidier leaves dangling symlinks and Caddy will not start. Cost two
attempts before it was written down. The `stiftl` user cannot read the private key;
Caddy runs as root in-container, which is why it works anyway. Containers need a
reload roughly 30 days after each renewal.

**`ANON_KEY` and `SERVICE_ROLE_KEY` are JWTs signed with `JWT_SECRET`.** As random
strings the stack starts perfectly and rejects every request. Verify: expect
`role=anon` / `role=service_role`, `iss=supabase`, `signature=VALID`.

**`studies.owner_id` has no foreign key.** Any UUID is accepted, so a typo creates a
study nobody can access - including you - with nothing failing at creation time.
Make the auth user first and use its real id.

**Everything pushed from Windows would land world-writable.** WSL reports `/mnt/c`
files as `0777` and `rsync -a` preserves it faithfully. `push.sh` applies
`--chmod=D750,F640` and restores the executable bit on the scripts. If you add
another rsync, do the same.

**Nothing validates `event_type` server-side by default.** `event-collector` accepts
any non-empty string, never consults `event_schemas`, and never sets `schema_id`. A
typo returns `201 Created` and surfaces months later as an event missing from the
reconstruction. `patches/001` adds a CHECK allow-list; `patches/002` is the
per-study version that also writes `audit_log` entries on rejection and on a missing
schema.

**`jlpt` fields are the OLD four-level scale** - in KANJIDIC2 and in
RadicalFighters' `kanji.db`. Old level 3 is 181 kanji; new N3 is 367; they overlap
by 25. Reading `JLPT = 3` as N3 gives a set ~93% disjoint from the intended one,
with no error and no warning.

**Two studies, one participant.** `participants` has no `study_id`;
`consent_records` is `UNIQUE(participant_id, study_id)`. One account is one
participant_id with one consent record per study, both written from a single act of
consent at enrolment. If anything ever mints a second participant_id for the pilot,
the prescreen-to-pilot link breaks silently. `EnrolmentApp/tests/two-studies.test.ts`
exists to stop that.

**`index.html` must not be cached.** The JS and CSS filenames are content-hashed and
bust themselves, but only if the browser re-reads `index.html` to learn the new
names. The Caddyfile marks the entry points `no-store`; a cached one would pin a
participant to the old bundle mid-study.