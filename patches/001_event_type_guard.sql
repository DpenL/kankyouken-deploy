-- 001_event_type_guard.sql
--
-- Why this exists
-- ---------------
-- `event-collector` accepts any non-empty string as event_type, never consults
-- `event_schemas`, and never sets `events.schema_id`. The column is free text with
-- no FK, no enum and no CHECK. A typo therefore returns 201 Created and is only
-- discovered at analysis time, as an event missing from the reconstruction.
--
-- This is the cheap half of the fix: a database-level allow-list. It cannot log to
-- audit_log (a CHECK constraint just rejects the INSERT), so it is a backstop, not
-- the whole answer -- see 002_event_collector_guard.ts.patch for the half that
-- validates per study and writes an audit entry.
--
-- Backup first, then migrate
-- --------------------------
-- A CHECK constraint cannot be added while rows violate it, and this database holds
-- rows that do (`test_event` from the first smoke test). Rather than refusing, this
-- migration copies public.events wholesale into a timestamped table in the `archive`
-- schema, and only then removes the offending rows from the live table. Nothing is
-- destroyed: every archived row is still queryable, and the copy is taken inside the
-- same transaction as the delete, so either both happen or neither does.
--
-- `archive` is deliberately NOT in PGRST_DB_SCHEMAS, so PostgREST does not expose it
-- and the archived rows are unreachable over the API. Grants are revoked explicitly
-- as well, because the default privileges installed for public would otherwise apply.
--
-- Run scripts/backup.sh first anyway. An in-database archive survives a bad migration;
-- it does not survive a lost volume.
--
-- Apply on the VM:
--   docker exec -i supabase-db psql -v ON_ERROR_STOP=1 -U postgres -d "$POSTGRES_DB" \
--     < patches/001_event_type_guard.sql
--
-- Roll back:
--   ALTER TABLE public.events DROP CONSTRAINT events_event_type_known;
--   -- and, if the removed rows are wanted back:
--   INSERT INTO public.events SELECT * FROM archive.<the table named below>
--     WHERE event_type NOT IN (SELECT unnest(...));   -- see the NOTICE this prints

BEGIN;

CREATE SCHEMA IF NOT EXISTS archive;
REVOKE ALL ON SCHEMA archive FROM PUBLIC;
REVOKE ALL ON SCHEMA archive FROM anon, authenticated;

DO $$
DECLARE
  t        text := 'events_pre_guard_' || to_char(now(), 'YYYYMMDD_HH24MISS');
  archived bigint;
  removed  bigint;
  kinds    text;
BEGIN
  -- 1. copy the whole table, before anything is removed from it
  EXECUTE format('CREATE TABLE archive.%I AS TABLE public.events', t);
  GET DIAGNOSTICS archived = ROW_COUNT;
  EXECUTE format('REVOKE ALL ON archive.%I FROM PUBLIC, anon, authenticated', t);

  -- 2. what is about to go, named explicitly so it is in the log
  SELECT string_agg(DISTINCT event_type, ', ')
    INTO kinds
    FROM public.events
   WHERE event_type NOT IN (
     'consent_given','account_created','questionnaire_submitted',
     'prescreen_item','prescreen_submitted',
     'session_started','session_completed','test_item_answered','practice_prompt_shown',
     'practice_revealed','practice_self_report','usability_submitted',
     'withdrawal_requested','researcher_override','client_error'
   );

  -- 3. remove them from the live table only; the archive still has them
  DELETE FROM public.events
   WHERE event_type NOT IN (
     'consent_given','account_created','questionnaire_submitted',
     'prescreen_item','prescreen_submitted',
     'session_started','session_completed','test_item_answered','practice_prompt_shown',
     'practice_revealed','practice_self_report','usability_submitted',
     'withdrawal_requested','researcher_override','client_error'
   );
  GET DIAGNOSTICS removed = ROW_COUNT;

  RAISE NOTICE 'archived % row(s) to archive.%', archived, t;
  IF removed > 0 THEN
    RAISE NOTICE 'removed % row(s) from public.events, event_type(s): %', removed, kinds;
    RAISE NOTICE 'they are still in archive.% -- nothing was lost', t;
  ELSE
    RAISE NOTICE 'no rows needed removing; the archive is a plain snapshot';
  END IF;
END $$;

ALTER TABLE public.events
  ADD CONSTRAINT events_event_type_known CHECK (event_type IN (
    -- enrolment client  (EnrolmentApp/src/study/constants.ts, ENROL_EVENT)
    'consent_given',
    'account_created',
    'questionnaire_submitted',
    'prescreen_item',
    'prescreen_submitted',
    -- daily-session client  (FlashCardApp/src/backend/events.ts, EVENT)
    'session_started',
    'session_completed',
    'test_item_answered',
    'practice_prompt_shown',
    'practice_revealed',
    'practice_self_report',
    'usability_submitted',
    'withdrawal_requested',
    'researcher_override',
    'client_error'
  ));

COMMIT;

-- Adding an event type later means editing this list in a new migration. That is the
-- cost of the simple version; the per-study check in 002 does not have it.
