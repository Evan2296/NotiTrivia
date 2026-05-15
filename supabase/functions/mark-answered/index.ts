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

    if (!slot || !["noon", "evening"].includes(slot)) {
      return new Response(
        JSON.stringify({ error: "Invalid or missing slot" }),
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