-- =============================================================================
-- Security: Row Level Security and column permissions.
-- Rule of thumb: the app can READ through these policies, but every WRITE that
-- matters (booking, accepting, status changes, ratings) goes through the
-- security-definer functions in 20261121000003_booking_logic.sql.
-- =============================================================================

-- Helper: is the current user an admin?
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- Helper: are the current user and another user both part of one live or past trip?
create or replace function public.shares_trip_with(other uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.trips t
    where t.driver_id is not null
      and t.status in ('accepted', 'arrived', 'started', 'completed', 'cancelled')
      and (
        (t.customer_id = auth.uid() and t.driver_id = other) or
        (t.driver_id = auth.uid() and t.customer_id = other)
      )
  );
$$;

-- Helper: has this driver been sent this trip?
create or replace function public.was_offered(p_trip uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.trip_offers o
    where o.trip_id = p_trip and o.driver_id = auth.uid()
  );
$$;

revoke all on function public.is_admin()            from public, anon;
revoke all on function public.shares_trip_with(uuid) from public, anon;
revoke all on function public.was_offered(uuid)      from public, anon;
grant execute on function public.is_admin()            to authenticated;
grant execute on function public.shares_trip_with(uuid) to authenticated;
grant execute on function public.was_offered(uuid)      to authenticated;

-- ---------------------------------------------------------------------------
-- Enable RLS everywhere
-- ---------------------------------------------------------------------------
alter table public.profiles    enable row level security;
alter table public.drivers     enable row level security;
alter table public.fare_rates  enable row level security;
alter table public.trips       enable row level security;
alter table public.trip_offers enable row level security;
alter table public.ratings     enable row level security;
alter table public.sos_events  enable row level security;

-- Nothing is visible to signed-out users.
revoke all on all tables in schema public from anon;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create policy "profiles: read own, trip partner, or admin"
  on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_trip_with(id) or public.is_admin());

create policy "profiles: update own"
  on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Users may only change these columns on their own profile (never is_admin).
revoke update on public.profiles from authenticated;
grant update (full_name, phone, role, push_token, avatar_url) on public.profiles to authenticated;
revoke insert, delete on public.profiles from authenticated;

-- ---------------------------------------------------------------------------
-- drivers (written only through register_driver / availability functions)
-- ---------------------------------------------------------------------------
create policy "drivers: read own, trip partner, or admin"
  on public.drivers for select to authenticated
  using (id = auth.uid() or public.shares_trip_with(id) or public.is_admin());

revoke insert, update, delete on public.drivers from authenticated;

-- ---------------------------------------------------------------------------
-- fare_rates: everyone signed in can read, only admins edit
-- ---------------------------------------------------------------------------
create policy "fare_rates: read"
  on public.fare_rates for select to authenticated
  using (true);

create policy "fare_rates: admin write"
  on public.fare_rates for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- trips: customer sees own, driver sees offered or assigned, admin sees all
-- ---------------------------------------------------------------------------
create policy "trips: read"
  on public.trips for select to authenticated
  using (
    customer_id = auth.uid()
    or driver_id = auth.uid()
    or (status = 'searching' and public.was_offered(id))
    or public.is_admin()
  );

revoke insert, update, delete on public.trips from authenticated;

-- ---------------------------------------------------------------------------
-- trip_offers: drivers see their own offers
-- ---------------------------------------------------------------------------
create policy "trip_offers: read own"
  on public.trip_offers for select to authenticated
  using (driver_id = auth.uid() or public.is_admin());

revoke insert, update, delete on public.trip_offers from authenticated;

-- ---------------------------------------------------------------------------
-- ratings
-- ---------------------------------------------------------------------------
create policy "ratings: read given or received"
  on public.ratings for select to authenticated
  using (from_user = auth.uid() or to_user = auth.uid() or public.is_admin());

revoke insert, update, delete on public.ratings from authenticated;

-- ---------------------------------------------------------------------------
-- sos_events: admins only (written through trigger_sos)
-- ---------------------------------------------------------------------------
create policy "sos_events: admin read"
  on public.sos_events for select to authenticated
  using (public.is_admin() or user_id = auth.uid());

create policy "sos_events: admin update"
  on public.sos_events for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

revoke insert, delete on public.sos_events from authenticated;
