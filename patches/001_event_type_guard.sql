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
-- Apply on the VM:
--   docker exec -i supabase-db psql -U postgres -d "$POSTGRES_DB" < 001_event_type_guard.sql
-- Roll back:
--   ALTER TABLE public.events DROP CONSTRAINT events_event_type_known;

BEGIN;

-- Fail loudly if anything already stored would violate the constraint, rather than
-- having ALTER TABLE do it with a less useful message.
DO $$
DECLARE offending text;
BEGIN
  SELECT string_agg(DISTINCT event_type, ', ') INTO offending
  FROM public.events
  WHERE event_type NOT IN (
    'consent_given','account_created','questionnaire_submitted','prescreen_submitted',
    'session_started','session_completed','test_item_answered','practice_prompt_shown',
    'practice_revealed','practice_self_report','usability_submitted',
    'withdrawal_requested','researcher_override','client_error'
  );
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'events already contains unlisted event_type(s): %. Add them to the list or clean them up first.', offending;
  END IF;
END $$;

ALTER TABLE public.events
  ADD CONSTRAINT events_event_type_known CHECK (event_type IN (
    -- enrolment client  (EnrolmentApp/src/study/constants.ts, ENROL_EVENT)
    'consent_given',
    'account_created',
    'questionnaire_submitted',
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