// Goodest Boy runtime config.
// While these are null the site runs in demo mode (pretend money).
// After creating your Supabase project (see SETUP.md), fill both in and the
// site switches to live mode. Both values are safe to publish — the anon key
// is public by design; Row Level Security is what protects the data.
window.GOODESTBOY_CONFIG = {
  supabaseUrl: null, // e.g. "https://abcdefgh.supabase.co"
  supabaseAnonKey: null,
};
