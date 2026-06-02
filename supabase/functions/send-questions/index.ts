/**
 * send-questions — Supabase Edge Function
 *
 * Selects one question per invocation and delivers it to all registered devices
 * via a prep-then-visible push sequence:
 *   1. Two silent background "prep" pushes (~0s and ~20s) — wake the app to register a
 *      UNIQUE per-question answer-choice category (`question_category_<questionID>`) before
 *      the visible notification appears. Sending twice over a generous lead time tolerates
 *      best-effort background-push drops on watchOS.
 *   2. Visible alert push (after ~45 s) — the question the user sees and taps. Its
 *      `aps.category` matches the per-question category so a dropped prep push can never
 *      surface a previous question's answer buttons.
 *
 * Triggered by pg_cron: noon ET (UTC 16:00) and 6 PM ET (UTC 22:00).
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
  pushType: "alert" | "background" = "alert"
): Promise<{ ok: boolean; status: number; body: string }> {
  const res = await fetch(`https://api.push.apple.com/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${apnsToken}`,
      "apns-topic": bundleId,
      "apns-push-type": pushType,
      "apns-priority": pushType === "background" ? "5" : "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  return { ok: res.ok, status: res.status, body: await res.text() };
}

/** Selects a random question from the least-used pool and increments its usage count. */
async function pickOneQuestion(supabase: any) {
  const { data: minRow } = await supabase
    .from("questions")
    .select("times_used")
    .order("times_used", { ascending: true })
    .limit(1)
    .single();

  const minUsed = minRow?.times_used ?? 0;

  const { data: pool, error } = await supabase
    .from("questions")
    .select("*")
    .eq("times_used", minUsed);

  if (error) throw error;
  if (!pool || pool.length === 0) throw new Error("No questions available");

  const question = pool[Math.floor(Math.random() * pool.length)];

  await supabase
    .from("questions")
    .update({ times_used: question.times_used + 1 })
    .eq("id", question.id);

  return question;
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: { "Access-Control-Allow-Origin": "*" },
    });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const bundleId = Deno.env.get("APNS_BUNDLE_ID")!;
    const apnsToken = await getAPNsToken();

    const { data: devices, error: devErr } = await supabase
      .from("devices")
      .select("device_token, timezone");

    if (devErr) throw devErr;
    if (!devices || devices.length === 0) {
      return new Response(JSON.stringify({ message: "No devices registered" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Determine slot from UTC hour and pick exactly one question for it.
    const utcHour = new Date().getUTCHours();
    const slot: "noon" | "evening" = utcHour === 22 ? "evening" : "noon";
    const question = await pickOneQuestion(supabase);
    const deliveredAt = Math.floor(Date.now() / 1000);

    // Persist the active question so send-expirations knows the correct answer.
    await supabase
      .from("active_questions")
      .upsert({
        slot,
        question_id: question.id,
        correct_answer: question.correct,
        question_text: question.question,
        delivered_at: new Date().toISOString(),
        expiration_sent: false,
        is_answered: false,
      }, { onConflict: "slot" });

    const results = [];

    // Per-question category ID. watchOS renders a notification's answer buttons from the
    // UNNotificationCategory registered under this exact ID on-device — never from the push
    // payload. Using a UNIQUE ID per question guarantees a visible push can never inherit a
    // previous question's buttons: the worst case (prep push dropped) becomes "no buttons",
    // never the old question's "wrong buttons".
    const categoryID = `question_category_${question.id}`;

    // Sends the silent prep push to every device. The prep push wakes the app so it can
    // register `categoryID` with the real answer choices before the visible push renders.
    async function sendPrepRound(round: number) {
      for (const device of devices) {
        const silentPayload = {
          aps: { "content-available": 1 },
          questionID: question.id,
          choices: question.choices,
          correctAnswer: question.correct,
          categoryID,
          slot,
          deliveredAt,
          isPrepPush: true,
        };

        const result = await sendPush(device.device_token, silentPayload, apnsToken, bundleId, "background");
        console.log(`[APNs silent r${round}] token=...${device.device_token.slice(-6)} status=${result.status} body=${result.body}`);
        results.push({ token: device.device_token.slice(-6), push: `silent-r${round}`, ...result });
      }
    }

    // Two prep rounds spread over ~45s before the visible push. watchOS background
    // (content-available) pushes are best-effort and frequently throttled/dropped, and the
    // previous 5s gap was far too short for the watch to wake, run the extension, and commit
    // the category. Sending twice with a generous lead time makes a single dropped background
    // push non-fatal and gives slow-waking watches time to register the category.
    await sendPrepRound(1);
    await sleep(20000);
    await sendPrepRound(2);
    await sleep(25000);

    // Visible question notification — references the per-question category by ID.
    for (const device of devices) {
      const visiblePayload = {
        aps: {
          alert: { title: "NotiTrivia", body: question.question },
          sound: "default",
          category: categoryID,
        },
        questionID: question.id,
        choices: question.choices,
        correctAnswer: question.correct,
        categoryID,
        slot,
        deliveredAt,
        isPush: true,
      };

      const result = await sendPush(device.device_token, visiblePayload, apnsToken, bundleId, "alert");
      console.log(`[APNs visible] token=...${device.device_token.slice(-6)} status=${result.status} body=${result.body}`);
      results.push({ token: device.device_token.slice(-6), push: "visible", ...result });
    }

    return new Response(
      JSON.stringify({ slot, question: question.question, devices: devices.length, results }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});