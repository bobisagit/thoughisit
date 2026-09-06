-- Rate limits + monthly Hall of Fame.
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
-- (table name is historic: snapshots are monthly, one row per crowned month)

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

-- Snapshot the current #1 into the hall at each Sydney month boundary.
-- Runs daily via pg_cron; only acts when the new month has just begun in
-- Sydney. Idempotent per calendar date.
create function public.snapshot_monthly_crown()
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  champ record;
begin
  if extract(day from (now() at time zone 'Australia/Sydney')) <> 1 then
    return; -- not the month boundary yet
  end if;
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
revoke execute on function public.snapshot_monthly_crown() from public, anon, authenticated;

-- Schedule: daily at 14:00 UTC; the function fires only when that instant
-- lands in the first day of a new Sydney month (i.e. month's end, midnight).
-- Also purge day-old checkout_attempts nightly.
-- pg_cron ships with Supabase; if this block reports it unavailable,
-- enable the pg_cron extension in Dashboard → Database → Extensions
-- and re-run this DO block.
do $outer$
begin
  create extension if not exists pg_cron;
  perform cron.schedule(
    'monthly-crown-snapshot',
    '0 14 * * *',
    'select public.snapshot_monthly_crown()'
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
