-- On submission, also email the owner a confirmation (alongside the
-- admin review alert). Replaces notify_new_dog to send both.

create or replace function public.notify_new_dog()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  api_key text;
  admin_to text;
  from_addr text;
  owner_email text;
begin
  select value into api_key from secrets.keys where name = 'resend';
  if api_key is null then
    return new; -- notifications not configured yet
  end if;
  select value into admin_to from secrets.keys where name = 'admin_email';
  select coalesce(
    (select value from secrets.keys where name = 'email_from'),
    'Goodest Boy <onboarding@resend.dev>'
  ) into from_addr;

  -- alert the admin
  if admin_to is not null then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || api_key,
        'Content-Type', 'application/json'
      ),
      body := jsonb_build_object(
        'from', from_addr,
        'to', admin_to,
        'subject', '🕵️ New dog awaiting review: ' || new.name,
        'html', '<div style="font-family:sans-serif"><p><b>' || new.name || '</b>'
          || coalesce(' (' || new.breed || ')', '')
          || ' just joined the review queue.</p>'
          || '<p><a href="https://thoughisit.com/admin.html" style="background:#f59e2d;color:#fff;padding:10px 20px;border-radius:999px;text-decoration:none;font-weight:bold">Review now 🐾</a></p></div>'
      )
    );
  end if;

  -- confirm to the owner
  select email into owner_email from auth.users where id = new.owner_id;
  if owner_email is not null then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || api_key,
        'Content-Type', 'application/json'
      ),
      body := jsonb_build_object(
        'from', from_addr,
        'to', owner_email,
        'subject', '🐾 ' || new.name || ' is in the review queue!',
        'html', '<div style="background:#fff8ee;padding:32px 16px;font-family:sans-serif;color:#3b2b1e">'
          || '<div style="max-width:480px;margin:0 auto;background:#ffffff;border:1px solid #f0e2cc;border-radius:18px;padding:28px;text-align:center">'
          || '<div style="font-size:44px;line-height:1">🐶📋</div>'
          || '<h1 style="font-size:22px;margin:12px 0 8px">' || new.name || ' has entered the race!</h1>'
          || '<p style="font-size:15px;color:#7a6a58;margin:0 0 8px">Thanks for joining Goodest Boy — our inspectors are reviewing the paperwork now. <b>Every good dog passes</b>, and you''ll get an email the moment ' || new.name || ' hits the board.</p>'
          || '<p style="font-size:15px;color:#7a6a58;margin:0 0 22px">Meanwhile, scope out the competition…</p>'
          || '<a href="https://thoughisit.com/#board" style="display:inline-block;background:#f59e2d;color:#ffffff;font-weight:bold;font-size:16px;padding:13px 28px;border-radius:999px;text-decoration:none">See the leaderboard 🏆</a>'
          || '</div></div>'
      )
    );
  end if;

  return new;
end;
$$;
