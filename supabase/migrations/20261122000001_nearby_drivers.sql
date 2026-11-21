-- =============================================================================
-- Nearby free drivers for the customer home map.
-- Returns approximate positions only (rounded to ~100 m, no names or ids),
-- so customers can see that drivers are around without tracking anyone.
-- =============================================================================

create or replace function public.nearby_drivers(
  p_lat double precision,
  p_lng double precision,
  p_radius_km integer default 5
)
returns table (lat double precision, lng double precision, has_car boolean, vehicle_type public.vehicle_type)
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
  select
    round(st_y(d.location::geometry)::numeric, 3)::double precision,
    round(st_x(d.location::geometry)::numeric, 3)::double precision,
    d.has_car,
    d.vehicle_type
  from public.drivers d
  where d.status = 'approved'
    and d.is_available
    and d.id <> auth.uid()
    and d.location is not null
    and d.location_updated_at > now() - make_interval(mins => public.app_setting('location_fresh_min')::int)
    and st_dwithin(d.location, public.make_point(p_lat, p_lng), least(greatest(p_radius_km, 1), 20) * 1000)
  order by st_distance(d.location, public.make_point(p_lat, p_lng))
  limit 30;
end;
$$;

revoke all on function public.nearby_drivers(double precision, double precision, integer) from public, anon;
grant execute on function public.nearby_drivers(double precision, double precision, integer) to authenticated;
