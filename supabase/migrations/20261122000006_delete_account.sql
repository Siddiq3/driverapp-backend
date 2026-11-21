-- =============================================================================
-- Delete my account (required by Google Play: in the app and on the website).
-- Cancels any live trip, then deletes the login. Profile, driver details,
-- the person's own bookings, ratings and SOS records are removed with it
-- (foreign keys cascade). Trips they drove stay for the customer, without them.
-- =============================================================================

-- "Who cancelled" must not block deleting that person
alter table public.trips drop constraint if exists trips_cancelled_by_fkey;
alter table public.trips
  add constraint trips_cancelled_by_fkey
  foreign key (cancelled_by) references public.profiles (id) on delete set null;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Not signed in';
  end if;

  -- Close live trips so nobody is left waiting
  update public.trips
  set status = 'cancelled', cancelled_at = now(), cancelled_by = null,
      cancel_reason = 'Account deleted'
  where (customer_id = v_me or driver_id = v_me)
    and status in ('searching', 'accepted', 'arrived', 'started');

  delete from auth.users where id = v_me;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
