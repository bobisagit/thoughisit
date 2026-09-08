-- Launch-season free bidding + crown-change emails.
--
-- place_free_bid lets a signed-in user stack a no-payment bid ($1-$25,
-- max $50/day each) marked free=true, so the board and the outbid war
-- work before Stripe. Flip config.js freeBids to false to retire it.
--
-- notify_crown_change fires on EVERY bid insert (free now, Stripe later)
-- and emails both sides of a dethronement: congratulations to the new
-- champion's owner, and the reclaim-the-crown prompt to the beaten one.

alter table public.bids add column free boolean not null default false;

create function public.place_free_bid(p_dog_id bigint, p_amount_cents int)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  spent int;
begin
  if uid is null then
    raise exception 'sign in to bid';
  end if;
  if p_amount_cents is null or p_amount_cents < 100 or p_amount_cents > 2500 then
    raise exception 'launch-season bids are $1 to $25 at a time';
  end if;
  if not exists (select 1 from public.dogs where id = p_dog_id and status = 'approved') then
    raise exception 'dog not found';
  end if;
  select coalesce(sum(amount_cents), 0) into spent
  from public.bids
  where bidder_id = uid and free and created_at > now() - interval '1 day';
  if spent + p_amount_cents > 5000 then
    raise exception 'you''ve hit today''s free-bid limit — back tomorrow!';
  end if;
  insert into public.bids (dog_id, bidder_id, amount_cents, stripe_session_id, free)
  values (p_dog_id, uid, p_amount_cents, 'free-' || gen_random_uuid(), true);
end;
$$;

revoke execute on function public.place_free_bid(bigint, int) from public, anon;
grant execute on function public.place_free_bid(bigint, int) to authenticated;

create function public.notify_crown_change()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  api_key text;
  from_addr text;
  new_champ record;
  old_champ record;
  new_owner text;
  old_owner text;
  reclaim int;
begin
  select value into api_key from secrets.keys where name = 'resend';
  if api_key is null then
    return new;
  end if;

  -- champion now
  select d.id, d.name, d.owner_id,
         coalesce(sum(b.amount_cents), 0) as total,
         max(b.created_at) as last_bid
  into new_champ
  from public.dogs d
  left join public.bids b on b.dog_id = d.id
  where d.status = 'approved'
  group by d.id
  order by total desc, last_bid desc nulls last, d.created_at asc
  limit 1;

  -- only a bid on the (new) champion can have changed the crown
  if new_champ.id is null or new_champ.id <> new.dog_id then
    return new;
  end if;

  -- champion as it stood before this bid
  select d.id, d.name, d.owner_id,
         coalesce(sum(b.amount_cents), 0) as total,
         max(b.created_at) as last_bid
  into old_champ
  from public.dogs d
  left join public.bids b on b.dog_id = d.id and b.id <> new.id
  where d.status = 'approved'
  group by d.id
  order by total desc, last_bid desc nulls last, d.created_at asc
  limit 1;

  if old_champ.id is null or old_champ.id = new_champ.id then
    return new; -- crown held (or first crown ever)
  end if;

  select coalesce(
    (select value from secrets.keys where name = 'email_from'),
    'Goodest Boy <onboarding@resend.dev>'
  ) into from_addr;
  select email into new_owner from auth.users where id = new_champ.owner_id;
  select email into old_owner from auth.users where id = old_champ.owner_id;
  reclaim := new_champ.total - old_champ.total + 100;

  if new_owner is not null then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || api_key,
        'Content-Type', 'application/json'
      ),
      body := jsonb_build_object(
        'from', from_addr,
        'to', new_owner,
        'subject', '👑 ' || new_champ.name || ' is now the Goodest Boy!',
        'html', '<div style="background:#fff8ee;padding:32px 16px;font-family:sans-serif;color:#3b2b1e">'
          || '<div style="max-width:480px;margin:0 auto;background:#ffffff;border:1px solid #f0e2cc;border-radius:18px;padding:28px;text-align:center">'
          || '<div style="font-size:44px;line-height:1">👑</div>'
          || '<h1 style="font-size:22px;margin:12px 0 8px">' || new_champ.name || ' has taken the crown!</h1>'
          || '<p style="font-size:15px;color:#7a6a58;margin:0 0 22px">With a lifetime total of <b>$' || round(new_champ.total / 100.0, 2) || '</b>, ' || new_champ.name || ' now reigns as the official Goodest Boy. Reign wisely — the pack is coming.</p>'
          || '<a href="https://thoughisit.com" style="display:inline-block;background:#f59e2d;color:#ffffff;font-weight:bold;font-size:16px;padding:13px 28px;border-radius:999px;text-decoration:none">Admire the throne 🏆</a>'
          || '</div></div>'
      )
    );
  end if;

  if old_owner is not null and old_owner is distinct from new_owner then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || api_key,
        'Content-Type', 'application/json'
      ),
      body := jsonb_build_object(
        'from', from_addr,
        'to', old_owner,
        'subject', '💔 ' || old_champ.name || ' has been dethroned!',
        'html', '<div style="background:#fff8ee;padding:32px 16px;font-family:sans-serif;color:#3b2b1e">'
          || '<div style="max-width:480px;margin:0 auto;background:#ffffff;border:1px solid #f0e2cc;border-radius:18px;padding:28px;text-align:center">'
          || '<div style="font-size:44px;line-height:1">💔</div>'
          || '<h1 style="font-size:22px;margin:12px 0 8px">' || old_champ.name || ' has been dethroned!</h1>'
          || '<p style="font-size:15px;color:#7a6a58;margin:0 0 22px"><b>' || new_champ.name || '</b> just snatched the crown with $' || round(new_champ.total / 100.0, 2) || '. The good news: you can take it straight back for just <b>$' || round(reclaim / 100.0, 2) || '</b>.</p>'
          || '<a href="https://thoughisit.com" style="display:inline-block;background:#e05a4e;color:#ffffff;font-weight:bold;font-size:16px;padding:13px 28px;border-radius:999px;text-decoration:none">Reclaim the crown for $' || round(reclaim / 100.0, 2) || ' 😤</a>'
          || '</div></div>'
      )
    );
  end if;

  return new;
end;
$$;

create trigger notify_crown_change
  after insert on public.bids
  for each row execute function public.notify_crown_change();
