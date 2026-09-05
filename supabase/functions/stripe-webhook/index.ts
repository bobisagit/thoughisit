// Stripe webhook: the ONLY writer of the bids ledger.
// Verifies Stripe's signature, then records the bid for a paid Checkout
// session. Idempotent: the unique stripe_session_id column makes webhook
// retries and replays harmless.
//
// After recording a bid it also sends the crown emails (new champion
// congratulations + dethrone alert with the exact reclaim price) via
// Resend. Emails are best-effort: if RESEND_API_KEY is unset or sending
// fails, the bid still counts and Stripe still gets a 200.
//
// Deploy with JWT verification off (Stripe doesn't hold a Supabase JWT);
// signature verification is what authenticates the caller instead.

import Stripe from "npm:stripe@16";
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-06-20",
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();

type BoardRow = {
  dog_id: number;
  name: string;
  total_cents: number;
};

async function leaderboard(
  admin: SupabaseClient,
  limit: number,
): Promise<BoardRow[]> {
  const { data, error } = await admin.rpc("get_leaderboard", {
    limit_count: limit,
  });
  if (error) {
    console.error("leaderboard fetch failed", error);
    return [];
  }
  return (data as BoardRow[]) ?? [];
}

async function ownerEmailFor(
  admin: SupabaseClient,
  dogId: number,
): Promise<string | null> {
  const { data: dog } = await admin
    .from("dogs")
    .select("owner_id")
    .eq("id", dogId)
    .single();
  if (!dog?.owner_id) return null;
  const { data } = await admin.auth.admin.getUserById(dog.owner_id);
  return data?.user?.email ?? null;
}

const fmt = (cents: number) =>
  "$" + (cents / 100).toLocaleString("en-AU", { maximumFractionDigits: 2 });

function emailHtml(heading: string, body: string, cta: string, url: string) {
  return `<div style="background:#fff8ee;padding:32px 16px;font-family:'Segoe UI',Arial,sans-serif;color:#3b2b1e">
  <div style="max-width:480px;margin:0 auto;background:#ffffff;border:1px solid #f0e2cc;border-radius:18px;padding:28px;text-align:center">
    <div style="font-size:40px;line-height:1">🐾</div>
    <h1 style="font-size:22px;margin:12px 0 8px">${heading}</h1>
    <p style="font-size:15px;color:#7a6a58;margin:0 0 22px">${body}</p>
    <a href="${url}" style="display:inline-block;background:#f59e2d;color:#ffffff;font-weight:bold;font-size:16px;padding:13px 28px;border-radius:999px;text-decoration:none">${cta}</a>
    <p style="font-size:12px;color:#a8987f;margin:24px 0 0">goodestboy.com · every bid stacks forever · 10% goes to rescue shelters</p>
  </div>
</div>`;
}

async function sendEmail(to: string, subject: string, html: string) {
  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) return;
  const from = Deno.env.get("EMAIL_FROM") ??
    "Goodest Boy <onboarding@resend.dev>";
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ from, to, subject, html }),
  });
  if (!res.ok) {
    console.error("email send failed", res.status, await res.text());
  }
}

async function sendCrownEmails(
  admin: SupabaseClient,
  before: BoardRow[],
  after: BoardRow[],
) {
  if (!Deno.env.get("RESEND_API_KEY")) return; // emails not configured yet
  const siteUrl = Deno.env.get("SITE_URL") ?? "https://thoughisit.com";
  const oldChamp = before[0];
  const newChamp = after[0];
  if (!newChamp) return;
  if (oldChamp && oldChamp.dog_id === newChamp.dog_id) return; // crown held

  const newOwner = await ownerEmailFor(admin, newChamp.dog_id);
  const oldOwner = oldChamp ? await ownerEmailFor(admin, oldChamp.dog_id) : null;

  if (newOwner) {
    await sendEmail(
      newOwner,
      `👑 ${newChamp.name} is now the Goodest Boy!`,
      emailHtml(
        `${newChamp.name} has taken the crown! 👑`,
        `With a lifetime total of <b>${fmt(newChamp.total_cents)}</b>, ${newChamp.name} now sits at #1 as the official Goodest Boy. Reign wisely — the pack is coming.`,
        "Admire the throne",
        siteUrl,
      ),
    );
  }

  if (oldChamp && oldOwner && oldOwner !== newOwner) {
    // the old champion's current total, wherever it now sits on the board
    const oldRow = after.find((r) => r.dog_id === oldChamp.dog_id);
    const oldTotal = oldRow?.total_cents ?? oldChamp.total_cents;
    const reclaimCents = newChamp.total_cents - oldTotal + 100;
    await sendEmail(
      oldOwner,
      `💔 ${oldChamp.name} has been dethroned!`,
      emailHtml(
        `${oldChamp.name} has been dethroned 💔`,
        `<b>${newChamp.name}</b> just took the crown with ${fmt(newChamp.total_cents)}. The good news: you can take it straight back for just <b>${fmt(reclaimCents)}</b>.`,
        `Reclaim the crown for ${fmt(reclaimCents)}`,
        siteUrl,
      ),
    );
  }
}

Deno.serve(async (req) => {
  const signature = req.headers.get("stripe-signature");
  if (!signature) {
    return new Response("missing signature", { status: 400 });
  }

  const payload = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      payload,
      signature,
      Deno.env.get("STRIPE_WEBHOOK_SECRET")!,
      undefined,
      cryptoProvider,
    );
  } catch (err) {
    console.error("webhook signature verification failed", err);
    return new Response("invalid signature", { status: 400 });
  }

  if (event.type === "checkout.session.completed") {
    const session = event.data.object as Stripe.Checkout.Session;
    if (session.payment_status !== "paid") {
      return new Response("ok (not paid yet)", { status: 200 });
    }

    const dogId = Number(session.metadata?.dog_id);
    const bidderId = session.metadata?.bidder_id ?? null;
    const amountCents = session.amount_total;
    if (!Number.isInteger(dogId) || !amountCents) {
      console.error("session missing metadata", session.id);
      return new Response("bad session metadata", { status: 200 });
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const before = await leaderboard(admin, 1);

    const { error } = await admin.from("bids").upsert(
      {
        dog_id: dogId,
        bidder_id: bidderId,
        amount_cents: amountCents,
        stripe_session_id: session.id,
        stripe_payment_intent:
          typeof session.payment_intent === "string"
            ? session.payment_intent
            : session.payment_intent?.id ?? null,
      },
      { onConflict: "stripe_session_id", ignoreDuplicates: true },
    );
    if (error) {
      console.error("failed to record bid", error);
      // 500 makes Stripe retry — the upsert keeps retries safe.
      return new Response("db error", { status: 500 });
    }

    try {
      const after = await leaderboard(admin, 50);
      await sendCrownEmails(admin, before, after);
    } catch (err) {
      // never fail the webhook over an email
      console.error("crown emails failed", err);
    }
  }

  return new Response("ok", { status: 200 });
});
