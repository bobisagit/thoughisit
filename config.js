// Goodest Boy runtime config.
// While these are null the site runs in demo mode (pretend money).
// After creating your Supabase project (see SETUP.md), fill both in and the
// site switches to live mode. Both values are safe to publish — the anon key
// is public by design; Row Level Security is what protects the data.
window.GOODESTBOY_CONFIG = {
  supabaseUrl: "https://frxwyapydgpmuapsghhl.supabase.co",
  supabaseAnonKey: "sb_publishable_KlrPzSNYE70e0Bh6DB_zuA_xBvj_KvU",

  // Optional bot protection (see SETUP.md): create a Cloudflare Turnstile
  // widget, put its SITE key here, and give Supabase the SECRET key.
  // Leave null to run without captcha. Set both together or sign-in breaks.
  turnstileSiteKey: null,
};
