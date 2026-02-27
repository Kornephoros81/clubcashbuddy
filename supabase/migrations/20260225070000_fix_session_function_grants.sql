-- Fix execute grants for session/login functions used by backend service role.

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.app_apply_session(text) to service_role';
    execute 'grant execute on function public.app_login_user(text, text, integer) to service_role';
    execute 'grant execute on function public.app_login_device_key(text, integer) to service_role';
    execute 'grant execute on function public.app_login_device_pair_code(text, integer) to service_role';
    execute 'grant execute on function public.app_logout(text) to service_role';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.app_apply_session(text) to authenticated';
  end if;
end
$$;
