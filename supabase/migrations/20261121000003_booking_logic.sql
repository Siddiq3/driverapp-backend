-- =============================================================================
-- Booking logic. Every function checks auth.uid() itself, so the app can call
-- them directly with supabase.rpc(...). Internal helpers are not callable by
-- users (execute revoked at the bottom of this file).
--
-- Flow:
--   request_trip  -> trip 'searching', offers sent to free drivers nearby
--   accept_trip   -> first driver to accept wins (single atomic UPDATE)
--   widen_search  -> after 2 min with no accept: 5 km -> 10 km -> 20 km -> expired
--   driver_update_trip: accepted -> arrived -> started -> completed
--   cancel_trip / rate_trip / trigger_sos
-- =============================================================================

-- Settings in one place
create or replace function public.app_setting(p_key text)
returns numeric
language sql
immutable
as $$
  select case p_key
    when 'offer_seconds'        then 120   -- how long drivers get to accept
    when 'start_radius_km'      then 5
    when 'max_radius_km'        then 20
    when 'max_offers'           then 25    -- drivers notified per round
    when 'location_fresh_min'   then 20    -- ignore drivers whose GPS is older than this
    when 'missed_limit'         then 3     -- ignored requests before auto-busy
    when 'road_factor'          then 1.3   -- straight line -> approx road distance
  end;
$$;

create or replace function public.make_point(p_lat double precision, p_lng double precision)
returns extensions.geography
language sql
immutable
set search_path = public, extensions
as $$
  select st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
$$;

-- ---------------------------------------------------------------------------
-- Drivers: sign up, Free/Busy switch, location
-- ---------------------------------------------------------------------------
create or replace function public.register_driver(
  p_has_car        boolean,
  p_vehicle_type   public.vehicle_type,
  p_vehicle_model  text,
  p_vehicle_number text,
  p_licence_number text
)
returns public.drivers
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_driver public.drivers;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if coalesce(trim(p_licence_number), '') = '' then
    raise exception 'Driving licence number is required';
  end if;
  if p_has_car and (p_vehicle_type is null or coalesce(trim(p_vehicle_number), '') = '') then
    raise exception 'Car type and number are required';
  end if;

  insert into public.drivers (id, has_car, vehicle_type, vehicle_model, vehicle_number, licence_number)
  values (
    auth.uid(),
    p_has_car,
    case when p_has_car then p_vehicle_type end,
    case when p_has_car then nullif(trim(p_vehicle_model), '') end,
    case when p_has_car then upper(replace(trim(p_vehicle_number), ' ', '')) end,
    upper(trim(p_licence_number))
  )
  on conflict (id) do update set
    has_car        = excluded.has_car,
    vehicle_type   = excluded.vehicle_type,
    vehicle_model  = excluded.vehicle_model,
    vehicle_number = excluded.vehicle_number,
    licence_number = excluded.licence_number,
    -- a rejected driver who edits details goes back into the review queue
    status = case when public.drivers.status = 'rejected' then 'pending'::public.driver_status
                  else public.drivers.status end
  returning * into v_driver;

  update public.profiles set role = 'driver' where id = auth.uid();
  return v_driver;
end;
$$;

create or replace function public.set_driver_availability(
  p_available boolean,
  p_lat double precision default null,
  p_lng double precision default null
)
returns public.drivers
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_driver public.drivers;
begin
  select * into v_driver from public.drivers where id = auth.uid();
  if not found then
    raise exception 'You are not registered as a driver';
  end if;
  if v_driver.status <> 'approved' then
    raise exception 'Your driver account is not approved yet';
  end if;
  if p_available then
    if p_lat is null or p_lng is null then
      raise exception 'Location is needed to go online';
    end if;
    if exists (
      select 1 from public.trips
      where driver_id = auth.uid() and status in ('accepted', 'arrived', 'started')
    ) then
      raise exception 'Finish your current trip first';
    end if;
  end if;

  update public.drivers set
    is_available        = p_available,
    missed_streak       = case when p_available then 0 else missed_streak end,
    location            = coalesce(public.make_point(p_lat, p_lng), location),
    location_updated_at = case when p_lat is not null then now() else location_updated_at end
  where id = auth.uid()
  returning * into v_driver;

  return v_driver;
end;
$$;

