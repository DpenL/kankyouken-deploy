#!/usr/bin/env bash
# End-to-end reachability check: TLS -> Caddy -> Kong -> edge functions -> Postgres.
#
# WRITES ONE EVENT. Pass a throwaway study id, never the live one:
#   scripts/smoke-test.sh <study-uuid> [base-url]
set -euo pipefail

STUDY_ID="${1:-}"
BASE="${2:-https://gr-stiftl.ndx.cit.tum.de}"
ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0

[ -n "$STUDY_ID" ] || { echo "usage: $0 <study-uuid> [base-url]" >&2; exit 2; }

echo "smoke test against $BASE"

# 1. TLS and the static site --------------------------------------------------
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/" || true)"
verify="$(curl -sS -o /dev/null -w '%{ssl_verify_result}' --max-time 10 "$BASE/" || echo 1)"
[ "$code" = "200" ] && pass "landing page 200" || fail "landing page returned $code"
[ "$verify" = "0" ] && pass "TLS chain validates against public roots" || fail "TLS verify=$verify"

for path in /signup/ /study/ /kanji-commons/; do
  c="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$BASE$path" || true)"
  [ "$c" = "200" ] && pass "$path 200" || fail "$path returned $c"
done

# 2. Edge function health -----------------------------------------------------
h="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/functions/v1/health" || true)"
[ "$h" = "200" ] && pass "functions/v1/health 200" || fail "health returned $h"

# 3. A real event through the collector ---------------------------------------
# Deliberately shaped like the flashcard client's contract (docs/EVENTS.md).
payload=$(cat <<JSON
{"participant_id":"00000000-0000-4000-8000-000000000000",
 "study_id":"$STUDY_ID",
 "event_type":"client_error",
 "payload":{"smoke_test":true,"client_event_id":"$(cat /proc/sys/kernel/random/uuid)","client_seq":1},
 "ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)",
 "app_version":"smoke-test/1","platform":"ci"}
JSON
)
resp="$(curl -sS -X POST "$BASE/functions/v1/event-collector" \
          -H 'Content-Type: application/json' -d "$payload" \
          -w '\n%{http_code}' --max-time 15 || true)"
body="$(echo "$resp" | head -n -1)"; status="$(echo "$resp" | tail -n1)"
if [ "$status" = "201" ]; then
  pass "event-collector accepted a test event"
  echo "       $body"
else
  fail "event-collector returned $status"
  echo "       $body"
  echo "       NOTE: a 4xx here often means the per-study schema does not know this"
  echo "             event_type. That is the check, not a bug in the script."
fi

echo
[ "$FAILED" = "0" ] && echo "all checks passed" || { echo "one or more checks failed"; exit 1; }