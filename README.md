# driverapp-backend

Backend for the driver & cab booking app. Built on **Supabase** (Postgres + PostGIS, Auth, Realtime, Edge Functions).

App repo: [driverapp-app](https://github.com/Siddiq3/driverapp-app)

## How it works

```
App ──► supabase.rpc(...)          reads, Free/Busy switch, location, rating, SOS
App ──► Edge Function "trip"       request / widen / accept / update / cancel  ──► Expo push ──► phones
App ◄── Realtime                   trip status (customer), new offers (driver)
```

- **First accept wins** inside the database: one `UPDATE … WHERE status = 'searching'`, so two drivers can never both get a trip.
- **Search grows**: 5 km → 10 km → 20 km, 2 minutes each, then the trip expires.
- **Auto-busy**: a driver who ignores 3 requests in a row is switched to Busy.
- **Security**: Row Level Security on every table. Users can't write to tables directly; every change goes through a checked function.

## Folder layout

```
supabase/
  migrations/
    ..._schema.sql             tables, enums, indexes
    ..._security.sql           Row Level Security + permissions
    ..._booking_logic.sql      request, accept, widen, status, cancel, rate, SOS, admin
    ..._realtime_and_jobs.sql  realtime tables + cleanup job every minute
    ..._default_fares.sql      starting fares (PLACEHOLDERS, edit them)
  functions/
    trip/                      the one Edge Function (actions + push notifications)
    _shared/                   push, http, supabase helpers
  config.toml
```

## Setup (one time)

1. **Create a Supabase project** (Mumbai region is closest for India).
2. **Enable extensions** in Dashboard → Database → Extensions: `postgis` and `pg_cron`.
3. **Install the CLI and link:**
   ```bash
   npm i -g supabase
   supabase login
   supabase link --project-ref <your-project-ref>
   ```
4. **Push the database:**
   ```bash
   supabase db push
   ```
5. **Google sign-in:** Dashboard → Authentication → Providers → Google → enable, paste your **Web** client ID + secret, and turn on *Skip nonce check*.
6. **Deploy the Edge Function:**
   ```bash
   supabase functions deploy trip
   ```
   Optional: `supabase secrets set EXPO_ACCESS_TOKEN=...` if you enable push security on Expo.
7. **Make yourself admin** (SQL editor):
   ```sql
   update profiles set is_admin = true where id = '<your-user-id>';
   ```

## Day-to-day admin (until the admin panel is built)

| Task | How |
| --- | --- |
| Approve a driver | Table editor → `drivers` → set `status` to `approved` (check the licence first). The admin panel will call `admin_set_driver_status()` |
| Change fares | Edit the `fare_rates` table — the app picks them up instantly |
| See SOS alerts | Table `sos_events` where `resolved = false` |
| Change timings (2 min, 5/10/20 km, 3 missed) | Edit `app_setting()` in a new migration |

## Moving to AWS later

Everything important is plain Postgres: `pg_dump` this database into AWS RDS / Aurora (with PostGIS) and the data, rules and booking functions move as they are. The `trip` Edge Function is TypeScript and ports to a Node.js Lambda with small changes. Users sign in with Google, so they just sign in again.
