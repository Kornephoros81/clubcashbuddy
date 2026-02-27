-- Allow admins to create kiosk devices directly from admin UI.

create or replace function public.admin_create_kiosk_device(
  p_name text,
  p_device_key text,
  p_active boolean default true
)
returns table(
  id uuid,
  name text,
  active boolean,
  last_seen_at timestamp with time zone,
  created_at timestamp with time zone
)
language plpgsql
security definer
as $function$
declare
  v_name text;
  v_key text;
begin
  perform public.assert_admin();

  v_name := nullif(trim(coalesce(p_name, '')), '');
  v_key := nullif(trim(coalesce(p_device_key, '')), '');

  if v_name is null then
    raise exception 'DEVICE_NAME_REQUIRED';
  end if;

  if v_key is null then
    raise exception 'DEVICE_KEY_REQUIRED';
  end if;

  if length(v_key) < 4 then
    raise exception 'DEVICE_KEY_TOO_SHORT';
  end if;

  insert into public.kiosk_devices (
    name,
    secret_hash,
    active
  ) values (
    v_name,
    crypt(v_key, gen_salt('bf')),
    coalesce(p_active, true)
  )
  returning
    kiosk_devices.id,
    kiosk_devices.name,
    kiosk_devices.active,
    kiosk_devices.last_seen_at,
    kiosk_devices.created_at
  into id, name, active, last_seen_at, created_at;

  return next;
end;
$function$;

revoke all on function public.admin_create_kiosk_device(text, text, boolean) from public;
grant execute on function public.admin_create_kiosk_device(text, text, boolean) to authenticated;

create or replace function public.api_admin_create_kiosk_device(
  p_token text,
  p_name text,
  p_device_key text,
  p_active boolean default true
)
returns table(
  id uuid,
  name text,
  active boolean,
  last_seen_at timestamp with time zone,
  created_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_create_kiosk_device(p_name, p_device_key, p_active);
end;
$function$;

revoke all on function public.api_admin_create_kiosk_device(text, text, text, boolean) from public;
