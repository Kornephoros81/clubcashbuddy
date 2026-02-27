-- Support legacy "single device key" login against kiosk_devices.secret_hash
-- while issuing app_sessions tokens (no JWT verification required).

create or replace function public.app_login_device_key(
  p_device_key text,
  p_ttl_days integer default 30
)
returns table(
  token text,
  device_id uuid,
  device_name text
)
language plpgsql
security definer
as $function$
declare
  v_device public.kiosk_devices%rowtype;
  v_token text;
begin
  if nullif(trim(coalesce(p_device_key, '')), '') is null then
    raise exception 'Missing key';
  end if;

  select kd.*
  into v_device
  from public.kiosk_devices kd
  where kd.active = true
    and kd.secret_hash = crypt(p_device_key, kd.secret_hash)
  limit 1;

  if v_device.id is null then
    raise exception 'Unauthorized';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');

  insert into public.app_sessions (
    token_hash,
    actor_type,
    actor_id,
    role,
    expires_at
  ) values (
    encode(digest(v_token, 'sha256'), 'hex'),
    'device',
    v_device.id,
    'device',
    now() + make_interval(days => greatest(coalesce(p_ttl_days, 30), 1))
  );

  update public.kiosk_devices
  set last_seen_at = now()
  where id = v_device.id;

  token := v_token;
  device_id := v_device.id;
  device_name := v_device.name;
  return next;
end;
$function$;

revoke all on function public.app_login_device_key(text, integer) from public;
