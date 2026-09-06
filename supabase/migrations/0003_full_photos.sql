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

create or replace function public.snapshot_monthly_crown()
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  champ record;
begin
  if extract(day from (now() at time zone 'Australia/Sydney')) <> 1 then
    return;
  end if;
  select * into champ from public.get_leaderboard(1);
  if champ.dog_id is null then
    return;
  end if;
  insert into public.crown_weeks (week_ending, dog_id, name, photo_path, photo_full_path, total_cents)
  values (current_date, champ.dog_id, champ.name, champ.photo_path, champ.photo_full_path, champ.total_cents)
  on conflict (week_ending) do nothing;
end;
$$;
