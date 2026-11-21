import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** Acts as the signed-in user: database rules (RLS + auth.uid()) apply. */
export function userClient(authHeader: string): SupabaseClient {
  return createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Full access. Used ONLY to read push tokens after the user action succeeded. */
export const adminClient: SupabaseClient = createClient(url, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});
