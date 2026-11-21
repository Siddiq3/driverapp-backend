-- =============================================================================
-- Starting fares (rupees). THESE ARE PLACEHOLDERS — replace them with the real
-- local rates you collect from drivers. Edit later in the Supabase table editor
-- (table: fare_rates); no app update needed.
--
-- car_with_driver, local / outstation:  base_fare + per_km * km  (at least min_fare)
-- car_with_driver, hourly:              base_fare + per_hour * hours
-- driver_only (any trip type):          base_fare + per_hour * hours
-- =============================================================================

insert into public.fare_rates (service_type, trip_type, vehicle_key, base_fare, per_km, per_hour, min_fare) values
  ('car_with_driver', 'local',      'hatchback',  50, 14,   0,  150),
  ('car_with_driver', 'local',      'sedan',      60, 16,   0,  180),
  ('car_with_driver', 'local',      'suv',        80, 20,   0,  250),
  ('car_with_driver', 'outstation', 'hatchback',   0, 12,   0, 1500),
  ('car_with_driver', 'outstation', 'sedan',       0, 14,   0, 1800),
  ('car_with_driver', 'outstation', 'suv',         0, 18,   0, 2500),
  ('car_with_driver', 'hourly',     'hatchback',   0,  0, 250,  500),
  ('car_with_driver', 'hourly',     'sedan',       0,  0, 300,  600),
  ('car_with_driver', 'hourly',     'suv',         0,  0, 400,  800),
  ('driver_only',     'local',      'any',         0,  0, 150,  300),
  ('driver_only',     'outstation', 'any',       200,  0, 120, 1000),
  ('driver_only',     'hourly',     'any',         0,  0, 150,  300)
on conflict (service_type, trip_type, vehicle_key) do nothing;
