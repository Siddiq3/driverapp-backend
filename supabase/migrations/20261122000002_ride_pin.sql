-- =============================================================================
-- Ride PIN (like Uber / Rapido): when a driver accepts, the customer gets a
-- 4-digit PIN. The driver must enter it to start the trip, so the customer
-- always gets into the right car with the right driver.
-- The PIN lives in its own table so drivers can never read it.
-- =============================================================================

create table public.trip_pins (
  trip_id    uuid primary key references public.trips (id) on delete cascade,
  pin        text not null check (pin ~ '^[0-9]{4}$'),
  created_at timestamptz not null default now()
);

alter table public.trip_pins enable row level security;
revoke all on public.trip_pins from anon, authenticated;

-- Customer reads the PIN of their own trip
create or replace function public.get_trip_pin(p_trip uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.pin
  from public.trip_pins p
  join public.trips t on t.id = p.trip_id
  where p.trip_id = p_trip
    and t.customer_id = auth.uid()
    and t.status in ('accepted', 'arrived');
$$;

revoke all on function public.get_trip_pin(uuid) from public, anon;
grant execute on function public.get_trip_pin(uuid) to authenticated;

-- Create the PIN the moment a driver is assigned
create or replace function public.create_trip_pin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'accepted' and old.status = 'searching' then
    insert into public.trip_pins (trip_id, pin)
    values (new.id, lpad((floor(random() * 10000))::int::text, 4, '0'))
    on conflict (trip_id) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function public.create_trip_pin() from public, anon, authenticated;

create trigger trips_create_pin
  after update of status on public.trips
  for each row execute function public.create_trip_pin();

-- Driver status changes now need the PIN to start
drop function if exists public.driver_update_trip(uuid, public.trip_status);

create or replace function public.driver_update_trip(
  p_trip   uuid,
  p_status public.trip_status,
  p_pin    text default null
)
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
    (t.status in ('accepted', 'arrived') and p_status = 'started') or
    (t.status = 'started'  and p_status = 'completed')
  ) then
    raise exception 'Cannot change trip from % to %', t.status, p_status;
  end if;

  if p_status = 'started' and not exists (
    select 1 from public.trip_pins where trip_id = p_trip and pin = trim(coalesce(p_pin, ''))
  ) then
    raise exception 'Wrong PIN. Ask the customer for the 4-digit PIN shown in their app.';
  end if;

  update public.trips set
    status       = p_status,
    arrived_at   = case when p_status = 'arrived' then now()
                        when p_status = 'started' then coalesce(arrived_at, now())
                        else arrived_at end,
    started_at   = case when p_status = 'started'   then now() else started_at end,
    completed_at = case when p_status = 'completed' then now() else completed_at end
  where id = p_trip
  returning * into t;

  return t;
end;
$$;

revoke all on function public.driver_update_trip(uuid, public.trip_status, text) from public, anon;
grant execute on function public.driver_update_trip(uuid, public.trip_status, text) to authenticated;
