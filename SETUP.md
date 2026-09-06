# Goodest Boy — backend setup guide

The site runs in **demo mode** (pretend money) until you connect it to Supabase
and Stripe. Everything below is one-time setup, roughly an hour end to end.
Nothing here needs to be secret except the two keys marked **SECRET**.

## What's in this repo

| Path | What it is |
|---|---|
| `index.html` | The site. Demo mode until `config.js` is filled in. |
| `admin.html` | Your moderation page: approve/hide dogs, handle reports, revenue stats. |
| `config.js` | Public config — your Supabase URL + anon key go here. |
| `supabase/migrations/0001_init.sql` | Database schema: dogs, bid ledger, moderation, leaderboard. |
| `supabase/migrations/0002_rate_limits_hall_of_fame.sql` | Rate limits + weekly Hall of Fame snapshot. |
| `supabase/migrations/0003_full_photos.sql` | Full-size photo storage for click-to-enlarge. |
| `supabase/functions/create-checkout/` | Starts a Stripe payment for a bid. |
| `supabase/functions/stripe-webhook/` | Records the bid after Stripe confirms the money. |

**Security model in one sentence:** the browser can only *ask* to bid; money is
taken by Stripe's hosted page, and the bid ledger is written only by the
webhook after Stripe confirms payment — so nobody can fake a total, and card
numbers never touch our code.

## 1. Create the Supabase project (~10 min)

