-- Admin-editable branding (title + logo URL) for Terminal/Admin header.
create table if not exists public.app_branding_settings (
  singleton boolean primary key default true check (singleton),
  app_title text not null default 'ClubCashBuddy',
  logo_url text null,
  updated_at timestamp with time zone not null default now(),
  updated_by uuid null references public.app_users(id) on delete set null
);

insert into public.app_branding_settings (singleton, app_title, logo_url)
values (true, 'ClubCashBuddy', null)
on conflict (singleton) do nothing;

create or replace function public.public_get_branding_settings()
returns table(
  app_title text,
  logo_url text
)
language sql
security definer
as $function$
  select
    s.app_title,
    s.logo_url
  from public.app_branding_settings s
  where s.singleton = true;
$function$;

revoke all on function public.public_get_branding_settings() from public;
grant execute on function public.public_get_branding_settings() to anon, authenticated;

create or replace function public.admin_get_branding_settings()
returns table(
  app_title text,
  logo_url text,
  updated_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select
    s.app_title,
    s.logo_url,
    s.updated_at
  from public.app_branding_settings s
  where s.singleton = true;
end;
$function$;

revoke all on function public.admin_get_branding_settings() from public;
grant execute on function public.admin_get_branding_settings() to authenticated;

create or replace function public.admin_upsert_branding_settings(
  p_app_title text default null::text,
  p_logo_url text default null::text
)
returns table(
  app_title text,
  logo_url text,
  updated_at timestamp with time zone
)
language plpgsql
security definer
as $function$
declare
  v_current_title text;
  v_current_logo text;
  v_title text;
  v_logo text;
begin
  perform public.assert_admin();

  select s.app_title, s.logo_url
  into v_current_title, v_current_logo
  from public.app_branding_settings s
  where s.singleton = true;

  v_title := coalesce(nullif(trim(coalesce(p_app_title, '')), ''), v_current_title, 'ClubCashBuddy');
  v_logo := case
    when p_logo_url is null then v_current_logo
    else nullif(trim(p_logo_url), '')
  end;

  insert into public.app_branding_settings (singleton, app_title, logo_url, updated_at, updated_by)
  values (true, v_title, v_logo, now(), public.app_current_user_id())
  on conflict (singleton) do update
    set app_title = excluded.app_title,
        logo_url = excluded.logo_url,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by;

  return query
  select
    s.app_title,
    s.logo_url,
    s.updated_at
  from public.app_branding_settings s
  where s.singleton = true;
end;
$function$;

revoke all on function public.admin_upsert_branding_settings(text, text) from public;
grant execute on function public.admin_upsert_branding_settings(text, text) to authenticated;

create or replace function public.api_admin_get_branding_settings(
  p_token text
)
returns table(
  app_title text,
  logo_url text,
  updated_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_branding_settings();
end;
$function$;

revoke all on function public.api_admin_get_branding_settings(text) from public;

create or replace function public.api_admin_upsert_branding_settings(
  p_token text,
  p_app_title text default null::text,
  p_logo_url text default null::text
)
returns table(
  app_title text,
  logo_url text,
  updated_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_upsert_branding_settings(p_app_title, p_logo_url);
end;
$function$;

revoke all on function public.api_admin_upsert_branding_settings(text, text, text) from public;



