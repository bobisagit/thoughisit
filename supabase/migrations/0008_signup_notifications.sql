-- Email the admin when a new member signs up. Includes the running
-- member count. Turn off when it becomes noise:
--   drop trigger notify_new_user on public.profiles;

create or replace function public.notify_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  api_key text;
  admin_to text;
  from_addr text;
  user_email text;
begin
  select value into api_key from secrets.keys where name = 'resend';
  select value into admin_to from secrets.keys where name = 'admin_email';
  if api_key is null or admin_to is null then
    return new;
  end if;
  select coalesce(
    (select value from secrets.keys where name = 'email_from'),
    'Goodest Boy <onboarding@resend.dev>'
  ) into from_addr;
  select email into user_email from auth.users where id = new.id;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || api_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'from', from_addr,
      'to', admin_to,
      'subject', '👋 New member joined Goodest Boy',
      'html', '<div style="font-family:sans-serif"><p><b>' || coalesce(user_email, 'someone') || '</b> just signed up — member #' || (select count(*) from public.profiles) || '. 🐾</p></div>'
    )
  );
  return new;
end;
$$;

create trigger notify_new_user
  after insert on public.profiles
  for each row execute function public.notify_new_user();
