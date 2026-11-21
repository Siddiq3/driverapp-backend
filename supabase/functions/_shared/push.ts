// Sends push notifications through Expo's free push service.
// Expo forwards them to Firebase Cloud Messaging (Android) / APNs (iOS).

export type PushMessage = {
  to: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
  channelId?: "trip-requests" | "trip-updates";
};

const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";

export async function sendPush(messages: PushMessage[]): Promise<void> {
  const valid = messages.filter((m) => m.to?.startsWith("ExponentPushToken") || m.to?.startsWith("ExpoPushToken"));
  if (valid.length === 0) return;

  // Expo accepts up to 100 messages per request
  for (let i = 0; i < valid.length; i += 100) {
    const batch = valid.slice(i, i + 100).map((m) => ({
      to: m.to,
      title: m.title,
      body: m.body,
      data: m.data ?? {},
      sound: "default",
      priority: "high",
      channelId: m.channelId ?? "trip-updates",
    }));

    try {
      const headers: Record<string, string> = {
        "Content-Type": "application/json",
        Accept: "application/json",
      };
      const accessToken = Deno.env.get("EXPO_ACCESS_TOKEN");
      if (accessToken) headers.Authorization = `Bearer ${accessToken}`;

      const res = await fetch(EXPO_PUSH_URL, { method: "POST", headers, body: JSON.stringify(batch) });
      if (!res.ok) console.error("Expo push failed", res.status, await res.text());
    } catch (err) {
      // A failed push must never fail the booking itself
      console.error("Expo push error", err);
    }
  }
}
