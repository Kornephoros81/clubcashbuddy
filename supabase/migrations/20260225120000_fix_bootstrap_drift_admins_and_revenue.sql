-- Fix bootstrap drift:
-- 1) revenue report RPC must support pagination (p_limit, p_offset)
-- 2) admin app-user management must not depend on dropped public.admins table

drop function if exists public.api_admin_get_revenue_report_period(text, timestamp with time zone, timestamp with time zone);
drop function if exists public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone);

create or replace function public.admin_get_revenue_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_limit integer default null,
  p_offset integer default 0
)
returns table(
  event_type text,
  event_at timestamp with time zone,
  local_day date,
  transaction_created_at timestamp with time zone,
  member_id uuid,
  member_name text,
  product_id uuid,
  product_name text,
  product_category text,
  transaction_type text,
  amount integer,
  amount_abs integer,
  is_free_amount boolean,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  with tx as (
    select
      'booking'::text as event_type,
      t.created_at as event_at,
      (t.created_at at time zone 'Europe/Berlin')::date as local_day,
      t.created_at as transaction_created_at,
      t.member_id,
      (
        coalesce(
          nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
          nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
          t.member_name_snapshot,
          'Unbekanntes Mitglied'
        )
        || case when coalesce(m.is_guest, ma.is_guest, false) then ' (Gast)' else '' end
      ) as member_name,
      t.product_id,
      coalesce(
        p.name,
        pa.name,
        t.product_name_snapshot,
        case when t.product_id is null then 'Freier Betrag' else 'Unbekanntes Produkt' end
      ) as product_name,
      coalesce(
        p.category,
        pa.category,
        case when t.product_id is null then 'Freier Betrag' else 'Unbekannt' end
      ) as product_category,
      coalesce(t.transaction_type, case when t.product_id is null then 'sale_free_amount' else 'sale_product' end) as transaction_type,
      t.amount,
      abs(t.amount)::int as amount_abs,
      (t.product_id is null) as is_free_amount,
      t.note
    from public.transactions t
    left join public.members m on m.id = t.member_id
    left join public.members_archive ma on ma.id = t.member_id
    left join public.products p on p.id = t.product_id
    left join public.products_archive pa on pa.id = t.product_id
    where t.created_at >= p_start
      and t.created_at < p_end
      and t.amount <> 0
  ),
  sl as (
    select
      'cancellation'::text as event_type,
      s.canceled_at as event_at,
      (s.canceled_at at time zone 'Europe/Berlin')::date as local_day,
      s.transaction_created_at,
      s.member_id,
      (
        coalesce(
          nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
          nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
          'Unbekanntes Mitglied'
        )
        || case when coalesce(m.is_guest, ma.is_guest, false) then ' (Gast)' else '' end
      ) as member_name,
      s.product_id,
      coalesce(
        p.name,
        pa.name,
        case when s.product_id is null then 'Freier Betrag' else 'Unbekanntes Produkt' end
      ) as product_name,
      coalesce(
        p.category,
        pa.category,
        case when s.product_id is null then 'Freier Betrag' else 'Unbekannt' end
      ) as product_category,
      coalesce(s.transaction_type, case when s.product_id is null then 'sale_free_amount' else 'sale_product' end) as transaction_type,
      s.amount,
      abs(s.amount)::int as amount_abs,
      (s.product_id is null) as is_free_amount,
      s.note
    from public.storno_log s
    left join public.members m on m.id = s.member_id
    left join public.members_archive ma on ma.id = s.member_id
    left join public.products p on p.id = s.product_id
    left join public.products_archive pa on pa.id = s.product_id
    where s.canceled_at >= p_start
      and s.canceled_at < p_end
      and s.amount <> 0
  )
  select * from (
    select * from tx
    union all
    select * from sl
  ) u
  order by u.event_at desc, u.event_type asc
  limit coalesce(p_limit, 2147483647)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$function$;

revoke all on function public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone, integer, integer) from public;
grant execute on function public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone, integer, integer) to authenticated;

