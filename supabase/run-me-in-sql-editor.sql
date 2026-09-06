-- ONE-PASTE SETUP: the whole Goodest Boy schema (migrations 0001+0002+0003).
-- Paste this entire file into Supabase Dashboard -> SQL Editor -> Run, once,
-- on a fresh project. If you already ran some migration files individually,
-- run only the remaining numbered files instead of this one.

-- Goodest Boy backend schema
-- Core security design: bids are a ledger written ONLY by the Stripe webhook
-- (service role). Leaderboard totals are always computed from the ledger.
-- The browser can never set a total, insert a bid, or approve a dog.

-- ---------- profiles ----------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text check (char_length(display_name) <= 60),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- auto-create a profile row when a user signs up
create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- helper used by policies
create function public.is_admin()
returns boolean
language sql stable
security definer set search_path = public
as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

create policy "read own profile" on public.profiles
  for select using (id = auth.uid() or public.is_admin());

create policy "update own profile" on public.profiles
  for update using (id = auth.uid())
  with check (id = auth.uid());

-- nobody promotes themselves: is_admin can only change via service role / SQL editor
create function public.protect_is_admin()
returns trigger
language plpgsql
as $$
begin
  if new.is_admin is distinct from old.is_admin
     and coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'is_admin can only be changed by an administrator';
  end if;
  return new;
end;
$$;

create trigger protect_is_admin
  before update on public.profiles
  for each row execute function public.protect_is_admin();

-- ---------- dogs ----------
create type public.dog_status as enum ('pending', 'approved', 'hidden');

create table public.dogs (
  id bigint generated always as identity primary key,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  breed text check (char_length(breed) <= 60),
  photo_path text,        -- path inside the dog-photos storage bucket
  status public.dog_status not null default 'pending',
  flair text check (char_length(flair) <= 8),
  created_at timestamptz not null default now()
);

alter table public.dogs enable row level security;

-- everyone sees approved dogs; owners see their own; admins see all
create policy "read dogs" on public.dogs
  for select using (
    status = 'approved' or owner_id = auth.uid() or public.is_admin()
  );

-- owners submit dogs, which always start as pending with no flair
create policy "submit own dog" on public.dogs
  for insert to authenticated
  with check (
    owner_id = auth.uid() and status = 'pending' and flair is null
  );

-- owners may edit their dog, but any edit forces it back to pending review
create policy "edit own dog back to pending" on public.dogs
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid() and status = 'pending');

-- admins moderate freely (approve / hide / set flair)
create policy "admin moderates dogs" on public.dogs
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------- bids (the ledger) ----------
create table public.bids (
  id bigint generated always as identity primary key,
  dog_id bigint not null references public.dogs (id) on delete restrict,
  bidder_id uuid references public.profiles (id) on delete set null,
  amount_cents integer not null check (amount_cents between 100 and 100000),
  stripe_session_id text not null unique,   -- idempotency: one bid per Checkout session
  stripe_payment_intent text,
  created_at timestamptz not null default now()
);

create index bids_dog_id_idx on public.bids (dog_id);

alter table public.bids enable row level security;

-- bidders may see their own bid history; admins see all.
-- There are NO insert/update/delete policies: only the service role
-- (the Stripe webhook function) can write the ledger.
create policy "read own bids" on public.bids
  for select using (bidder_id = auth.uid() or public.is_admin());

-- ---------- reports ----------
create table public.reports (
  id bigint generated always as identity primary key,
  dog_id bigint not null references public.dogs (id) on delete cascade,
  reporter_id uuid references public.profiles (id) on delete set null,
  reason text check (char_length(reason) <= 500),
  created_at timestamptz not null default now()
);

alter table public.reports enable row level security;

create policy "report a dog" on public.reports
  for insert to authenticated
  with check (reporter_id = auth.uid());

create policy "admin reads reports" on public.reports
  for select using (public.is_admin());

create policy "admin resolves reports" on public.reports
  for delete using (public.is_admin());

-- ---------- name filter ----------
-- First gate against offensive dog names/breeds; human moderation remains
-- the real backstop. match_anywhere=true words are blocked as substrings
-- (only unambiguous terms belong there); others match whole words only, so
-- "Cocker Spaniel" and "Cassie" stay legal. Admins and the service role
-- bypass the trigger, so you can always override a false positive.
create table public.banned_words (
  word text primary key check (word = lower(word) and word ~ '^[a-z]+$'),
  match_anywhere boolean not null default false
);

