-- ============================================================================
-- Only commercial (yellow-plate) cars can be listed for hire.
--
-- A private (white-plate) car carrying paying passengers breaks the Motor
-- Vehicles Act, so a driver who lists "my car" must confirm a yellow plate and
-- give the taxi/tourist permit number. Admins check the RC and permit before
-- approval. Drivers without a car (driving the customer's own car) need
-- neither.
-- ============================================================================

alter table public.drivers
  add column commercial_plate boolean not null default false,
  add column permit_number    text;

comment on column public.drivers.commercial_plate is
  'Driver confirmed the car has a yellow (commercial) number plate.';
comment on column public.drivers.permit_number is
  'Taxi / tourist permit number of the car. Required when has_car.';

-- Car listings must be commercial. NOT VALID so rows created before this
-- migration don't block it; admins fix those by hand (see the query below).
alter table public.drivers
  add constraint car_must_be_commercial check (
    has_car = false or (commercial_plate and coalesce(trim(permit_number), '') <> '')
  ) not valid;

-- Rows created before this rule: hide their car until they add a permit.
-- They keep getting "drive the customer's car" trips.
update public.drivers
   set has_car = false, is_available = false
 where has_car and (not commercial_plate or coalesce(trim(permit_number), '') = '');

-- ---------------------------------------------------------------------------
-- register_driver: new version with plate + permit
-- ---------------------------------------------------------------------------
drop function if exists public.register_driver(boolean, public.vehicle_type, text, text, text);

create or replace function public.register_driver(
  p_has_car          boolean,
  p_vehicle_type     public.vehicle_type,
  p_vehicle_model    text,
  p_vehicle_number   text,
  p_licence_number   text,
  p_commercial_plate boolean default false,
  p_permit_number    text default null
)
returns public.drivers
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_driver public.drivers;
  v_number text := upper(regexp_replace(coalesce(p_vehicle_number, ''), '[\s-]', '', 'g'));
  v_permit text := upper(trim(coalesce(p_permit_number, '')));
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if coalesce(trim(p_licence_number), '') = '' then
    raise exception 'Driving licence number is required';
  end if;
  if p_has_car then
    if p_vehicle_type is null or v_number = '' then
      raise exception 'Car type and number are required';
    end if;
    if not coalesce(p_commercial_plate, false) then
      raise exception 'Only cars with a yellow (commercial) number plate can be listed';
    end if;
    if v_permit = '' then
      raise exception 'Taxi permit number is required';
    end if;
  end if;

  insert into public.drivers (
    id, has_car, vehicle_type, vehicle_model, vehicle_number, licence_number,
    commercial_plate, permit_number
  )
  values (
    auth.uid(),
    p_has_car,
    case when p_has_car then p_vehicle_type end,
    case when p_has_car then nullif(trim(p_vehicle_model), '') end,
    case when p_has_car then v_number end,
    upper(trim(p_licence_number)),
    case when p_has_car then true else false end,
    case when p_has_car then v_permit end
  )
  on conflict (id) do update set
    has_car          = excluded.has_car,
    vehicle_type     = excluded.vehicle_type,
    vehicle_model    = excluded.vehicle_model,
    vehicle_number   = excluded.vehicle_number,
    licence_number   = excluded.licence_number,
    commercial_plate = excluded.commercial_plate,
    permit_number    = excluded.permit_number,
    status = case
      -- a rejected driver who edits details goes back into the review queue
      when public.drivers.status = 'rejected' then 'pending'::public.driver_status
      -- an approved driver who adds or changes a car is checked again
      when public.drivers.status = 'approved'
           and excluded.has_car
           and (not public.drivers.has_car
                or public.drivers.vehicle_number is distinct from excluded.vehicle_number
                or public.drivers.permit_number  is distinct from excluded.permit_number)
        then 'pending'::public.driver_status
      else public.drivers.status
    end,
    is_available = case
      when public.drivers.status = 'approved'
           and excluded.has_car
           and (not public.drivers.has_car
                or public.drivers.vehicle_number is distinct from excluded.vehicle_number
                or public.drivers.permit_number  is distinct from excluded.permit_number)
        then false
      else public.drivers.is_available
    end
  returning * into v_driver;

  update public.profiles set role = 'driver' where id = auth.uid();
  return v_driver;
end;
$$;

revoke all on function public.register_driver(boolean, public.vehicle_type, text, text, text, boolean, text) from public, anon;
grant execute on function public.register_driver(boolean, public.vehicle_type, text, text, text, boolean, text) to authenticated;
