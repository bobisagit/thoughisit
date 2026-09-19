// Goodest Boy runtime config.
// While these are null the site runs in demo mode (pretend money).
// After creating your Supabase project (see SETUP.md), fill both in and the
// site switches to live mode. Both values are safe to publish — the anon key
// is public by design; Row Level Security is what protects the data.
window.GOODESTBOY_CONFIG = {
  supabaseUrl: "https://frxwyapydgpmuapsghhl.supabase.co",
  supabaseAnonKey: "sb_publishable_KlrPzSNYE70e0Bh6DB_zuA_xBvj_KvU",

  // Launch season: bids are free (no payment) and capped at $25 each /
  // $50 a day per person. Flip to false once Stripe is deployed to switch
  // every Boost button to real checkout.
  freeBids: false, // Stripe sandbox test in progress — flip back to true to resume free launch season
  // Optional bot protection (see SETUP.md): create a Cloudflare Turnstile
  // widget, put its SITE key here, and give Supabase the SECRET key.
  // Leave null to run without captcha. Set both together or sign-in breaks.
  turnstileSiteKey: null,
};
