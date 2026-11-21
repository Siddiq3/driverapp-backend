// One Edge Function for every trip action that needs a push notification.
//
// The app sends: POST /functions/v1/trip  { action: "...", ...params }
// with the user's normal Authorization header.
//
// Each action runs the database function AS THE USER (so all rules in the
// database apply), then sends pushes to the other side.
//
//   request  -> request_trip  -> push to drivers who got the offer
//   widen    -> widen_search  -> push to new drivers in the wider area
//   accept   -> accept_trip   -> push to the customer
//   update   -> driver_update_trip (arrived / started with PIN / completed) -> push to customer
//   cancel   -> cancel_trip   -> push to the other person

import { corsHeaders, errorResponse, json } from "../_shared/http.ts";
import { adminClient, userClient } from "../_shared/supabase.ts";
import { sendPush, type PushMessage } from "../_shared/push.ts";

type Body = Record<string, unknown> & { action?: string };

const SERVICE_LABEL: Record<string, string> = {
  car_with_driver: "Car + driver",
  driver_only: "Driver only",
};
const TRIP_LABEL: Record<string, string> = {
  local: "Local",
  outstation: "Outstation",
  hourly: "Hourly",
};

const isUuid = (v: unknown): v is string =>
  typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v);
const num = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : null;
const str = (v: unknown, max = 300): string | null =>
  typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return errorResponse("Method not allowed", 405);

  const auth = req.headers.get("Authorization");
  if (!auth) return errorResponse("Not signed in", 401);

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return errorResponse("Invalid request");
  }

  const db = userClient(auth);

  try {
    switch (body.action) {
      case "request":
        return await handleRequest(db, body);
      case "widen":
        return await handleWiden(db, body);
      case "accept":
        return await handleAccept(db, body);
      case "update":
        return await handleUpdate(db, body);
      case "cancel":
        return await handleCancel(db, body);
      default:
        return errorResponse("Unknown action");
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : "Something went wrong";
    return errorResponse(message);
  }
});

// ---------------------------------------------------------------------------

type Db = ReturnType<typeof userClient>;

async function handleRequest(db: Db, b: Body) {
  const startedAt = new Date(Date.now() - 2000).toISOString();
  const { data, error } = await db.rpc("request_trip", {
    p_service: b.service,
    p_trip_type: b.trip_type,
    p_vehicle: b.vehicle ?? null,
    p_pickup_address: str(b.pickup_address),
    p_pickup_lat: num(b.pickup_lat),
    p_pickup_lng: num(b.pickup_lng),
    p_drop_address: str(b.drop_address),
    p_drop_lat: num(b.drop_lat),
    p_drop_lng: num(b.drop_lng),
    p_hours: num(b.hours),
    p_note: str(b.note),
  });
  if (error) throw new Error(error.message);

  const row = Array.isArray(data) ? data[0] : data;
  await notifyNewOffers(row.trip_id, startedAt);
  return json({ trip_id: row.trip_id, drivers_notified: row.drivers_notified });
}

async function handleWiden(db: Db, b: Body) {
  if (!isUuid(b.trip_id)) return errorResponse("Trip not found");
  const startedAt = new Date(Date.now() - 2000).toISOString();
  const { data, error } = await db.rpc("widen_search", { p_trip: b.trip_id });
  if (error) throw new Error(error.message);

  const row = Array.isArray(data) ? data[0] : data;
  if (row?.drivers_notified > 0) await notifyNewOffers(b.trip_id, startedAt);
  return json(row);
}

async function handleAccept(db: Db, b: Body) {
  if (!isUuid(b.trip_id)) return errorResponse("Trip not found");
  const { data: won, error } = await db.rpc("accept_trip", { p_trip: b.trip_id });
  if (error) throw new Error(error.message);

  if (won) {
    const trip = await loadTrip(b.trip_id);
    if (trip?.customer?.push_token) {
      await sendPush([{
        to: trip.customer.push_token,
        title: "Driver found",
        body: `${trip.driver?.full_name ?? "Your driver"} accepted your trip.`,
        data: { trip_id: b.trip_id, type: "accepted" },
      }]);
    }
  }
  return json({ accepted: Boolean(won) });
}

