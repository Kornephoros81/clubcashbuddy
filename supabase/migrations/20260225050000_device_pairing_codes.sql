-- One-time device pairing codes for secure terminal onboarding.

create table if not exists public.device_pairing_codes (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.kiosk_devices(id) on delete cascade,
  code_hash text not null,
  created_by uuid null references public.app_users(id) on delete set null,
  created_at timestamp with time zone not null default now(),
  expires_at timestamp with time zone not null,
  used_at timestamp with time zone null
);

create index if not exists device_pairing_codes_device_idx
  on public.device_pairing_codes(device_id, created_at desc);

create index if not exists device_pairing_codes_hash_idx
  on public.device_pairing_codes(code_hash);

create index if not exists device_pairing_codes_open_idx
  on public.device_pairing_codes(expires_at, used_at)
  where used_at is null;

create or replace function public.admin_list_kiosk_devices()
returns table(
  id uuid,
  name text,
  active boolean,
  last_seen_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select
    d.id,
    d.name,
    d.active,
    d.last_seen_at
  from public.kiosk_devices d
  order by lower(d.name), d.created_at;
end;
$function$;

revoke all on function public.admin_list_kiosk_devices() from public;
grant execute on function public.admin_list_kiosk_devices() to authenticated;

create or replace function public.admin_create_device_pairing_code(
  p_device_id uuid,
  p_ttl_minutes integer default 5
)
returns table(
  pairing_code text,
  expires_at timestamp with time zone,
  device_id uuid,
  device_name text
)
language plpgsql
security definer
as $function$
declare
  v_code text;
  v_hash text;
  v_ttl integer;
  v_device public.kiosk_devices%rowtype;
  v_try integer;
begin
  perform public.assert_admin();

  if p_device_id is null then
    raise exception 'DEVICE_ID_REQUIRED';
  end if;

  select *
  into v_device
  from public.kiosk_devices d
  where d.id = p_device_id
  limit 1;

  if v_device.id is null then
    raise exception 'DEVICE_NOT_FOUND';
  end if;

  if coalesce(v_device.active, false) = false then
    raise exception 'DEVICE_INACTIVE';
  end if;

  v_ttl := greatest(coalesce(p_ttl_minutes, 5), 1);

  for v_try in 1..10 loop
    v_code := lpad((floor(random() * 1000000))::integer::text, 6, '0');
    v_hash := encode(digest(v_code, 'sha256'), 'hex');
    exit when not exists (
      select 1
      from public.device_pairing_codes c
      where c.code_hash = v_hash
        and c.used_at is null
        and c.expires_at > now()
    );
  end loop;

  if v_code is null then
    raise exception 'PAIRING_CODE_GENERATION_FAILED';
  end if;

  insert into public.device_pairing_codes (
    device_id,
    code_hash,
    created_by,
    expires_at
  ) values (
    v_device.id,
    v_hash,
    public.app_current_user_id(),
    now() + make_interval(mins => v_ttl)
  );

  pairing_code := v_code;
  expires_at := now() + make_interval(mins => v_ttl);
  device_id := v_device.id;
  device_name := v_device.name;
  return next;
end;
$function$;

revoke all on function public.admin_create_device_pairing_code(uuid, integer) from public;
grant execute on function public.admin_create_device_pairing_code(uuid, integer) to authenticated;

create or replace function public.app_login_device_pair_code(
  p_pair_code text,
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
  v_hash text;
  v_device_id uuid;
  v_device_name text;
  v_token text;
begin
  if nullif(trim(coalesce(p_pair_code, '')), '') is null then
    raise exception 'PAIR_CODE_REQUIRED';
  end if;

  v_hash := encode(digest(trim(p_pair_code), 'sha256'), 'hex');

  with candidate as (
    select
      c.id,
      c.device_id,
      d.name as device_name
    from public.device_pairing_codes c
    join public.kiosk_devices d on d.id = c.device_id
    where c.code_hash = v_hash
      and c.used_at is null
      and c.expires_at > now()
      and d.active = true
    order by c.created_at desc
    limit 1
    for update of c skip locked
  ),
  marked as (
    update public.device_pairing_codes c
    set used_at = now()
    from candidate x
    where c.id = x.id
      and c.used_at is null
    returning x.device_id, x.device_name
  )
  select m.device_id, m.device_name
  into v_device_id, v_device_name
  from marked m
  limit 1;

  if v_device_id is null then
    raise exception 'PAIR_CODE_INVALID_OR_EXPIRED';
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
    v_device_id,
    'device',
    now() + make_interval(days => greatest(coalesce(p_ttl_days, 180), 1))
  );

  update public.kiosk_devices
  set last_seen_at = now()
  where id = v_device_id;

  token := v_token;
  device_id := v_device_id;
  device_name := v_device_name;
  return next;
end;
$function$;

revoke all on function public.app_login_device_pair_code(text, integer) from public;

create or replace function public.api_admin_list_kiosk_devices(
  p_token text
)
returns table(
  id uuid,
  name text,
  active boolean,
  last_seen_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_kiosk_devices();
end;
$function$;

revoke all on function public.api_admin_list_kiosk_devices(text) from public;

create or replace function public.api_admin_create_device_pairing_code(
  p_token text,
  p_device_id uuid,
  p_ttl_minutes integer default 5
)
returns table(
  pairing_code text,
  expires_at timestamp with time zone,
  device_id uuid,
  device_name text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_create_device_pairing_code(p_device_id, p_ttl_minutes);
end;
$function$;

revoke all on function public.api_admin_create_device_pairing_code(text, uuid, integer) from public;
