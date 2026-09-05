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
