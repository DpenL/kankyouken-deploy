# Where everything lives

Five repos, three machines. This file exists because the answer is not obvious and
gets re-asked.

## Repos on GitHub (DpenL)

| Repo | What it is | Visibility |
|---|---|---|
| `KanKyouKen` | The platform: schema, migrations, 13 edge functions, Python SDK | public |
| `FlashCardApp` | Daily-session client — pre-test, 3x practice, post-test, questionnaire | public |
| `EnrolmentApp` | One-time enrolment — info sheet, consent, account, prescreening | public |
| **`kankyouken-deploy`** | **This repo.** Compose, Caddy, scripts, static pages | private |
| `ClaudeKanKyouKen` | Private knowledge base, handoffs, agent working notes | private |

Split out of the KB repo to separate infrastructure from agentic working notes: this
repo is only the thing that runs. It is **private**, and reaches the VM by copy
(`scripts/push.sh`) — no deploy key, no git on the VM.

## Laptop — `~/projects/`

```
KanKyouKen/          platform; supabase/migrations + supabase/functions
FlashCardApp/        daily client        -> builds to dist/
EnrolmentApp/        enrolment client    -> builds to dist/
kankyouken-deploy/   this repo           <- all infrastructure
ClaudeKanKyouKen/    private KB          (no longer contains deploy/)
```

All builds happen here. **Node never goes on the VM** — less to maintain, and one
less thing to justify in a data-protection conversation.

## VM — `~/` on gr-stiftl.ndx.cit.tum.de

```
~/deploy/
  kankyouken-deploy/     rsync'd from the laptop          <- compose runs from here
    volumes/             fetched by scripts/fetch-upstream-volumes.sh   (gitignored)
    www/
      index.html         landing page                     (tracked)
      kanji-commons/     project page                     (tracked)
      signup/            EnrolmentApp bundle, rsync'd     (gitignored)
      study/             FlashCardApp bundle, rsync'd     (gitignored)
  functions-src/         edge functions, rsync'd from KanKyouKen/supabase/functions/
  .env                   ALL SECRETS. mode 600. never in any repo.
  backups/               pg_dump output. mode 700. never in any repo.
```

Note `.env` and `backups/` sit **beside** the checkout, not inside it. Nothing secret
is ever one `git add -A` away from a commit.

## The flow

```
scripts/push.sh   (laptop, WSL)
   |- builds both clients with the right VITE_BASE_PATH
   |- writes DEPLOYED.txt (the commit SHAs behind what is live)
   `- rsyncs  config+scripts+pages -> ~/deploy/kankyouken-deploy/
              client bundles       -> ~/deploy/kankyouken-deploy/www/{signup,study}/
              edge functions       -> ~/deploy/functions-src/

scripts/deploy.sh (VM)
   |- copies functions beside the upstream main router
   `- docker compose up -d
```

`--delete` is on, but `volumes/` is excluded: it holds the fetched upstream tree and
the postgres data directory.

## Why the clients are not submodules

Considered and rejected for now. Submodules would pin exactly which client commit is
deployed, which is genuinely useful for a study. But:

- The VM needs **built artefacts, not source**. Submodules would put client source on
  the server and imply building there — exactly what keeping Node off the VM avoids.
- Submodule ergonomics are poor: detached HEADs, forgotten `--recurse-submodules`,
  two-step commits. Real friction, for one person, for a 15-person pilot.
- The provenance benefit is obtainable for free, and now is: `scripts/push.sh` writes
  `DEPLOYED.txt` with the SHA of every repo behind the running system, flagging any
  that were dirty at push time.

**Revisit at archival.** If you publish a reproducibility bundle with the paper, one
`git clone --recursive` reproducing the whole system is worth the friction. Adding
submodules later is one command per client; nothing here forecloses it.