create or replace function public.update_driver_location(p_lat double precision, p_lng double precision)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public.drivers
  set location = public.make_point(p_lat, p_lng), location_updated_at = now()
  where id = auth.uid();
end;
$$;

-- ---------------------------------------------------------------------------
-- Fares
-- ---------------------------------------------------------------------------
create or replace function public.estimate_fare(
  p_service     public.service_type,
  p_trip_type   public.trip_type,
  p_vehicle     public.vehicle_type,
  p_distance_km numeric,
  p_hours       integer
)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.fare_rates;
  v_fare numeric;
begin
  select * into r from public.fare_rates
  where service_type = p_service
    and trip_type = p_trip_type
    and vehicle_key = case when p_service = 'car_with_driver' then coalesce(p_vehicle::text, 'hatchback') else 'any' end;

  if not found then
    raise exception 'No fare set for this booking type yet';
  end if;

  if p_service = 'driver_only' or p_trip_type = 'hourly' then
    v_fare := r.base_fare + r.per_hour * greatest(coalesce(p_hours, 1), 1);
  else
    v_fare := r.base_fare + r.per_km * greatest(coalesce(p_distance_km, 0), 0);
  end if;

  -- round to the nearest 10 rupees
  return (round(greatest(v_fare, r.min_fare) / 10.0) * 10)::integer;
end;
$$;

-- Approx road distance between two points, in km
create or replace function public.approx_distance_km(
  p_from_lat double precision, p_from_lng double precision,
  p_to_lat   double precision, p_to_lng   double precision
)
returns numeric
language sql
immutable
set search_path = public, extensions
as $$
  select round(
    (st_distance(public.make_point(p_from_lat, p_from_lng), public.make_point(p_to_lat, p_to_lng)) / 1000.0
      * public.app_setting('road_factor'))::numeric, 1);
$$;

-- ---------------------------------------------------------------------------
-- Internal: send offers to free drivers within the trip's search radius
-- Returns how many NEW drivers were offered.
-- ---------------------------------------------------------------------------
create or replace function public.dispatch_offers(p_trip uuid)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t public.trips;
  v_count integer;
begin
  select * into t from public.trips where id = p_trip;
  if not found or t.status <> 'searching' then
    return 0;
  end if;

  with candidates as (
    select d.id,
           round((st_distance(d.location, t.pickup_location) / 1000.0)::numeric, 1) as km
    from public.drivers d
    where d.status = 'approved'
      and d.is_available
      and d.id <> t.customer_id
      and d.location is not null
      and d.location_updated_at > now() - make_interval(mins => public.app_setting('location_fresh_min')::int)
      and st_dwithin(d.location, t.pickup_location, t.search_radius_km * 1000)
      and (
        t.service_type = 'driver_only'
        or (d.has_car and (t.vehicle_type is null or d.vehicle_type = t.vehicle_type))
      )
      and not exists (select 1 from public.trip_offers o where o.trip_id = t.id and o.driver_id = d.id)
      and not exists (
        select 1 from public.trips x
        where x.driver_id = d.id and x.status in ('accepted', 'arrived', 'started')
      )
    order by st_distance(d.location, t.pickup_location)
    limit public.app_setting('max_offers')::int
  )
  insert into public.trip_offers (trip_id, driver_id, distance_km)
  select t.id, c.id, c.km from candidates c;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Internal: close all pending offers on a trip.
