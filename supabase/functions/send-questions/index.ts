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

// Picks and increments exactly ONE question — fixes the double-increment bug
// where the old pickTwoQuestions bumped times_used for both slots on every call.
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

    // Determine slot from UTC hour, pick exactly one question for it
    const utcHour = new Date().getUTCHours();
    const slot: "noon" | "evening" = utcHour === 22 ? "evening" : "noon";
    const question = await pickOneQuestion(supabase);
    const deliveredAt = Math.floor(Date.now() / 1000);

    // Store what was sent so send-expirations knows the correct answer
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

    // Push 1: Silent prep push — wakes app to register question_category
    for (const device of devices) {
      const silentPayload = {
        aps: { "content-available": 1 },
        questionID: question.id,
        choices: question.choices,
        correctAnswer: question.correct,
        slot,
        deliveredAt,
        isPrepPush: true,
      };

      const result = await sendPush(device.device_token, silentPayload, apnsToken, bundleId, "background");
      console.log(`[APNs silent] token=...${device.device_token.slice(-6)} status=${result.status} body=${result.body}`);
      results.push({ token: device.device_token.slice(-6), push: "silent", ...result });
    }

    // Wait for devices to register their categories
    await sleep(5000);

    // Push 2: Visible question notification
    for (const device of devices) {
      const visiblePayload = {
        aps: {
          alert: { title: "NotiTrivia", body: question.question },
          sound: "default",
          category: "question_category",
        },
        questionID: question.id,
        choices: question.choices,
        correctAnswer: question.correct,
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