alter table public.banned_words enable row level security;

create policy "admin manages banned words" on public.banned_words
  for all using (public.is_admin()) with check (public.is_admin());

insert into public.banned_words (word, match_anywhere) values
  ('fuck', true), ('cunt', true), ('nigg', true), ('fagg', true), ('kike', true),
  ('shit', false), ('bitch', false), ('cock', false), ('dick', false),
  ('ass', false), ('arse', false), ('tit', false), ('tits', false),
  ('piss', false), ('slut', false), ('whore', false), ('twat', false),
  ('wank', false), ('spic', false), ('chink', false), ('retard', false),
  ('tranny', false), ('nazi', false), ('hitler', false), ('rape', false),
  ('porn', false), ('penis', false), ('vagina', false), ('boner', false),
  ('cum', false);

-- lowercase + undo common leetspeak (B1scu1t → biscuit)
create function public.normalize_text(t text)
returns text
language sql immutable
as $$
  select lower(translate(coalesce(t, ''), '013457$@!', 'oieastsai'));
$$;

create function public.text_allowed(t text)
returns boolean
language plpgsql stable
security definer set search_path = public
as $$
declare
  squished text := regexp_replace(public.normalize_text(t), '[^a-z]', '', 'g');
  spaced text := regexp_replace(public.normalize_text(t), '[^a-z]+', ' ', 'g');
begin
  return not exists (
    select 1 from public.banned_words w
    where (w.match_anywhere and squished like '%' || w.word || '%')
       or (not w.match_anywhere and spaced ~ ('\m' || w.word || '\M'))
  );
end;
$$;

create function public.check_dog_name()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' or public.is_admin() then
    return new;
  end if;
  if not public.text_allowed(new.name) or not public.text_allowed(new.breed) then
    raise exception 'that name is not suitable for the board — please pick another';
  end if;
  return new;
end;
$$;

create trigger check_dog_name
  before insert or update on public.dogs
  for each row execute function public.check_dog_name();

-- ---------- leaderboard ----------
-- Exposed as an RPC so the bids table itself never needs public read access.
-- Ties go to the most recent bid, matching the site's advertised rules.
create function public.get_leaderboard(limit_count int default 50)
returns table (
  dog_id bigint,
  name text,
  breed text,
  photo_path text,
  flair text,
  total_cents bigint,
  last_bid_at timestamptz
)
language sql stable
security definer set search_path = public
as $$
  select
    d.id,
    d.name,
    d.breed,
    d.photo_path,
    d.flair,
    coalesce(sum(b.amount_cents), 0)::bigint as total_cents,
    max(b.created_at) as last_bid_at
  from public.dogs d
  left join public.bids b on b.dog_id = d.id
  where d.status = 'approved'
  group by d.id
  order by total_cents desc, last_bid_at desc nulls last, d.created_at asc
  limit greatest(1, least(limit_count, 100));
$$;

grant execute on function public.get_leaderboard(int) to anon, authenticated;

-- ---------- storage: dog photos ----------
insert into storage.buckets (id, name, public)
values ('dog-photos', 'dog-photos', true)
on conflict (id) do nothing;

-- users upload only into their own folder: dog-photos/<user_id>/...
create policy "upload own dog photo" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'dog-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "replace own dog photo" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'dog-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
-- Rate limits + weekly Hall of Fame.
-- Run after 0001_init.sql (fresh installs run both files in order).

-- ---------- rate limiting ----------

-- Checkout attempts: written by the create-checkout function (service role
-- only — no policies on purpose) so it can cap attempts per user.
create table public.checkout_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  created_at timestamptz not null default now()
);

create index checkout_attempts_user_idx
  on public.checkout_attempts (user_id, created_at);

alter table public.checkout_attempts enable row level security;

-- Max 5 reports per user per hour.
create function public.limit_reports()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if (
    select count(*) from public.reports
    where reporter_id = new.reporter_id
      and created_at > now() - interval '1 hour'
  ) >= 5 then
    raise exception 'too many reports in the last hour — please try again later';
  end if;
  return new;
