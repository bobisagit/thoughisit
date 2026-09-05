// Stripe webhook: the ONLY writer of the bids ledger.
// Verifies Stripe's signature, then records the bid for a paid Checkout
// session. Idempotent: the unique stripe_session_id column makes webhook
// retries and replays harmless.
//
// Deploy with JWT verification off (Stripe doesn't hold a Supabase JWT);
// signature verification is what authenticates the caller instead.

import Stripe from "npm:stripe@16";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-06-20",
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();

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
  }

  return new Response("ok", { status: 200 });
});
