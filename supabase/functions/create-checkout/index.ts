// Creates a Stripe Checkout session for a bid.
// The browser sends {dog_id, amount_cents}; everything is re-validated here.
// The bid is NOT recorded yet — that happens only when the stripe-webhook
// function receives Stripe's payment confirmation.

import Stripe from "npm:stripe@16";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-06-20",
});

const MIN_CENTS = 100; // $1
const MAX_CENTS = 100000; // $1,000 per single bid

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json(405, { error: "method not allowed" });
  }

  // Identify the signed-in bidder from their JWT.
  const authClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
  );
  const { data: userData, error: userError } = await authClient.auth.getUser();
  if (userError || !userData?.user) {
    return json(401, { error: "sign in to bid" });
  }

  let body: { dog_id?: unknown; amount_cents?: unknown };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid request body" });
  }

  const dogId = Number(body.dog_id);
  const amountCents = Number(body.amount_cents);
  if (!Number.isInteger(dogId) || dogId <= 0) {
    return json(400, { error: "invalid dog" });
  }
  if (
    !Number.isInteger(amountCents) ||
    amountCents < MIN_CENTS ||
    amountCents > MAX_CENTS
  ) {
    return json(400, { error: "bid must be between $1 and $1,000" });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Rate limit: max 10 checkout attempts per user per 15 minutes,
  // which stops card-testing runs without bothering real bidders.
  const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const { count } = await admin
    .from("checkout_attempts")
    .select("*", { count: "exact", head: true })
    .eq("user_id", userData.user.id)
    .gte("created_at", since);
  if ((count ?? 0) >= 10) {
    return json(429, {
      error: "whoa, easy tiger — too many bids at once, try again in a few minutes",
    });
  }
  await admin.from("checkout_attempts").insert({ user_id: userData.user.id });

  // Verify the dog exists and is approved (service role bypasses RLS).
  const { data: dog, error: dogError } = await admin
    .from("dogs")
    .select("id, name, status")
    .eq("id", dogId)
    .single();
  if (dogError || !dog || dog.status !== "approved") {
    return json(404, { error: "dog not found" });
  }

  const siteUrl = Deno.env.get("SITE_URL") ?? "https://thoughisit.com";
  const session = await stripe.checkout.sessions.create({
    mode: "payment",
    line_items: [
      {
        quantity: 1,
        price_data: {
          currency: "aud",
          unit_amount: amountCents,
          product_data: {
            name: `Goodest Boy bid — ${dog.name}`,
            description:
              "Stacks permanently on this dog's lifetime total. 10% goes to rescue shelters.",
          },
        },
      },
    ],
    metadata: {
      dog_id: String(dog.id),
      bidder_id: userData.user.id,
    },
    success_url: `${siteUrl}/?bid=success`,
    cancel_url: `${siteUrl}/?bid=cancelled`,
  });

  return json(200, { url: session.url });
});