-- p_penalise = true when drivers simply did not answer (counts toward auto-busy).
create or replace function public.close_pending_offers(p_trip uuid, p_penalise boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  with missed as (
    update public.trip_offers
    set response = 'missed', responded_at = now()
    where trip_id = p_trip and response = 'pending'
    returning driver_id
  )
  update public.drivers d
  set missed_streak = d.missed_streak + 1,
      is_available  = case when d.missed_streak + 1 >= public.app_setting('missed_limit') then false
                           else d.is_available end
  where p_penalise and d.id in (select driver_id from missed);
end;
$$;

-- ---------------------------------------------------------------------------
-- Customers: request a trip
-- ---------------------------------------------------------------------------
create or replace function public.request_trip(
  p_service        public.service_type,
  p_trip_type      public.trip_type,
  p_vehicle        public.vehicle_type,
  p_pickup_address text,
  p_pickup_lat     double precision,
  p_pickup_lng     double precision,
  p_drop_address   text default null,
  p_drop_lat       double precision default null,
  p_drop_lng       double precision default null,
  p_hours          integer default null,
  p_note           text default null
)
returns table (trip_id uuid, drivers_notified integer)
language plpgsql
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_trip     public.trips;
  v_distance numeric;
  v_fare     integer;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and phone is not null) then
    raise exception 'Add your phone number before booking';
  end if;
  if exists (
    select 1 from public.trips
    where customer_id = auth.uid() and status in ('searching', 'accepted', 'arrived', 'started')
  ) then
    raise exception 'You already have a trip in progress';
  end if;
  if p_pickup_lat is null or p_pickup_lng is null or coalesce(trim(p_pickup_address), '') = '' then
    raise exception 'Pickup location is required';
  end if;
  if p_service = 'car_with_driver' and p_trip_type <> 'hourly'
     and (p_drop_lat is null or p_drop_lng is null) then
    raise exception 'Drop location is required';
  end if;
  if (p_service = 'driver_only' or p_trip_type = 'hourly') and (p_hours is null or p_hours < 1) then
    raise exception 'Choose how many hours you need';
  end if;

  if p_drop_lat is not null and p_drop_lng is not null then
    v_distance := public.approx_distance_km(p_pickup_lat, p_pickup_lng, p_drop_lat, p_drop_lng);
  end if;

  v_fare := public.estimate_fare(p_service, p_trip_type,
              case when p_service = 'car_with_driver' then coalesce(p_vehicle, 'hatchback') end,
              v_distance, p_hours);

  insert into public.trips (
    customer_id, service_type, trip_type, vehicle_type,
    pickup_address, pickup_location, pickup_lat, pickup_lng,
    drop_address, drop_location, drop_lat, drop_lng,
    distance_km, hours, fare_estimate, customer_note,
    search_radius_km, expires_at
  ) values (
    auth.uid(), p_service, p_trip_type,
    case when p_service = 'car_with_driver' then coalesce(p_vehicle, 'hatchback') end,
    trim(p_pickup_address), public.make_point(p_pickup_lat, p_pickup_lng), p_pickup_lat, p_pickup_lng,
    nullif(trim(p_drop_address), ''),
    case when p_drop_lat is not null and p_drop_lng is not null then public.make_point(p_drop_lat, p_drop_lng) end,
    case when p_drop_lng is not null then p_drop_lat end,
    case when p_drop_lat is not null then p_drop_lng end,
    v_distance, p_hours, v_fare, nullif(trim(p_note), ''),
    public.app_setting('start_radius_km')::int,
    now() + make_interval(secs => public.app_setting('offer_seconds'))
  )
  returning * into v_trip;

  trip_id := v_trip.id;
  drivers_notified := public.dispatch_offers(v_trip.id);
  return next;
end;
$$;

-- After the timer runs out with no accept: widen the area, or expire the trip.
create or replace function public.widen_search(p_trip uuid)
returns table (status public.trip_status, search_radius_km integer, drivers_notified integer)
language plpgsql
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  t public.trips;
begin
  select * into t from public.trips where id = p_trip for update;
  if not found or t.customer_id <> auth.uid() then
    raise exception 'Trip not found';
  end if;

  if t.status <> 'searching' then
    status := t.status; search_radius_km := t.search_radius_km; drivers_notified := 0;
    return next; return;
  end if;

  -- Ignore early calls (e.g. the phone clock is ahead)
  if t.expires_at > now() + interval '5 seconds' then
    status := t.status; search_radius_km := t.search_radius_km; drivers_notified := 0;
    return next; return;
  end if;

  perform public.close_pending_offers(t.id, true);

  if t.search_radius_km >= public.app_setting('max_radius_km') then
    update public.trips set status = 'expired' where id = t.id;
    status := 'expired'; search_radius_km := t.search_radius_km; drivers_notified := 0;
    return next; return;
  end if;

  update public.trips set
    search_radius_km = least(t.search_radius_km * 2, public.app_setting('max_radius_km')::int),
    expires_at       = now() + make_interval(secs => public.app_setting('offer_seconds'))
  where id = t.id
  returning * into t;

  status := t.status;
  search_radius_km := t.search_radius_km;
  drivers_notified := public.dispatch_offers(t.id);
  return next;
end;
$$;

