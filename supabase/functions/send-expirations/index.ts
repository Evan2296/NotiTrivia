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

    // Fetch all slots that haven't been expired yet.
    // This works for both production (1hr cron offset) and testing (10min cron offset)
    // without needing to guess the slot from UTC hour.
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
      // Atomically claim this expiration by flipping expiration_sent = true BEFORE
      // sending the push, with is_answered = false in the WHERE clause.
      // If mark-answered already ran and set is_answered = true, this update matches
      // 0 rows and `claimed` will be null — we skip the push entirely, closing the
      // race window between the initial SELECT and the push delivery.
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
        // Alert push — delivers reliably even when the watch is inactive/charging.
        // content-available:1 ensures AppDelegate.didReceiveRemoteNotification fires
        // to mark the question expired and update streak/lives on-device.
        // The push itself IS the expiration notification — the app does not fire
        // an additional local result notification for server-sent expirations.
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