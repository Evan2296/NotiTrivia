/**
 * send-expirations — Supabase Edge Function
 *
 * Sends alert pushes to all registered devices for any active questions that have
 * not yet been answered or expired, then atomically marks them as expiration-sent
 * to prevent duplicate pushes. Skips any slot already resolved by mark-answered.
 *
 * Triggered by pg_cron: 1 hour after each send-questions invocation.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { SignJWT, importPKCS8 } from "https://deno.land/x/jose@v4.14.4/index.ts";

async function getAPNsToken(): Promise<string> {
  const rawKey = Deno.env.get("APNS_PRIVATE_KEY") ?? "";
  const privateKeyPem = rawKey.replace(/\\n/g, "\n");
  const keyId = Deno.env.get("APNS_KEY_ID")!;
  const teamId = Deno.env.get("APNS_TEAM_ID")!;
  const privateKey = await importPKCS8(privateKeyPem, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .sign(privateKey);
}

async function sendPush(
  deviceToken: string,
  payload: object,
  apnsToken: string,
  bundleId: string,
): Promise<{ ok: boolean; status: number; body: string }> {
  const res = await fetch(`https://api.push.apple.com/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${apnsToken}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  return { ok: res.ok, status: res.status, body: await res.text() };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*" } });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const bundleId = Deno.env.get("APNS_BUNDLE_ID")!;
    const apnsToken = await getAPNsToken();

    // Fetch all slots that are still pending expiration.
    // Querying by flag rather than UTC hour works for both production and testing schedules.
    const { data: pendingExpirations, error } = await supabase
      .from("active_questions")
      .select("*")
      .eq("expiration_sent", false)
      .eq("is_answered", false);

    if (error) throw error;
    if (!pendingExpirations || pendingExpirations.length === 0) {
      return new Response(
        JSON.stringify({ message: "No pending expirations" }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    const { data: devices, error: devErr } = await supabase
      .from("devices")
      .select("device_token");

    if (devErr) throw devErr;

    const results = [];

    for (const activeQuestion of pendingExpirations) {
      // Atomic claim: only updates if mark-answered hasn't already resolved this slot.
      // If it has, 0 rows match and `claimed` is null — skip the push to prevent a double expiration.
      const { data: claimed } = await supabase
        .from("active_questions")
        .update({ expiration_sent: true })
        .eq("slot", activeQuestion.slot)
        .eq("is_answered", false)
        .eq("expiration_sent", false)
        .select()
        .single();

      if (!claimed) {
        console.log(`[send-expirations] slot=${activeQuestion.slot} already answered — skipping expiration push`);
        continue;
      }

      for (const device of devices ?? []) {
        // Priority-10 alert push delivers even when the watch is inactive or charging.
        const payload = {
          aps: {
            alert: {
              title: "⏰ Time Expired",
              body: `The correct answer was: ${activeQuestion.correct_answer}`,
            },
            sound: "default",
            "content-available": 1,
          },
          isExpiration: true,
          slot: activeQuestion.slot,
          correctAnswer: activeQuestion.correct_answer,
          // questionID and deliveredAt are required by activateQuestion() on the client.
          // If APNs dropped the silent prep push, AppDelegate uses these fields to reconstruct
          // a QuestionState before calling markExpired, so the life debit fires regardless.
          questionID: activeQuestion.question_id,
          deliveredAt: Math.floor(new Date(activeQuestion.delivered_at).getTime() / 1000),
        };

        const result = await sendPush(device.device_token, payload, apnsToken, bundleId);
        console.log(`[APNs expiration] token=...${device.device_token.slice(-6)} slot=${activeQuestion.slot} status=${result.status} body=${result.body}`);
        results.push({ token: device.device_token.slice(-6), slot: activeQuestion.slot, ...result });
      }
    }

    return new Response(
      JSON.stringify({ slots: pendingExpirations.map(q => q.slot), devices: devices?.length ?? 0, results }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});