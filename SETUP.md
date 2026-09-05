# Goodest Boy — backend setup guide

The site runs in **demo mode** (pretend money) until you connect it to Supabase
and Stripe. Everything below is one-time setup, roughly an hour end to end.
Nothing here needs to be secret except the two keys marked **SECRET**.

## What's in this repo

| Path | What it is |
|---|---|
| `index.html` | The site. Demo mode until `config.js` is filled in. |
| `config.js` | Public config — your Supabase URL + anon key go here. |
| `supabase/migrations/0001_init.sql` | Database schema: dogs, bid ledger, moderation, leaderboard. |
| `supabase/functions/create-checkout/` | Starts a Stripe payment for a bid. |
| `supabase/functions/stripe-webhook/` | Records the bid after Stripe confirms the money. |

**Security model in one sentence:** the browser can only *ask* to bid; money is
taken by Stripe's hosted page, and the bid ledger is written only by the
webhook after Stripe confirms payment — so nobody can fake a total, and card
numbers never touch our code.

## 1. Create the Supabase project (~10 min)

1. Sign up at [supabase.com](https://supabase.com) (free tier) → **New project**.
   Pick the Sydney region. Save the database password somewhere safe.
2. In the dashboard, open **SQL Editor**, paste the whole contents of
   `supabase/migrations/0001_init.sql`, and run it.
3. Go to **Project Settings → API** and copy two values into `config.js`:
   - Project URL → `supabaseUrl`
   - `anon` `public` key → `supabaseAnonKey`

   (These two are safe to commit — the anon key is designed to be public.)
4. **Authentication → URL Configuration**: set the Site URL to
   `https://thoughisit.com` (change when goodestboy.com goes live).

## 2. Make yourself admin (~1 min)

Sign in to the site once (any Boost button → enter your email → click the
link). Then in the Supabase **SQL Editor**:

```sql
update public.profiles set is_admin = true
where id = (select id from auth.users where email = 'YOUR-EMAIL-HERE');
```

Admins can approve/hide dogs and see all bids. Regular users can't grant
themselves this — a database trigger blocks it.

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

## 4. Seed the founding dogs (~5 min)

Dogs normally arrive via user sign-ups (submission UI is the next build step),
but you can add the founding dogs directly. After a friend signs in once, in
the SQL Editor:

```sql
insert into public.dogs (owner_id, name, breed, status)
values (
  (select id from auth.users where email = 'FRIEND-EMAIL-HERE'),
  'Biscuit', 'Golden Retriever', 'approved'
);
```

To moderate later: `update public.dogs set status = 'approved' where id = ...;`
(or `'hidden'` to take one down). A proper admin page is on the launch plan.

## 5. Test it end to end (test mode)

1. Open the site — the banner should say “Real bids” and the board shows your
   founding dogs (empty board shows “Fetching the goodest boys…”).
2. Boost a dog → sign in via the email link → Boost again → Stripe's payment
   page opens. Pay with test card `4242 4242 4242 4242`, any future expiry,
   any CVC.
3. You land back on the site; within seconds the dog's total updates.
4. Also try the decline card `4000 0000 0000 0002` — the bid must NOT appear.

## 6. Going live with real money

Only after Phase 0 of the launch plan (ABN, bank account, charity agreement,
terms on the site): flip Stripe to live mode, repeat step 3 with the live
`sk_live_...` key and a live webhook endpoint, and make one real $1 bid.

## Limits baked in

- Bids: min $1, max $1,000 per transaction (change in
  `create-checkout/index.ts` and the DB constraint together).
- Only `approved` dogs appear or accept bids; new/edited dogs go back to
  `pending`.
- Webhook retries are harmless: one Checkout session can only ever create one
  bid row.

## Still to build (next steps)

- “Add your dog” form with photo upload (schema + storage already support it)
- Admin moderation page (until then: Supabase dashboard)
- Dethrone alert emails
- Report button, name filter, rate limiting / Turnstile