async function handleUpdate(db: Db, b: Body) {
  if (!isUuid(b.trip_id)) return errorResponse("Trip not found");
  if (!["arrived", "started", "completed"].includes(String(b.status))) {
    return errorResponse("Invalid status");
  }
  const { data, error } = await db.rpc("driver_update_trip", {
    p_trip: b.trip_id,
    p_status: b.status,
    p_pin: b.status === "started" ? str(b.pin, 4) : null,
  });
  if (error) throw new Error(error.message);

  const trip = await loadTrip(b.trip_id);
  const token = trip?.customer?.push_token;
  if (token && b.status !== "started") {
    const msg: PushMessage = b.status === "arrived"
      ? { to: token, title: "Your driver has arrived", body: "Please meet your driver at the pickup point." }
      : { to: token, title: "Trip completed", body: "Please rate your driver. Thank you for riding!" };
    await sendPush([{ ...msg, data: { trip_id: b.trip_id, type: b.status } }]);
  }
  return json(data);
}

async function handleCancel(db: Db, b: Body) {
  if (!isUuid(b.trip_id)) return errorResponse("Trip not found");
  const { data, error } = await db.rpc("cancel_trip", {
    p_trip: b.trip_id,
    p_reason: str(b.reason),
  });
  if (error) throw new Error(error.message);

  const trip = await loadTrip(b.trip_id);
  if (trip?.driver_id) {
    const byCustomer = trip.cancelled_by === trip.customer_id;
    const other = byCustomer ? trip.driver : trip.customer;
    if (other?.push_token) {
      await sendPush([{
        to: other.push_token,
        title: "Trip cancelled",
        body: byCustomer ? "The customer cancelled this trip." : "Your driver cancelled. Please book again.",
        data: { trip_id: b.trip_id, type: "cancelled" },
      }]);
    }
  }
  return json(data);
}

// ---------------------------------------------------------------------------

type TripWithPeople = {
  id: string;
  customer_id: string;
  driver_id: string | null;
  cancelled_by: string | null;
  customer: { full_name: string | null; push_token: string | null } | null;
  driver: { full_name: string | null; push_token: string | null } | null;
};

async function loadTrip(tripId: string): Promise<TripWithPeople | null> {
  const { data } = await adminClient
    .from("trips")
    .select(
      "id, customer_id, driver_id, cancelled_by, " +
        "customer:profiles!trips_customer_id_fkey(full_name, push_token), " +
        "driver:drivers!trips_driver_id_fkey(profile:profiles!drivers_id_fkey(full_name, push_token))",
    )
    .eq("id", tripId)
    .maybeSingle();
  if (!data) return null;
  // deno-lint-ignore no-explicit-any
  const d = data as any;
  return { ...d, driver: d.driver?.profile ?? null };
}

async function notifyNewOffers(tripId: string, since: string) {
  const { data: trip } = await adminClient
    .from("trips")
    .select("service_type, trip_type, vehicle_type, fare_estimate, pickup_address")
    .eq("id", tripId)
    .maybeSingle();
  if (!trip) return;

  const { data: offers } = await adminClient
    .from("trip_offers")
    .select("distance_km, driver:drivers!trip_offers_driver_id_fkey(profile:profiles!drivers_id_fkey(push_token))")
    .eq("trip_id", tripId)
    .eq("response", "pending")
    .gte("sent_at", since);

  const kind = [SERVICE_LABEL[trip.service_type], TRIP_LABEL[trip.trip_type]].join(" · ");
  // deno-lint-ignore no-explicit-any
  const messages: PushMessage[] = (offers ?? []).map((o: any) => ({
    to: o.driver?.profile?.push_token ?? "",
    title: `New trip · ₹${trip.fare_estimate}`,
    body: `${kind} · ${o.distance_km ?? "?"} km away · ${trip.pickup_address}`,
    data: { trip_id: tripId, type: "offer" },
    channelId: "trip-requests",
  }));

  await sendPush(messages);
}
