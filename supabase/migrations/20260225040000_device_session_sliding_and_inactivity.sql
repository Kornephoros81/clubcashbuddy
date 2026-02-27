-- Device sessions:
-- - sliding expiration (180 days) while active
-- - revoke/deny if device session was inactive for more than 30 days

create or replace function public.app_apply_session(p_token text)
returns table(actor_type text, actor_id uuid, role text)
language plpgsql
security definer
as $function$
declare
  v_hash text;
  v_sess record;
  v_now timestamp with time zone;
begin
  if nullif(trim(coalesce(p_token, '')), '') is null then
    raise exception 'Unauthorized';
  end if;

  v_hash := encode(digest(p_token, 'sha256'), 'hex');
  v_now := now();

  select s.*
  into v_sess
  from public.app_sessions s
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > v_now
  limit 1;

  if v_sess.id is null then
    raise exception 'Unauthorized';
  end if;

  -- Device must reconnect at least every 30 days, otherwise session is invalidated.
  if v_sess.actor_type = 'device'
     and coalesce(v_sess.last_seen_at, v_sess.created_at, v_now) < (v_now - interval '30 days') then
    update public.app_sessions
    set revoked_at = v_now
    where id = v_sess.id;
    raise exception 'Unauthorized';
  end if;

  update public.app_sessions s
  set
    last_seen_at = v_now,
    expires_at = case
      when s.actor_type = 'device' then v_now + interval '180 days'
      else s.expires_at
    end
  where s.id = v_sess.id;

  perform set_config('app.role', v_sess.role, true);
  if v_sess.actor_type = 'user' then
    perform set_config('app.user_id', v_sess.actor_id::text, true);
    perform set_config('app.device_id', '', true);
  else
    perform set_config('app.user_id', '', true);
    perform set_config('app.device_id', v_sess.actor_id::text, true);
  end if;

  actor_type := v_sess.actor_type;
  actor_id := v_sess.actor_id;
  role := v_sess.role;
  return next;
end;
$function$;

revoke all on function public.app_apply_session(text) from public;

create or replace function public.app_login_device_key(
  p_device_key text,
  p_ttl_days integer default 180
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
    now() + make_interval(days => greatest(coalesce(p_ttl_days, 180), 1))
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

