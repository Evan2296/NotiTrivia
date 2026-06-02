/**
 * send-expirations — Supabase Edge Function
 *
 * Timezone-aware expiration delivery: runs every hour and sends "time's up"
 * pushes only to devices where it is currently 1 PM (13:00) or 7 PM (19:00)
 * local time — exactly one hour after the noon and evening question windows.
 *
 * For each slot (noon / evening) that has a pending, unanswered active question,
 * the function atomically claims the expiration and pushes only to the devices
 * whose local time matches that slot's expiration hour:
 *   • noon    expiration → local hour == 13
 *   • evening expiration → local hour == 19
 *
 * This ensures that a user in Shanghai never gets NYC's expiration push and
 * vice versa — everyone receives the "correct answer" reveal exactly 1 hour
 * after their own local delivery.
 *
 * Triggered by pg_cron: every hour at :00 (0 * * * *).
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

/**
 * Returns the current local hour (0–23) for the given IANA timezone identifier.
 * Returns -1 if the timezone is invalid or unrecognised.
 */
function getLocalHour(timezone: string): number {
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      hour: "numeric",
      hour12: false,
    }).formatToParts(new Date());
    const hourStr = parts.find(p => p.type === "hour")?.value ?? "0";
    const hour = parseInt(hourStr, 10);
    return hour === 24 ? 0 : hour; // Intl returns "24" for midnight in some runtimes
  } catch {
    return -1; // invalid timezone → skip device
  }
}

/** The local hour at which each slot's expiration is sent (delivery hour + 1). */
const EXPIRATION_HOUR: Record<string, number> = {
  noon:    13,
  evening: 19,
};

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

    // Fetch all devices with their timezones so we can filter by local hour.
    const { data: devices, error: devErr } = await supabase
      .from("devices")
      .select("device_token, timezone");

    if (devErr) throw devErr;

    const results = [];

    for (const activeQuestion of pendingExpirations) {
      const expirationHour = EXPIRATION_HOUR[activeQuestion.slot];
      if (expirationHour === undefined) {
        console.log(`[send-expirations] unknown slot=${activeQuestion.slot} — skipping`);
        continue;
      }

      // Only send to devices where it is currently the expiration hour for this slot.
      const eligibleDevices = (devices ?? []).filter(
        d => getLocalHour(d.timezone) === expirationHour
      );

      if (eligibleDevices.length === 0) {
        console.log(`[send-expirations] slot=${activeQuestion.slot} — no devices at local hour ${expirationHour} right now`);
        continue;
      }

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

      for (const device of eligibleDevices) {
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
        console.log(`[APNs expiration] token=...${device.device_token.slice(-6)} tz=${device.timezone} slot=${activeQuestion.slot} status=${result.status} body=${result.body}`);
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
