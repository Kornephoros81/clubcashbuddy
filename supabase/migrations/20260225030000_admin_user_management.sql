-- Admin user management RPCs (list/create/update) with safety guards.

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
    exists(select 1 from public.admins a where a.user_id = u.id) as is_admin,
    u.active,
    u.created_at,
    u.last_login_at
  from public.app_users u
  where u.role in ('admin', 'operator')
  order by lower(u.username), u.created_at desc;
end;
$function$;

revoke all on function public.admin_list_app_users() from public;
grant execute on function public.admin_list_app_users() to authenticated;

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

  if v_is_admin then
    insert into public.admins (user_id)
    values (v_user_id)
    on conflict (user_id) do nothing;
  end if;

  return query
  select
    u.id,
    u.username,
    u.role,
    exists(select 1 from public.admins a where a.user_id = u.id) as is_admin,
    u.active,
    u.created_at,
    u.last_login_at
  from public.app_users u
  where u.id = v_user_id;
end;
$function$;

revoke all on function public.admin_create_app_user(text, text, boolean, boolean) from public;
grant execute on function public.admin_create_app_user(text, text, boolean, boolean) to authenticated;

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

  select exists(select 1 from public.admins a where a.user_id = v_user.id) into v_is_admin_current;
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
    join public.admins a on a.user_id = u.id
    where u.id <> v_user.id
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

  if v_is_admin_next then
    insert into public.admins (user_id)
    values (v_user.id)
    on conflict (user_id) do nothing;
  else
    delete from public.admins a
    where a.user_id = v_user.id;
  end if;

  return query
  select
    u.id,
    u.username,
    u.role,
    exists(select 1 from public.admins a where a.user_id = u.id) as is_admin,
    u.active,
    u.created_at,
    u.last_login_at
  from public.app_users u
  where u.id = v_user.id;
end;
$function$;

revoke all on function public.admin_update_app_user(uuid, text, text, boolean, boolean) from public;
grant execute on function public.admin_update_app_user(uuid, text, text, boolean, boolean) to authenticated;

create or replace function public.api_admin_list_app_users(
  p_token text
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
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_app_users();
end;
$function$;

revoke all on function public.api_admin_list_app_users(text) from public;

create or replace function public.api_admin_create_app_user(
  p_token text,
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
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_create_app_user(p_username, p_password, p_is_admin, p_active);
end;
$function$;

revoke all on function public.api_admin_create_app_user(text, text, text, boolean, boolean) from public;

create or replace function public.api_admin_update_app_user(
  p_token text,
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
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_update_app_user(p_user_id, p_username, p_password, p_is_admin, p_active);
end;
$function$;

revoke all on function public.api_admin_update_app_user(text, uuid, text, text, boolean, boolean) from public;