1. Sign up at [supabase.com](https://supabase.com) (free tier) → **New project**.
   Pick the Sydney region. Save the database password somewhere safe.
2. In the dashboard, open **SQL Editor**, paste the whole of
   `supabase/run-me-in-sql-editor.sql` (all three migrations in one file)
   and run it once. If it prints a notice about pg_cron, enable the
   **pg_cron** extension under Database → Extensions and re-run the final
   `do` block — that's what schedules the Sunday-midnight Hall of Fame
   snapshot.
3. Go to **Project Settings → API** and copy two values into `config.js`:
   - Project URL → `supabaseUrl`
   - `anon` `public` key → `supabaseAnonKey`

   (These two are safe to commit — the anon key is designed to be public.)
4. **Authentication → URL Configuration**: set the Site URL to
   `https://thoughisit.com` and add `https://thoughisit.com/admin.html` to
   the Redirect URLs (change both when goodestboy.com goes live).

## 2. Make yourself admin (~1 min)

Sign in to the site once (any Boost button → enter your email → click the
link). Then in the Supabase **SQL Editor**:

```sql
update public.profiles set is_admin = true
where id = (select id from auth.users where email = 'YOUR-EMAIL-HERE');
```

Then open `https://thoughisit.com/admin.html` and sign in with that same
email — you'll get the moderation dashboard: the review queue, reports, a
flair tool, and revenue stats. Regular users can't grant themselves admin —
a database trigger blocks it. (The page is unlisted but not secret; the
database rejects every admin action from non-admin accounts, so a stranger
finding the URL just sees a "not an admin" message.)

## 3. Stripe (~15 min, needs your ABN + business bank account)

1. Create an account at [stripe.com](https://stripe.com) — stay in **test
   mode** for now.
2. **Developers → API keys**: copy the **Secret key** (SECRET — never goes in
   the repo).
3. Install the [Supabase CLI](https://supabase.com/docs/guides/cli), then from
   this repo's folder:

   ```sh
   supabase login
   supabase link --project-ref YOUR-PROJECT-REF   # ref is in your project's URL
   supabase secrets set STRIPE_SECRET_KEY=sk_test_...
   supabase secrets set SITE_URL=https://thoughisit.com
   supabase functions deploy create-checkout
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```

4. In Stripe: **Developers → Webhooks → Add endpoint**, URL:
   `https://YOUR-PROJECT-REF.supabase.co/functions/v1/stripe-webhook`,
   event: `checkout.session.completed`. Copy the signing secret it gives you
   (SECRET) and set it:

   ```sh
   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_...
   ```

5. In Stripe **Settings → Emails**, turn on receipts for successful payments.

## 4. Dethrone alert emails (~10 min — the revenue engine)

When the crown changes hands, the new champion's owner gets a congratulations
email and the dethroned owner gets the alert with the exact reclaim price.
Emails are optional: if you skip this step everything else still works.

1. Create a free account at [resend.com](https://resend.com) (3,000
   emails/month free) and copy an API key.
2. Set the secrets and redeploy the webhook:

   ```sh
   supabase secrets set RESEND_API_KEY=re_...
   supabase secrets set EMAIL_FROM="Goodest Boy <alerts@thoughisit.com>"
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```

3. **Domain verification matters:** until you verify your domain in Resend
   (Domains → Add → add the DNS records they show you), Resend only delivers
   to your own account email — fine for testing, useless for real bidders.
   Verify thoughisit.com now and re-verify goodestboy.com when it goes live,
   and set `EMAIL_FROM` to an address on the verified domain.

## 5. Bot protection with Turnstile (~10 min, do before announcing publicly)

Optional but recommended once strangers can find the site — it stops bot
sign-ups and card-testing runs at the front door.

1. In a free [Cloudflare account](https://dash.cloudflare.com), go to
   **Turnstile → Add widget**, add your domain, and choose the *Managed*
   widget type. You get a **site key** (public) and **secret key**.
2. Put the site key in `config.js` as `turnstileSiteKey`.
3. In Supabase: **Authentication → Attack Protection → Enable Captcha
   protection**, provider *Turnstile*, paste the **secret** key.
4. Set both or neither — captcha on in Supabase with no site key in
   `config.js` breaks sign-in.

Independent of Turnstile, the backend also rate-limits on its own: 10
checkout attempts per bidder per 15 minutes, 5 reports per hour, and 3
dogs awaiting review per owner.

## 6. Seed the founding dogs (~5 min)

Easiest way: friends use the site's own **Add your dog** button (sign in,
name, photo), and you approve them on `admin.html`. To add one yourself
directly, after that person has signed in once, in the SQL Editor:

```sql
insert into public.dogs (owner_id, name, breed, status)
values (
  (select id from auth.users where email = 'FRIEND-EMAIL-HERE'),
  'Biscuit', 'Golden Retriever', 'approved'
);
```

## 7. Test it end to end (test mode)

1. Open the site — the banner should say “Real bids” and the board shows your
   founding dogs (empty board shows “Fetching the goodest boys…”).
2. Boost a dog → sign in via the email link → Boost again → Stripe's payment
   page opens. Pay with test card `4242 4242 4242 4242`, any future expiry,
   any CVC.
3. You land back on the site; within seconds the dog's total updates.
4. Also try the decline card `4000 0000 0000 0002` — the bid must NOT appear.
5. With emails configured: bid a second dog past the champion — the dethroned
   owner should get the “💔 dethroned” email with the reclaim price, and the
   new owner the “👑” email.

6. Hall of Fame: run `select public.snapshot_weekly_crown();` in the SQL
   Editor once — the current champion should appear in the site's Hall of
   Fame section. (After launch this runs itself every Sunday at midnight.)

## 8. Going live with real money

Only after Phase 0 of the launch plan (ABN, bank account, charity agreement,
terms on the site): flip Stripe to live mode, repeat step 3 with the live
`sk_live_...` key and a live webhook endpoint, and make one real $1 bid.

## Limits baked in

- Bids: min $1, max $1,000 per transaction (change in
  `create-checkout/index.ts` and the DB constraint together).
- Only `approved` dogs appear or accept bids; new/edited dogs go back to
  `pending`.
- Dog names and breeds pass a profanity filter (leetspeak-aware). Tune it in
  the `banned_words` table; admin and SQL-editor submissions bypass it, so a
  false positive never blocks you.
- Any signed-in visitor can report a dog from its Boost window; reports land
  on `admin.html`.
- Webhook retries are harmless: one Checkout session can only ever create one
  bid row.

## Ideas for later

- Automated flair fulfilment (buy flair via Stripe instead of admin gifting)
- A weekly “state of the crown” email to all bidders
- Goodest-in-Breed titles
