-- =============================================================================
-- Driver prices + customer offers
-- Drivers enter their own prices when they register (per km / hour / day).
-- Customers see them and may offer their own price when sending a request.
-- The driver sees the offer and accepts, or calls to discuss.
-- =============================================================================

alter table public.drivers
  add column rate_per_km   integer check (rate_per_km   is null or rate_per_km   between 1 and 1000),
  add column rate_per_hour integer check (rate_per_hour is null or rate_per_hour between 1 and 10000),
  add column rate_per_day  integer check (rate_per_day  is null or rate_per_day  between 1 and 100000);

alter table public.trips
  add column customer_offer integer check (customer_offer is null or customer_offer between 50 and 200000);

create or replace function public.set_driver_rates(
  p_per_km   integer,
  p_per_hour integer,
  p_per_day  integer,
  p_note     text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(p_per_km, p_per_hour, p_per_day) is null then
    raise exception 'Please enter at least one price';
  end if;
  update public.drivers set
    rate_per_km   = case when has_car then nullif(p_per_km, 0) end,
    rate_per_hour = nullif(p_per_hour, 0),
    rate_per_day  = nullif(p_per_day, 0),
    rate_note     = nullif(trim(p_note), '')
  where id = auth.uid();
  if not found then
    raise exception 'You are not registered as a driver';
  end if;
end;
$$;

revoke all on function public.set_driver_rates(integer, integer, integer, text) from public, anon;
grant execute on function public.set_driver_rates(integer, integer, integer, text) to authenticated;

-- List of free drivers now includes their prices
drop function if exists public.free_drivers_near(double precision, double precision, integer, text);

create or replace function public.free_drivers_near(
  p_lat double precision,
  p_lng double precision,
  p_radius_km integer default 10,
  p_kind text default null
)
returns table (
  id uuid,
  full_name text,
  avatar_url text,
  has_car boolean,
  vehicle_type public.vehicle_type,
  vehicle_model text,
  rating_avg numeric,
  rating_count integer,
  rate_note text,
  rate_per_km integer,
  rate_per_hour integer,
  rate_per_day integer,
  distance_km numeric
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if p_lat is null or p_lng is null then
    return;
  end if;

  return query
  select d.id, p.full_name, p.avatar_url, d.has_car, d.vehicle_type, d.vehicle_model,
         d.rating_avg, d.rating_count, d.rate_note,
         d.rate_per_km, d.rate_per_hour, d.rate_per_day,
         round((st_distance(d.location, public.make_point(p_lat, p_lng)) / 1000.0)::numeric, 1)
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.status = 'approved'
    and d.is_available
    and d.id <> auth.uid()
    and d.location is not null
    and d.location_updated_at > now() - make_interval(mins => public.app_setting('location_fresh_min')::int)
    and st_dwithin(d.location, public.make_point(p_lat, p_lng), least(greatest(p_radius_km, 1), 20) * 1000)
    and (p_kind is null or (p_kind = 'car' and d.has_car) or p_kind = 'driver')
    and not exists (select 1 from public.trips x where x.driver_id = d.id and x.status in ('accepted', 'arrived', 'started'))
  order by st_distance(d.location, public.make_point(p_lat, p_lng))
  limit 50;
end;
$$;

revoke all on function public.free_drivers_near(double precision, double precision, integer, text) from public, anon;
grant execute on function public.free_drivers_near(double precision, double precision, integer, text) to authenticated;

-- Booking now takes the customer's offer
drop function if exists public.request_trip(public.service_type, public.trip_type, public.vehicle_type, text, double precision, double precision, text, double precision, double precision, integer, text, uuid);

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
  p_note           text default null,
  p_driver         uuid default null,     -- set when the customer picked a driver from the list
  p_offer          integer default null   -- the price the customer offers (optional, rupees)
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
  if p_offer is not null and (p_offer < 50 or p_offer > 200000) then
    raise exception 'Please enter a price between ₹50 and ₹2,00,000';
  end if;
  if p_pickup_lat is null or p_pickup_lng is null or coalesce(trim(p_pickup_address), '') = '' then
    raise exception 'Pickup location is required';
  end if;
  -- Requests to a chosen driver: details are agreed on the phone, so drop / hours are optional.
  if p_driver is null then
    if p_service = 'car_with_driver' and p_trip_type <> 'hourly'
       and (p_drop_lat is null or p_drop_lng is null) then
      raise exception 'Drop location is required';
    end if;
    if (p_service = 'driver_only' or p_trip_type = 'hourly') and (p_hours is null or p_hours < 1) then
      raise exception 'Choose how many hours you need';
    end if;
  else
    if p_driver = auth.uid() then
      raise exception 'You cannot book yourself';
    end if;
    if not exists (
      select 1 from public.drivers d
      where d.id = p_driver
        and d.status = 'approved'
        and d.is_available
        and d.location is not null
        and d.location_updated_at > now() - make_interval(mins => public.app_setting('location_fresh_min')::int)
        and st_dwithin(d.location, public.make_point(p_pickup_lat, p_pickup_lng), public.app_setting('max_radius_km') * 1000)
        and (p_service = 'driver_only' or d.has_car)
        and not exists (select 1 from public.trips x where x.driver_id = d.id and x.status in ('accepted', 'arrived', 'started'))
    ) then
      raise exception 'This driver is not free any more. Please choose another one.';
    end if;
  end if;

  if p_drop_lat is not null and p_drop_lng is not null then
    v_distance := public.approx_distance_km(p_pickup_lat, p_pickup_lng, p_drop_lat, p_drop_lng);
  end if;

  -- Price is agreed on the phone in v1; the estimate is kept for later use.
  begin
    v_fare := public.estimate_fare(p_service, p_trip_type,
                case when p_service = 'car_with_driver' then coalesce(p_vehicle, 'hatchback') end,
                v_distance, p_hours);
  exception when others then
    v_fare := 0;
  end;

  insert into public.trips (
    customer_id, service_type, trip_type, vehicle_type,
    pickup_address, pickup_location, pickup_lat, pickup_lng,
    drop_address, drop_location, drop_lat, drop_lng,
    distance_km, hours, fare_estimate, customer_note,
    search_radius_km, expires_at, requested_driver_id, customer_offer
  ) values (
    auth.uid(), p_service, p_trip_type,
    case when p_service = 'car_with_driver' then
      coalesce(p_vehicle, (select vehicle_type from public.drivers where id = p_driver), 'hatchback') end,
    trim(p_pickup_address), public.make_point(p_pickup_lat, p_pickup_lng), p_pickup_lat, p_pickup_lng,
    nullif(trim(p_drop_address), ''),
    case when p_drop_lat is not null and p_drop_lng is not null then public.make_point(p_drop_lat, p_drop_lng) end,
    case when p_drop_lng is not null then p_drop_lat end,
    case when p_drop_lat is not null then p_drop_lng end,
    v_distance, p_hours, v_fare, nullif(trim(p_note), ''),
    public.app_setting('start_radius_km')::int,
    now() + make_interval(secs => public.app_setting('offer_seconds')),
    p_driver,
    p_offer
  )
  returning * into v_trip;

  trip_id := v_trip.id;
  drivers_notified := public.dispatch_offers(v_trip.id);
  return next;
end;
$$;

revoke all on function public.request_trip(public.service_type, public.trip_type, public.vehicle_type, text, double precision, double precision, text, double precision, double precision, integer, text, uuid, integer) from public, anon;
grant execute on function public.request_trip(public.service_type, public.trip_type, public.vehicle_type, text, double precision, double precision, text, double precision, double precision, integer, text, uuid, integer) to authenticated;
