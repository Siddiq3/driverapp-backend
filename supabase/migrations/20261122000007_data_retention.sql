-- =============================================================================
-- Data retention, matching the privacy policy:
-- finished trips and SOS records are kept up to 2 years, then deleted.
-- Runs on the 1st of every month at 03:00.
-- =============================================================================

create or replace function public.purge_old_records()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.trips
  where status in ('completed', 'cancelled', 'expired')
    and created_at < now() - interval '2 years';

  delete from public.sos_events
  where resolved and created_at < now() - interval '2 years';
end;
$$;

revoke all on function public.purge_old_records() from public, anon, authenticated;

select cron.schedule('purge-old-records', '0 3 1 * *', $$ select public.purge_old_records(); $$);
