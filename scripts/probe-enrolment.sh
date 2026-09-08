#!/usr/bin/env bash
# Verify an enrolment actually landed. Run this ON THE VM.
#   scripts/probe-enrolment.sh              newest participant
#   scripts/probe-enrolment.sh <uuid>       a specific one
set -euo pipefail

ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"
DB_CONTAINER="supabase-db"
[ -f "$ENV_FILE" ] || { echo "no env file at $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

PID="${1:-}"
WHERE="p.id = (select id from public.participants order by created_at desc limit 1)"
[ -n "$PID" ] && WHERE="p.id = '$PID'"

docker exec -i "$DB_CONTAINER" psql -U postgres -d "${POSTGRES_DB:-postgres}" -F'|' <<SQL
\echo
\echo -- participant --
select p.id, p.consent_status, p.consent_timestamp,
       coalesce(p.user_id::text,'(no account)') as account
from public.participants p where $WHERE;

\echo -- consent records (expect one per study, same participant_id) --
select s.name, r.consent_version, r.consent_status, r.granted_at
from public.consent_records r
join public.studies s on s.id = r.study_id
join public.participants p on p.id = r.participant_id
where $WHERE order by s.name;

\echo -- events (payload->>'client_event_id' repeated = a duplicate delivery) --
select e.event_type, e.ts, e.payload->>'client_event_id' as client_event_id,
       jsonb_array_length(coalesce(e.payload->'responses','[]'::jsonb)) as n_responses
from public.events e
join public.participants p on p.id = e.participant_id
where $WHERE order by e.created_at;
SQL
