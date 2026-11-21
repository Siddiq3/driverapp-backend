-- =============================================================================
-- Driver & Cab booking — core schema
-- Tables, enums, indexes, updated_at triggers and the new-user profile trigger.
-- Business logic lives in 20261121000003_booking_logic.sql
-- Security rules live in 20261121000002_security.sql
-- =============================================================================

create extension if not exists postgis with schema extensions;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.user_role      as enum ('customer', 'driver');
create type public.driver_status  as enum ('pending', 'approved', 'rejected', 'blocked');
create type public.vehicle_type   as enum ('hatchback', 'sedan', 'suv');
create type public.service_type   as enum ('car_with_driver', 'driver_only');
create type public.trip_type      as enum ('local', 'outstation', 'hourly');
create type public.trip_status    as enum ('searching', 'accepted', 'arrived', 'started', 'completed', 'cancelled', 'expired');
create type public.offer_response as enum ('pending', 'accepted', 'skipped', 'missed');

-- ---------------------------------------------------------------------------
-- updated_at helper
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- profiles: one row per signed-in user (customers and drivers)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text,
  phone       text check (phone is null or phone ~ '^\+?[0-9]{10,13}$'),
  role        public.user_role not null default 'customer',  -- the mode the app opens in
  is_admin    boolean not null default false,
  push_token  text,                                          -- Expo push token
  avatar_url  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Create a profile automatically when someone signs in for the first time.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- drivers: extra details for users who drive
-- ---------------------------------------------------------------------------
create table public.drivers (
  id                  uuid primary key references public.profiles (id) on delete cascade,
  has_car             boolean not null default false,
  vehicle_type        public.vehicle_type,
  vehicle_model       text,
  vehicle_number      text,
  licence_number      text not null,
  status              public.driver_status not null default 'pending',
  is_available        boolean not null default false,       -- the Free / Busy switch
  location            extensions.geography (point, 4326),
  location_updated_at timestamptz,
  rating_avg          numeric(3, 2) not null default 0,
  rating_count        integer not null default 0,
  missed_streak       integer not null default 0,           -- requests ignored in a row
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint car_details_required check (
    has_car = false or (vehicle_type is not null and vehicle_number is not null)
  )
);

create index drivers_location_idx  on public.drivers using gist (location);
create index drivers_available_idx on public.drivers (status, is_available);

create trigger drivers_updated_at
  before update on public.drivers
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- fare_rates: prices set by the admin (rupees)
-- vehicle_key = 'any' for driver-only bookings
-- ---------------------------------------------------------------------------
create table public.fare_rates (
  id            serial primary key,
  service_type  public.service_type not null,
  trip_type     public.trip_type not null,
  vehicle_key   text not null default 'any',
  base_fare     integer not null default 0,
  per_km        integer not null default 0,
  per_hour      integer not null default 0,
  min_fare      integer not null default 0,
  updated_at    timestamptz not null default now(),
  unique (service_type, trip_type, vehicle_key)
);

create trigger fare_rates_updated_at
  before update on public.fare_rates
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- trips: one booking
-- ---------------------------------------------------------------------------
create table public.trips (
  id                uuid primary key default gen_random_uuid(),
  customer_id       uuid not null references public.profiles (id) on delete cascade,
  driver_id         uuid references public.drivers (id) on delete set null,
  service_type      public.service_type not null,
  trip_type         public.trip_type not null,
  vehicle_type      public.vehicle_type,                     -- only for car_with_driver
  pickup_address    text not null,
  pickup_location   extensions.geography (point, 4326) not null,
  pickup_lat        double precision not null,   -- plain copies for the app (maps, navigation)
  pickup_lng        double precision not null,
  drop_address      text,
  drop_location     extensions.geography (point, 4326),
  drop_lat          double precision,
  drop_lng          double precision,
  distance_km       numeric(7, 1),
  hours             integer check (hours is null or hours between 1 and 72),
  fare_estimate     integer not null,
  customer_note     text check (customer_note is null or length(customer_note) <= 300),
  status            public.trip_status not null default 'searching',
  search_radius_km  integer not null default 5,
  expires_at        timestamptz not null,
  accepted_at       timestamptz,
  arrived_at        timestamptz,
  started_at        timestamptz,
  completed_at      timestamptz,
  cancelled_at      timestamptz,
  cancelled_by      uuid references public.profiles (id),
  cancel_reason     text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index trips_customer_idx on public.trips (customer_id, created_at desc);
create index trips_driver_idx   on public.trips (driver_id, created_at desc);
create index trips_status_idx   on public.trips (status, expires_at);

create trigger trips_updated_at
  before update on public.trips
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- trip_offers: which drivers received a request and how they answered
-- ---------------------------------------------------------------------------
create table public.trip_offers (
  trip_id       uuid not null references public.trips (id) on delete cascade,
  driver_id     uuid not null references public.drivers (id) on delete cascade,
  distance_km   numeric(6, 1),
  response      public.offer_response not null default 'pending',
  sent_at       timestamptz not null default now(),
  responded_at  timestamptz,
  primary key (trip_id, driver_id)
);

create index trip_offers_driver_idx on public.trip_offers (driver_id, response);

-- ---------------------------------------------------------------------------
-- ratings: both sides rate each other after a trip
-- ---------------------------------------------------------------------------
create table public.ratings (
  id          bigserial primary key,
  trip_id     uuid not null references public.trips (id) on delete cascade,
  from_user   uuid not null references public.profiles (id) on delete cascade,
  to_user     uuid not null references public.profiles (id) on delete cascade,
  stars       smallint not null check (stars between 1 and 5),
  comment     text check (comment is null or length(comment) <= 500),
  created_at  timestamptz not null default now(),
  unique (trip_id, from_user)
);

-- ---------------------------------------------------------------------------
-- sos_events: emergency button presses
-- ---------------------------------------------------------------------------
create table public.sos_events (
  id          bigserial primary key,
  trip_id     uuid references public.trips (id) on delete set null,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  location    extensions.geography (point, 4326),
  resolved    boolean not null default false,
  created_at  timestamptz not null default now()
);
