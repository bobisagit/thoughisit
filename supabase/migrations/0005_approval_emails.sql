-- Email a dog's owner the moment their dog is approved onto the board.
-- Same pg_net + Resend pattern as 0004; requires the 'resend' row in
-- secrets.keys. Optional row 'email_from' overrides the sender once a
-- domain is verified in Resend (e.g. 'Goodest Boy <alerts@thoughisit.com>').
-- NOTE: until a domain is verified in Resend, delivery only reaches the
-- Resend account owner's own address — verify the domain to email everyone.

create function public.notify_dog_approved()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  api_key text;
  from_addr text;
  owner_email text;
begin
  if not (old.status is distinct from new.status and new.status = 'approved') then
    return new;
  end if;
  select value into api_key from secrets.keys where name = 'resend';
  if api_key is null then
    return new;
  end if;
  select coalesce(
    (select value from secrets.keys where name = 'email_from'),
    'Goodest Boy <onboarding@resend.dev>'
  ) into from_addr;
  select email into owner_email from auth.users where id = new.owner_id;
  if owner_email is null then
    return new;
  end if;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || api_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'from', from_addr,
      'to', owner_email,
      'subject', '🎉 ' || new.name || ' is officially on the board!',
      'html', '<div style="background:#fff8ee;padding:32px 16px;font-family:sans-serif;color:#3b2b1e">'
        || '<div style="max-width:480px;margin:0 auto;background:#ffffff;border:1px solid #f0e2cc;border-radius:18px;padding:28px;text-align:center">'
        || '<div style="font-size:44px;line-height:1">🎉🐶🎉</div>'
        || '<h1 style="font-size:22px;margin:12px 0 8px">' || new.name || ' passed review!</h1>'
        || '<p style="font-size:15px;color:#7a6a58;margin:0 0 8px">Officially certified as a Very Good Dog and live on the Goodest Boy leaderboard right now.</p>'
        || '<p style="font-size:15px;color:#7a6a58;margin:0 0 22px">Every dog starts at $0 — <b>the first $1 bid takes them up the board</b>, and every dollar stacks forever. 10% goes to rescue shelters.</p>'
        || '<a href="https://thoughisit.com/#board" style="display:inline-block;background:#f59e2d;color:#ffffff;font-weight:bold;font-size:16px;padding:13px 28px;border-radius:999px;text-decoration:none">See ' || new.name || ' on the board 🏆</a>'
        || '<p style="font-size:12px;color:#a8987f;margin:24px 0 0">Tell the group chat. The crown won''t defend itself.</p>'
        || '</div></div>'
    )
  );
  return new;
end;
$$;

create trigger notify_dog_approved
  after update on public.dogs
  for each row execute function public.notify_dog_approved();
