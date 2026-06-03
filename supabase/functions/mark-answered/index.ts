/**
 * mark-answered — Supabase Edge Function
 *
 * Marks the active question for a given delivery slot as answered in the database,
 * preventing send-expirations from sending a redundant expiration push.
 * Called by the watchOS client immediately after the user taps an answer button.
 *
 * The `slot` field must be a timezone-qualified key matching the active_questions row,
 * e.g. "noon_16" or "evening_4" (slot name + UTC hour at which the question was
 * delivered).  The Swift client derives the UTC hour from the `deliveredAt` Unix
 * timestamp embedded in the original push payload, so the key is always consistent
 * with what send-questions wrote when it upserted the row.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*" } });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { slot } = await req.json();

    // Accept timezone-qualified slot keys like "noon_16" or "evening_4".
    // The base name (everything before the first "_") must be "noon" or "evening".
    const baseSlot = typeof slot === "string" ? slot.split("_")[0] : "";
    if (!slot || !["noon", "evening"].includes(baseSlot)) {
      return new Response(
        JSON.stringify({ error: "Invalid or missing slot — expected format: \"noon_<utcHour>\" or \"evening_<utcHour>\"" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    const { error } = await supabase
      .from("active_questions")
      .update({ is_answered: true })
      .eq("slot", slot);

    if (error) throw error;

    console.log(`[mark-answered] slot=${slot} marked as answered`);

    return new Response(
      JSON.stringify({ success: true, slot }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
