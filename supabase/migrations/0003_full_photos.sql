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
