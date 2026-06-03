/**
 * send-questions — Supabase Edge Function
 *
 * Timezone-aware question delivery: runs every hour and delivers questions
 * only to devices where the local time is currently noon (12:00) or 6 PM (18:00).
 * Each group (noon / evening) independently picks one question so that, e.g.,
 * a Shanghai user and a New York user each get their own question at their
 * respective local noon and 6 PM.
 *
 * Sequence per device group:
 *   1. Two silent background "prep" pushes (~0s and ~20s) — wake the app to register a
 *      UNIQUE per-question answer-choice category (`question_category_<questionID>`) before
 *      the visible notification appears. Sending twice over a generous lead time tolerates
 *      best-effort background-push drops on watchOS.
 *   2. Visible alert push (after ~45 s) — the question the user sees and taps. Its
 *      `aps.category` matches the per-question category so a dropped prep push can never
 *      surface a previous question's answer buttons.
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

/**
 * Delivers one question to a group of devices via the prep → visible push sequence.
 * Returns an array of result objects for logging.
 */
async function deliverToGroup(
  devices: Array<{ device_token: string; timezone: string }>,
  question: any,
  slot: "noon" | "evening",
  apnsToken: string,
  bundleId: string,
  supabase: any
): Promise<object[]> {
  const results: object[] = [];
  const categoryID = `question_category_${question.id}`;
  const deliveredAt = Math.floor(Date.now() / 1000);

  // Build a timezone-qualified slot key such as "noon_16" (noon question delivered at
  // UTC hour 16). Including the UTC delivery hour prevents parallel deliveries to
  // different timezone groups from overwriting each other's active_questions row —
  // which would cause send-expirations to reveal the wrong correct answer to users
  // whose row was clobbered by a later-timezone group.
  const utcHour = new Date().getUTCHours();
  const slotKey = `${slot}_${utcHour}`;

  // Persist the active question so send-expirations knows the correct answer.
  // Keyed by slotKey (not bare slot) so each timezone-group delivery has its own row.
  await supabase
    .from("active_questions")
    .upsert({
      slot: slotKey,
      question_id: question.id,
      correct_answer: question.correct,
      question_text: question.question,
      delivered_at: new Date().toISOString(),
      expiration_sent: false,
      is_answered: false,
    }, { onConflict: "slot" });

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
      console.log(`[APNs silent r${round} ${slot}] token=...${device.device_token.slice(-6)} tz=${device.timezone} status=${result.status} body=${result.body}`);
      results.push({ token: device.device_token.slice(-6), slot, push: `silent-r${round}`, ...result });
    }
  }

  // Two prep rounds spread over ~45s before the visible push.
  await sendPrepRound(1);
  await sleep(20000);
  await sendPrepRound(2);
  await sleep(25000);

  // Visible question notification — references the per-question category by ID.
  //
  // "content-available": 1 is intentionally included on this alert push. It causes
  // didReceiveRemoteNotification(_:fetchCompletionHandler:) to fire on-device even
  // when the app is in the background, giving the app a last-resort opportunity to
  // register the per-question UNNotificationCategory (answer-choice action buttons)
  // in case BOTH silent prep pushes above were dropped by watchOS (which throttles
  // background pushes aggressively for battery life). Without this, a backgrounded
  // app that missed both prep pushes would render the notification with no buttons.
  for (const device of devices) {
    const visiblePayload = {
      aps: {
        alert: { title: "NotiTrivia", body: question.question },
        sound: "default",
        category: categoryID,
        "content-available": 1,
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
    console.log(`[APNs visible ${slot}] token=...${device.device_token.slice(-6)} tz=${device.timezone} status=${result.status} body=${result.body}`);
    results.push({ token: device.device_token.slice(-6), slot, push: "visible", ...result });
  }

  return results;
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

    // Prune stale active_questions rows on each run to keep the table lean.
    // Rows older than 2 hours are well past their expiration window and safe to remove.
    await supabase
      .from("active_questions")
      .delete()
      .lt("delivered_at", new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString());

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

    // Partition devices by their current local time.
    // noon    → local hour == 12
    // evening → local hour == 18
    const noonDevices    = devices.filter(d => getLocalHour(d.timezone) === 12);
    const eveningDevices = devices.filter(d => getLocalHour(d.timezone) === 18);

    console.log(`[send-questions] total=${devices.length} noon=${noonDevices.length} evening=${eveningDevices.length}`);

    if (noonDevices.length === 0 && eveningDevices.length === 0) {
      return new Response(
        JSON.stringify({ message: "No devices in a noon or evening window right now" }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    const allResults: object[] = [];
    const deliveries: object[] = [];

    // Deliver noon questions (each group picks its own question independently).
    if (noonDevices.length > 0) {
      const question = await pickOneQuestion(supabase);
      const results = await deliverToGroup(noonDevices, question, "noon", apnsToken, bundleId, supabase);
      allResults.push(...results);
      deliveries.push({ slot: "noon", question: question.question, devices: noonDevices.length });
    }

    // Deliver evening questions.
    if (eveningDevices.length > 0) {
      const question = await pickOneQuestion(supabase);
      const results = await deliverToGroup(eveningDevices, question, "evening", apnsToken, bundleId, supabase);
      allResults.push(...results);
      deliveries.push({ slot: "evening", question: question.question, devices: eveningDevices.length });
    }

    return new Response(
      JSON.stringify({ deliveries, results: allResults }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
