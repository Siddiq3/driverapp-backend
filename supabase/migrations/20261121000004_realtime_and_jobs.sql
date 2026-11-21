-- =============================================================================
-- Realtime + scheduled cleanup
-- =============================================================================

-- Live updates: customers watch their trip, drivers watch their offers.
-- Realtime respects the RLS policies, so nobody sees rows they can't read.
alter publication supabase_realtime add table public.trips;
alter publication supabase_realtime add table public.trip_offers;

-- Full old rows on update, so filters like driver_id=eq.<id> work on updates too.
alter table public.trips       replica identity full;
alter table public.trip_offers replica identity full;

-- Every minute, expire trips whose customer closed the app mid-search.
create extension if not exists pg_cron;

select cron.schedule(
  'expire-stale-trips',
  '* * * * *',
  $$ select public.expire_stale_trips(); $$
);