create or replace function public.api_admin_get_revenue_report_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_limit integer default null,
  p_offset integer default 0
)
returns table(
  event_type text,
  event_at timestamp with time zone,
  local_day date,
  transaction_created_at timestamp with time zone,
  member_id uuid,
  member_name text,
  product_id uuid,
  product_name text,
  product_category text,
  transaction_type text,
  amount integer,
  amount_abs integer,
  is_free_amount boolean,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_revenue_report_period(p_start, p_end, p_limit, p_offset);
end;
$function$;

revoke all on function public.api_admin_get_revenue_report_period(text, timestamp with time zone, timestamp with time zone, integer, integer) from public;

create or replace function public.admin_list_app_users()
returns table(
  id uuid,
  username text,
  role text,
  is_admin boolean,
  active boolean,
  created_at timestamp with time zone,
  last_login_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    u.id,
    u.username,
    u.role,
    (u.role = 'admin') as is_admin,
    u.active,
    u.created_at,
    u.last_login_at
  from public.app_users u
  where u.role in ('admin', 'operator')
  order by lower(u.username), u.created_at desc;
end;
$function$;

create or replace function public.admin_create_app_user(
  p_username text,
  p_password text,
  p_is_admin boolean default true,
  p_active boolean default true
)
returns table(
  id uuid,
  username text,
  role text,
  is_admin boolean,
  active boolean,
  created_at timestamp with time zone,
  last_login_at timestamp with time zone
)
language plpgsql
security definer
as $function$
declare
  v_user_id uuid;
  v_username text;
  v_password text;
  v_is_admin boolean;
  v_active boolean;
begin
  perform public.assert_admin();

  v_username := trim(coalesce(p_username, ''));
  v_password := coalesce(p_password, '');
  v_is_admin := coalesce(p_is_admin, true);
  v_active := coalesce(p_active, true);

  if v_username = '' then
    raise exception 'USERNAME_REQUIRED';
  end if;
  if length(v_password) < 4 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

  insert into public.app_users (username, password_hash, role, active)
  values (
    v_username,
    crypt(v_password, gen_salt('bf')),
    case when v_is_admin then 'admin' else 'operator' end,
    v_active
  )
  returning app_users.id into v_user_id;

  return query
  select
    u.id,
    u.username,
    u.role,
    (u.role = 'admin') as is_admin,
    u.active,
    u.created_at,
    u.last_login_at
  from public.app_users u
  where u.id = v_user_id;
end;
$function$;

create or replace function public.admin_update_app_user(
  p_user_id uuid,
  p_username text default null::text,
  p_password text default null::text,
  p_is_admin boolean default null::boolean,
  p_active boolean default null::boolean
)
returns table(
  id uuid,
  username text,
  role text,
  is_admin boolean,
  active boolean,
  created_at timestamp with time zone,
  last_login_at timestamp with time zone
)
language plpgsql
security definer
as $function$
declare
  v_user public.app_users%rowtype;
  v_is_admin_current boolean;
  v_is_admin_next boolean;
  v_active_next boolean;
  v_username_next text;
  v_current_user_id uuid;
  v_other_active_admins integer;
begin
  perform public.assert_admin();

  select u.*
  into v_user
  from public.app_users u
  where u.id = p_user_id
  limit 1;

  if v_user.id is null then
    raise exception 'USER_NOT_FOUND';
  end if;

  if v_user.role not in ('admin', 'operator') then
    raise exception 'USER_ROLE_NOT_MANAGEABLE';
  end if;

  v_is_admin_current := (v_user.role = 'admin');
  v_is_admin_next := coalesce(p_is_admin, v_is_admin_current);
  v_active_next := coalesce(p_active, v_user.active);
  v_username_next := coalesce(nullif(trim(coalesce(p_username, '')), ''), v_user.username);
  v_current_user_id := public.app_current_user_id();

  if p_password is not null and length(trim(p_password)) > 0 and length(trim(p_password)) < 4 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

  if v_user.id = v_current_user_id and (v_is_admin_next = false or v_active_next = false) then
    raise exception 'SELF_ADMIN_LOCKOUT_FORBIDDEN';
  end if;

  if v_is_admin_current and (v_is_admin_next = false or v_active_next = false) then
    select count(*)::int
    into v_other_active_admins
    from public.app_users u
    where u.id <> v_user.id
      and u.role = 'admin'
      and u.active = true;

    if coalesce(v_other_active_admins, 0) = 0 then
      raise exception 'LAST_ACTIVE_ADMIN_REQUIRED';
    end if;
  end if;

  update public.app_users u
  set
    username = v_username_next,
    role = case when v_is_admin_next then 'admin' else 'operator' end,
    active = v_active_next,
    password_hash = case
      when p_password is null or length(trim(p_password)) = 0 then u.password_hash
      else crypt(trim(p_password), gen_salt('bf'))
    end
  where u.id = v_user.id;

  return query
  select
    u.id,
    u.username,
    u.role,
    (u.role = 'admin') as is_admin,
    u.active,
    u.created_at,
    u.last_login_at
  from public.app_users u
  where u.id = v_user.id;
end;
$function$;

notify pgrst, 'reload schema';
