-- Timezone-aware hourly schedule.
--
-- send-questions  runs every hour at :00.  The function itself checks each
-- device's IANA timezone and only delivers when it is currently noon (12:00)
-- or 6 PM (18:00) for that device — so users in any timezone get their
-- questions at their local noon and 6 PM automatically.
--
-- send-expirations runs every hour at :00 as well.  It only pushes the
-- "time's up" reveal to devices where it is currently 1 PM (13:00) or
-- 7 PM (19:00) local time — exactly one hour after delivery.
-- Because questions and expirations target different local hours (12/18 vs
-- 13/19) the two jobs never fire for the same device in the same minute.

select cron.unschedule(jobid) from cron.job;

-- Deliver questions to any device whose local time is noon or 6 PM right now.
select cron.schedule(
  'send-questions-hourly',
  '0 * * * *',
  $$ select net.http_post(
       url     := 'https://hzlrqxcxcgdvocfaiuof.supabase.co/functions/v1/send-questions',
       headers := '{"Content-Type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6bHJxeGN4Y2dkdm9jZmFpdW9mIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3Nzk2NTI3MSwiZXhwIjoyMDkzNTQxMjcxfQ.Ttujbro4n9dsZr_gBJva6PAv2C-XFVbpe3Bf132LDpo"}'::jsonb,
       body    := '{}'::jsonb
     ); $$
);

-- Expire any unanswered question for devices whose local time is 1 PM or 7 PM right now.
select cron.schedule(
  'send-expirations-hourly',
  '0 * * * *',
  $$ select net.http_post(
       url     := 'https://hzlrqxcxcgdvocfaiuof.supabase.co/functions/v1/send-expirations',
       headers := '{"Content-Type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6bHJxeGN4Y2dkdm9jZmFpdW9mIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3Nzk2NTI3MSwiZXhwIjoyMDkzNTQxMjcxfQ.Ttujbro4n9dsZr_gBJva6PAv2C-XFVbpe3Bf132LDpo"}'::jsonb,
       body    := '{}'::jsonb
     ); $$
);
