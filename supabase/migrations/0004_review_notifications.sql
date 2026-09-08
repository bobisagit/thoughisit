-- Email the admin when a dog is submitted for review.
-- Uses pg_net to call Resend directly from the database, so it works
-- without deploying any edge functions. Configure it by inserting two
-- rows into secrets.keys (see SETUP.md):
--   ('resend', 're_...your Resend API key...')
--   ('admin_email', 'you@example.com')
-- Until both rows exist, submissions simply skip the email.

create extension if not exists pg_net;

-- Private schema: not exposed through the API, no grants to app roles.
create schema if not exists secrets;

create table if not exists secrets.keys (
  name text primary key,
  value text not null
);

create function public.notify_new_dog()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  api_key text;
  admin_to text;
  from_addr text;
begin
  select value into api_key from secrets.keys where name = 'resend';
  select value into admin_to from secrets.keys where name = 'admin_email';
  if api_key is null or admin_to is null then
    return new; -- notifications not configured yet
  end if;
  select coalesce(
    (select value from secrets.keys where name = 'email_from'),
    'Goodest Boy <onboarding@resend.dev>'
  ) into from_addr;
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
        || '<p><a href="https://thoughisit.com/admin" style="background:#f59e2d;color:#fff;padding:10px 20px;border-radius:999px;text-decoration:none;font-weight:bold">Review now 🐾</a></p></div>'
    )
  );
  return new;
end;
$$;

create trigger notify_new_dog
  after insert on public.dogs
  for each row execute function public.notify_new_dog();