end;
$$;

create trigger limit_reports
  before insert on public.reports
  for each row execute function public.limit_reports();

-- Max 3 dogs awaiting review per owner (admins and service role bypass).
create function public.limit_dog_submissions()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' or public.is_admin() then
    return new;
  end if;
  if (
    select count(*) from public.dogs
    where owner_id = new.owner_id and status = 'pending'
  ) >= 3 then
    raise exception 'you already have 3 dogs awaiting review — hang tight!';
  end if;
  return new;
end;
$$;

create trigger limit_dog_submissions
  before insert on public.dogs
  for each row execute function public.limit_dog_submissions();

-- ---------- hall of fame ----------

create table public.crown_weeks (
  week_ending date primary key,
  dog_id bigint references public.dogs (id) on delete set null,
  name text not null,
  photo_path text,
  total_cents bigint not null,
  created_at timestamptz not null default now()
);

alter table public.crown_weeks enable row level security;

create policy "hall of fame is public" on public.crown_weeks
  for select using (true);

-- Snapshot the current #1 into the hall. Idempotent per calendar date.
create function public.snapshot_weekly_crown()
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  champ record;
begin
  select * into champ from public.get_leaderboard(1);
  if champ.dog_id is null then
    return; -- empty board, nothing to immortalise
  end if;
  insert into public.crown_weeks (week_ending, dog_id, name, photo_path, total_cents)
  values (current_date, champ.dog_id, champ.name, champ.photo_path, champ.total_cents)
  on conflict (week_ending) do nothing;
end;
$$;

-- only the scheduler / service role may run it
revoke execute on function public.snapshot_weekly_crown() from public, anon, authenticated;

-- Schedule: Sunday 14:00 UTC = midnight Sunday→Monday AEST.
-- Also purge day-old checkout_attempts nightly.
-- pg_cron ships with Supabase; if this block reports it unavailable,
-- enable the pg_cron extension in Dashboard → Database → Extensions
-- and re-run this DO block.
do $outer$
begin
  create extension if not exists pg_cron;
  perform cron.schedule(
    'weekly-crown-snapshot',
    '0 14 * * 0',
    'select public.snapshot_weekly_crown()'
  );
  perform cron.schedule(
    'purge-checkout-attempts',
    '0 15 * * *',
    'delete from public.checkout_attempts where created_at < now() - interval ''1 day'''
  );
exception when others then
  raise notice 'pg_cron unavailable (%) — enable the extension and re-run this block', sqlerrm;
end;
$outer$;
-- Store the full-size photo alongside the display thumbnail, so the site
-- can enlarge a dog's photo on click. Run after 0002.

alter table public.dogs add column photo_full_path text;

-- get_leaderboard gains the full-photo column (drop first: the return
-- type is changing).
drop function public.get_leaderboard(int);

create function public.get_leaderboard(limit_count int default 50)
returns table (
  dog_id bigint,
  name text,
  breed text,
  photo_path text,
  photo_full_path text,
  flair text,
  total_cents bigint,
  last_bid_at timestamptz
)
language sql stable
security definer set search_path = public
as $$
  select
    d.id,
    d.name,
    d.breed,
    d.photo_path,
    d.photo_full_path,
    d.flair,
    coalesce(sum(b.amount_cents), 0)::bigint as total_cents,
    max(b.created_at) as last_bid_at
  from public.dogs d
  left join public.bids b on b.dog_id = d.id
  where d.status = 'approved'
  group by d.id
  order by total_cents desc, last_bid_at desc nulls last, d.created_at asc
  limit greatest(1, least(limit_count, 100));
$$;

grant execute on function public.get_leaderboard(int) to anon, authenticated;

-- Hall of Fame snapshots keep the full photo as well.
alter table public.crown_weeks add column photo_full_path text;

create or replace function public.snapshot_weekly_crown()
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  champ record;
begin
  select * into champ from public.get_leaderboard(1);
  if champ.dog_id is null then
    return;
  end if;
  insert into public.crown_weeks (week_ending, dog_id, name, photo_path, photo_full_path, total_cents)
  values (current_date, champ.dog_id, champ.name, champ.photo_path, champ.photo_full_path, champ.total_cents)
  on conflict (week_ending) do nothing;
end;
$$;
