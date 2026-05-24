/**
 * register-device — Supabase Edge Function
 *
 * Upserts a device's APNs token and IANA timezone identifier into the `devices` table.
 * Re-registering an existing token updates its `last_seen` timestamp and timezone.
 * Called by the watchOS app each time it successfully registers for remote notifications.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  try {
    const { device_token, timezone } = await req.json();

    if (!device_token) {
      return new Response(JSON.stringify({ error: "device_token is required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Upsert — if token already exists just update last_seen and timezone
    const { error } = await supabase
      .from("devices")
      .upsert(
        {
          device_token,
          timezone: timezone ?? "America/New_York",
          last_seen: new Date().toISOString(),
        },
        { onConflict: "device_token" }
      );

    if (error) throw error;

    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});