-- ---------------------------------------------------------------------------
-- Drivers: accept (first wins) or skip
-- ---------------------------------------------------------------------------
create or replace function public.accept_trip(p_trip uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_won boolean;
begin
  if not exists (
    select 1 from public.drivers where id = auth.uid() and status = 'approved'
  ) then
    raise exception 'Your driver account is not approved';
  end if;

  if exists (
    select 1 from public.trips
    where driver_id = auth.uid() and status in ('accepted', 'arrived', 'started')
  ) then
    raise exception 'Finish your current trip first';
  end if;

  -- The WHERE clause makes this atomic: only one driver can flip
  -- 'searching' -> 'accepted'. Everyone else gets false.
  update public.trips
  set driver_id = auth.uid(), status = 'accepted', accepted_at = now()
  where id = p_trip
    and status = 'searching'
    and driver_id is null
    and exists (
      select 1 from public.trip_offers o
      where o.trip_id = p_trip and o.driver_id = auth.uid() and o.response = 'pending'
    );

  v_won := found;

  if not v_won then
    update public.trip_offers set response = 'missed', responded_at = now()
    where trip_id = p_trip and driver_id = auth.uid() and response = 'pending';
    return false;
  end if;

  update public.trip_offers set response = 'accepted', responded_at = now()
  where trip_id = p_trip and driver_id = auth.uid();

  -- someone else took it: no penalty for the other drivers
  perform public.close_pending_offers(p_trip, false);

  update public.drivers set is_available = false, missed_streak = 0 where id = auth.uid();
  return true;
end;
$$;

create or replace function public.skip_trip(p_trip uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.trip_offers set response = 'skipped', responded_at = now()
  where trip_id = p_trip and driver_id = auth.uid() and response = 'pending';

  if found then
    update public.drivers set missed_streak = 0 where id = auth.uid();
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Trip progress, cancel, rating, SOS
-- ---------------------------------------------------------------------------
create or replace function public.driver_update_trip(p_trip uuid, p_status public.trip_status)
returns public.trips
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.trips;
begin
  select * into t from public.trips where id = p_trip for update;
  if not found or t.driver_id is distinct from auth.uid() then
    raise exception 'Trip not found';
  end if;

  if not (
    (t.status = 'accepted' and p_status = 'arrived') or
    (t.status = 'arrived'  and p_status = 'started') or
    (t.status = 'started'  and p_status = 'completed')
  ) then
    raise exception 'Cannot change trip from % to %', t.status, p_status;
  end if;

  update public.trips set
    status       = p_status,
    arrived_at   = case when p_status = 'arrived'   then now() else arrived_at end,
    started_at   = case when p_status = 'started'   then now() else started_at end,
    completed_at = case when p_status = 'completed' then now() else completed_at end
  where id = p_trip
  returning * into t;

  return t;
end;
$$;

create or replace function public.cancel_trip(p_trip uuid, p_reason text default null)
returns public.trips
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.trips;
begin
  select * into t from public.trips where id = p_trip for update;
  if not found then
    raise exception 'Trip not found';
  end if;

  if t.customer_id = auth.uid() then
    if t.status not in ('searching', 'accepted', 'arrived') then
      raise exception 'This trip can no longer be cancelled';
    end if;
  elsif t.driver_id = auth.uid() then
    if t.status not in ('accepted', 'arrived') then
      raise exception 'This trip can no longer be cancelled';
    end if;
  else
    raise exception 'Trip not found';
  end if;

  update public.trips set
    status        = 'cancelled',
    cancelled_at  = now(),
    cancelled_by  = auth.uid(),
    cancel_reason = nullif(trim(p_reason), '')
  where id = p_trip
  returning * into t;

  perform public.close_pending_offers(p_trip, false);
  return t;
end;
$$;

create or replace function public.rate_trip(p_trip uuid, p_stars integer, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.trips;
  v_to uuid;
begin
  select * into t from public.trips where id = p_trip;
  if not found or t.status <> 'completed' then
    raise exception 'You can rate only completed trips';
  end if;
  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'Rating must be 1 to 5 stars';
  end if;

  if t.customer_id = auth.uid() then
    v_to := t.driver_id;
  elsif t.driver_id = auth.uid() then
    v_to := t.customer_id;
  else
    raise exception 'Trip not found';
  end if;

  insert into public.ratings (trip_id, from_user, to_user, stars, comment)
  values (p_trip, auth.uid(), v_to, p_stars::smallint, nullif(trim(p_comment), ''))
  on conflict (trip_id, from_user) do nothing;

  if found and v_to = t.driver_id then
    update public.drivers
    set rating_avg   = round(((rating_avg * rating_count) + p_stars) / (rating_count + 1), 2),
        rating_count = rating_count + 1
    where id = v_to;
  end if;
end;
$$;

create or replace function public.trigger_sos(
  p_trip uuid,
  p_lat double precision default null,
  p_lng double precision default null
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
begin
  if p_trip is not null and not exists (
    select 1 from public.trips where id = p_trip and (customer_id = auth.uid() or driver_id = auth.uid())
  ) then
    raise exception 'Trip not found';
  end if;

  insert into public.sos_events (trip_id, user_id, location)
  values (p_trip, auth.uid(),
          case when p_lat is not null and p_lng is not null then public.make_point(p_lat, p_lng) end)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_driver_status(p_driver uuid, p_status public.driver_status)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admins only';
  end if;
  update public.drivers
  set status = p_status,
      is_available = case when p_status = 'approved' then is_available else false end
  where id = p_driver;
end;
$$;

-- ---------------------------------------------------------------------------
-- Cleanup job: trips stuck in 'searching' because the customer closed the app
-- ---------------------------------------------------------------------------
create or replace function public.expire_stale_trips()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select id from public.trips
    where status = 'searching' and expires_at < now() - interval '1 minute'
    for update skip locked
  loop
    perform public.close_pending_offers(r.id, true);
    update public.trips set status = 'expired' where id = r.id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions: users may call only the public functions
-- ---------------------------------------------------------------------------
revoke all on function public.dispatch_offers(uuid)               from public, anon, authenticated;
revoke all on function public.close_pending_offers(uuid, boolean) from public, anon, authenticated;
revoke all on function public.expire_stale_trips()                from public, anon, authenticated;
revoke all on function public.handle_new_user()                   from public, anon, authenticated;

revoke all on function public.register_driver(boolean, public.vehicle_type, text, text, text) from public, anon;
revoke all on function public.set_driver_availability(boolean, double precision, double precision) from public, anon;
revoke all on function public.update_driver_location(double precision, double precision) from public, anon;
revoke all on function public.estimate_fare(public.service_type, public.trip_type, public.vehicle_type, numeric, integer) from public, anon;
revoke all on function public.approx_distance_km(double precision, double precision, double precision, double precision) from public, anon;
revoke all on function public.request_trip(public.service_type, public.trip_type, public.vehicle_type, text, double precision, double precision, text, double precision, double precision, integer, text) from public, anon;
revoke all on function public.widen_search(uuid) from public, anon;
revoke all on function public.accept_trip(uuid) from public, anon;
revoke all on function public.skip_trip(uuid) from public, anon;
revoke all on function public.driver_update_trip(uuid, public.trip_status) from public, anon;
revoke all on function public.cancel_trip(uuid, text) from public, anon;
revoke all on function public.rate_trip(uuid, integer, text) from public, anon;
revoke all on function public.trigger_sos(uuid, double precision, double precision) from public, anon;
revoke all on function public.admin_set_driver_status(uuid, public.driver_status) from public, anon;

grant execute on function public.register_driver(boolean, public.vehicle_type, text, text, text) to authenticated;
grant execute on function public.set_driver_availability(boolean, double precision, double precision) to authenticated;
grant execute on function public.update_driver_location(double precision, double precision) to authenticated;
grant execute on function public.estimate_fare(public.service_type, public.trip_type, public.vehicle_type, numeric, integer) to authenticated;
grant execute on function public.approx_distance_km(double precision, double precision, double precision, double precision) to authenticated;
grant execute on function public.request_trip(public.service_type, public.trip_type, public.vehicle_type, text, double precision, double precision, text, double precision, double precision, integer, text) to authenticated;
grant execute on function public.widen_search(uuid) to authenticated;
grant execute on function public.accept_trip(uuid) to authenticated;
grant execute on function public.skip_trip(uuid) to authenticated;
grant execute on function public.driver_update_trip(uuid, public.trip_status) to authenticated;
grant execute on function public.cancel_trip(uuid, text) to authenticated;
grant execute on function public.rate_trip(uuid, integer, text) to authenticated;
grant execute on function public.trigger_sos(uuid, double precision, double precision) to authenticated;
grant execute on function public.admin_set_driver_status(uuid, public.driver_status) to authenticated;
