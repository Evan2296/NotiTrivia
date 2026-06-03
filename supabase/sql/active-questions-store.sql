-- active_questions table
--
-- Tracks one row per timezone-group delivery so that users in different time zones
-- never overwrite each other's records.
--
-- The `slot` primary key is a timezone-qualified string:
--   "noon_<utcHour>"    e.g. "noon_16"  — noon question delivered at UTC 16:00
--   "evening_<utcHour>" e.g. "evening_4" — evening question delivered at UTC 04:00
--
-- Including the UTC delivery hour means a London noon delivery (UTC 11) and a
-- New York noon delivery (UTC 16) each get their own row, preventing the London
-- row from clobbering NYC's correct_answer before send-expirations runs for NYC.
--
-- send-questions prunes rows older than 2 hours on every run so the table stays lean.
--
-- ── Initial schema creation ──────────────────────────────────────────────────
create table active_questions (
  slot            text        primary key,   -- e.g. "noon_16" or "evening_4"
  question_id     text        not null,
  correct_answer  text        not null,
  question_text   text        not null,
  delivered_at    timestamptz not null,
  expiration_sent boolean     default false,
  is_answered     boolean     default false  -- set true by mark-answered to suppress expiration push
);

-- ── Migration for existing deployments ───────────────────────────────────────
-- Run this once against the production database if the table already exists
-- without the is_answered column (it was added after initial schema creation):
--
--   ALTER TABLE active_questions
--     ADD COLUMN IF NOT EXISTS is_answered boolean DEFAULT false;
--
-- The slot column's value format has also changed from bare "noon"/"evening" to
-- timezone-qualified "noon_<utcHour>"/"evening_<utcHour>".  Old bare-slot rows
-- are harmless — send-expirations's 2-hour freshness guard will skip them, and
-- send-questions's cleanup will delete them on the next hourly run.
