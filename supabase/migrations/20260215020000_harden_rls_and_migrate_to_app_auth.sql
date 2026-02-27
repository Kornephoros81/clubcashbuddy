-- Hard migration: remove Supabase-auth coupling and move to app-managed auth/session context.
-- No fallback path is kept.

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 1) App-managed auth tables
-- ------------------------------------------------------------
create table if not exists public.app_users (
  id uuid not null default gen_random_uuid(),
  username text not null,
  password_hash text not null,
  role text not null,
  active boolean not null default true,
  created_at timestamp with time zone not null default now(),
  last_login_at timestamp with time zone null,
  constraint app_users_pkey primary key (id),
  constraint app_users_username_key unique (username),
  constraint app_users_role_chk check (role in ('admin', 'operator', 'device', 'service'))
);

create table if not exists public.app_sessions (
  id uuid not null default gen_random_uuid(),
  token_hash text not null,
  actor_type text not null,
  actor_id uuid not null,
  role text not null,
  expires_at timestamp with time zone not null,
  revoked_at timestamp with time zone null,
  created_at timestamp with time zone not null default now(),
  last_seen_at timestamp with time zone null,
  user_agent text null,
  ip inet null,
  constraint app_sessions_pkey primary key (id),
  constraint app_sessions_token_hash_key unique (token_hash),
  constraint app_sessions_actor_type_chk check (actor_type in ('user', 'device')),
  constraint app_sessions_role_chk check (role in ('admin', 'operator', 'device', 'service'))
);

create index if not exists app_sessions_actor_idx on public.app_sessions(actor_type, actor_id);
create index if not exists app_sessions_expires_idx on public.app_sessions(expires_at);

-- ------------------------------------------------------------
-- 2) Device credential migration (drop legacy plaintext secret)
-- ------------------------------------------------------------
alter table public.kiosk_devices
  add column if not exists secret_hash text;

update public.kiosk_devices
set secret_hash = crypt(device_secret, gen_salt('bf'))
where secret_hash is null
  and device_secret is not null;

alter table public.kiosk_devices
  alter column secret_hash set not null;

alter table public.kiosk_devices
  drop column if exists device_secret;

-- ------------------------------------------------------------
-- 3) Backfill app_users from existing actor UUIDs
-- ------------------------------------------------------------
with actor_ids as (
  select user_id as id from public.admins
  union
  select user_id as id from public.settlements
  union
  select deleted_by as id from public.members_archive where deleted_by is not null
  union
  select deleted_by as id from public.products_archive where deleted_by is not null
  union
  select created_by as id from public.inventory_movements where created_by is not null
)
insert into public.app_users (id, username, password_hash, role, active)
select
  a.id,
  'legacy-' || substr(a.id::text, 1, 8) as username,
  crypt(encode(gen_random_bytes(24), 'hex'), gen_salt('bf')) as password_hash,
  case when exists (select 1 from public.admins ad where ad.user_id = a.id) then 'admin' else 'operator' end as role,
  true as active
from actor_ids a
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- 4) Remove auth.users coupling (FKs -> app_users)
-- ------------------------------------------------------------
alter table public.members_archive
  drop constraint if exists members_archive_deleted_by_fkey;
alter table public.products_archive
  drop constraint if exists products_archive_deleted_by_fkey;
alter table public.inventory_movements
  drop constraint if exists inventory_movements_created_by_fkey;
alter table public.settlements
  drop constraint if exists settlements_user_id_fkey;

alter table public.members_archive
  add constraint members_archive_deleted_by_fkey
  foreign key (deleted_by) references public.app_users(id);

alter table public.products_archive
  add constraint products_archive_deleted_by_fkey
  foreign key (deleted_by) references public.app_users(id);

alter table public.inventory_movements
  add constraint inventory_movements_created_by_fkey
  foreign key (created_by) references public.app_users(id);

alter table public.settlements
  add constraint settlements_user_id_fkey
  foreign key (user_id) references public.app_users(id);

alter table public.admins
  drop constraint if exists admins_user_id_fkey;
alter table public.admins
  add constraint admins_user_id_fkey
  foreign key (user_id) references public.app_users(id) on delete cascade;

-- ------------------------------------------------------------
-- 5) Session context helpers (app.*)
-- ------------------------------------------------------------
create or replace function public.app_current_role()
returns text
language sql
stable
as $function$
select nullif(current_setting('app.role', true), '');
$function$;

create or replace function public.app_current_user_id()
returns uuid
language plpgsql
stable
as $function$
declare
  v text;
begin
  v := nullif(current_setting('app.user_id', true), '');
  if v is null then
    return null;
  end if;
  return v::uuid;
exception when others then
  return null;
end;
$function$;

create or replace function public.app_current_device_id()
returns uuid
language plpgsql
stable
as $function$
declare
  v text;
begin
  v := nullif(current_setting('app.device_id', true), '');
  if v is null then
    return null;
  end if;
  return v::uuid;
exception when others then
  return null;
end;
$function$;

create or replace function public.app_apply_session(p_token text)
returns table(actor_type text, actor_id uuid, role text)
language plpgsql
security definer
as $function$
declare
  v_hash text;
  v_sess record;
begin
  if nullif(trim(coalesce(p_token, '')), '') is null then
    raise exception 'Unauthorized';
  end if;

  v_hash := encode(digest(p_token, 'sha256'), 'hex');

  select s.*
  into v_sess
  from public.app_sessions s
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > now()
  limit 1;

  if v_sess.id is null then
    raise exception 'Unauthorized';
  end if;

  update public.app_sessions
  set last_seen_at = now()
  where id = v_sess.id;

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

create or replace function public.app_login_user(
  p_username text,
  p_password text,
  p_ttl_hours integer default 8
)
returns text
language plpgsql
security definer
as $function$
declare
  v_user public.app_users%rowtype;
  v_token text;
begin
  select *
  into v_user
  from public.app_users u
  where lower(u.username) = lower(trim(coalesce(p_username, '')))
    and u.active = true
  limit 1;

  if v_user.id is null or v_user.password_hash <> crypt(coalesce(p_password, ''), v_user.password_hash) then
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
    'user',
    v_user.id,
    v_user.role,
    now() + make_interval(hours => greatest(coalesce(p_ttl_hours, 8), 1))
  );

  update public.app_users
  set last_login_at = now()
  where id = v_user.id;

  return v_token;
end;
$function$;

create or replace function public.app_login_device(
  p_device_name text,
  p_device_secret text,
  p_ttl_days integer default 30
)
returns text
language plpgsql
security definer
as $function$
declare
  v_device public.kiosk_devices%rowtype;
  v_token text;
begin
  select *
  into v_device
  from public.kiosk_devices kd
  where lower(kd.name) = lower(trim(coalesce(p_device_name, '')))
    and kd.active = true
  limit 1;

  if v_device.id is null or v_device.secret_hash <> crypt(coalesce(p_device_secret, ''), v_device.secret_hash) then
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

  return v_token;
end;
$function$;

create or replace function public.app_logout(p_token text)
returns void
language plpgsql
security definer
as $function$
begin
  if nullif(trim(coalesce(p_token, '')), '') is null then
    return;
  end if;

  update public.app_sessions
  set revoked_at = now()
  where token_hash = encode(digest(p_token, 'sha256'), 'hex')
    and revoked_at is null;
end;
$function$;

-- ------------------------------------------------------------
-- 6) Guards migrated to app.* context
-- ------------------------------------------------------------
create or replace function public.assert_admin()
returns void
language plpgsql
security definer
as $function$
declare
  v_user_id uuid;
begin
  v_user_id := public.app_current_user_id();

  if public.app_current_role() is null or v_user_id is null then
    raise exception 'Unauthorized';
  end if;

  if public.app_current_role() <> 'admin' then
    raise exception 'Forbidden';
  end if;

  if not exists (
    select 1
    from public.admins a
    where a.user_id = v_user_id
  ) then
    raise exception 'Forbidden';
  end if;
end;
$function$;

create or replace function public.assert_device()
returns void
language plpgsql
security definer
as $function$
declare
  v_device_id uuid;
begin
  v_device_id := public.app_current_device_id();

  if public.app_current_role() is null or v_device_id is null then
    raise exception 'Unauthorized';
  end if;

  if public.app_current_role() <> 'device' then
    raise exception 'Forbidden';
  end if;

  if not exists (
    select 1
    from public.kiosk_devices kd
    where kd.id = v_device_id
      and kd.active = true
  ) then
    raise exception 'Forbidden';
  end if;
end;
$function$;

-- ------------------------------------------------------------
-- 7) Rebind auth-sensitive functions
-- ------------------------------------------------------------
create or replace function public.delete_member_safely(
  p_member_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
declare
  v_member public.members%rowtype;
  v_open_tx integer;
begin
  perform public.assert_admin();

  select *
  into v_member
  from public.members m
  where m.id = p_member_id;

  if not found then
    raise exception 'Mitglied nicht gefunden';
  end if;

  if not p_force and coalesce(v_member.balance, 0) <> 0 then
    raise exception 'Mitglied hat noch einen Saldo. Fuer hard delete p_force=true setzen.';
  end if;

  if not p_force then
    select count(*)::int
    into v_open_tx
    from public.transactions t
    where t.member_id = p_member_id
      and t.settled_at is null;

    if coalesce(v_open_tx, 0) > 0 then
      raise exception 'Mitglied hat noch offene Buchungen. Fuer hard delete p_force=true setzen.';
    end if;
  end if;

  insert into public.members_archive (
    id, firstname, lastname, is_guest, active, balance, settled, created_at, last_settled_at, deleted_at, deleted_by
  ) values (
    v_member.id, v_member.firstname, v_member.lastname, v_member.is_guest, v_member.active, v_member.balance, v_member.settled, v_member.created_at, v_member.last_settled_at, now(), public.app_current_user_id()
  )
  on conflict (id) do update
  set
    firstname = excluded.firstname,
    lastname = excluded.lastname,
    is_guest = excluded.is_guest,
    active = excluded.active,
    balance = excluded.balance,
    settled = excluded.settled,
    created_at = excluded.created_at,
    last_settled_at = excluded.last_settled_at,
    deleted_at = excluded.deleted_at,
    deleted_by = excluded.deleted_by;

  delete from public.members m
  where m.id = p_member_id;
end;
$function$;

create or replace function public.delete_product_safely(
  p_product_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
declare
  v_product public.products%rowtype;
begin
  perform public.assert_admin();

  select *
  into v_product
  from public.products p
  where p.id = p_product_id;

  if not found then
    raise exception 'Produkt nicht gefunden';
  end if;

  if not p_force and (coalesce(v_product.warehouse_stock, 0) <> 0 or coalesce(v_product.fridge_stock, 0) <> 0) then
    raise exception 'Produkt hat noch Bestand. Fuer hard delete p_force=true setzen.';
  end if;

  insert into public.products_archive (
    id, name, price, guest_price, category, active, inventoried, created_at, deleted_at, deleted_by
  ) values (
    v_product.id, v_product.name, v_product.price, v_product.guest_price, v_product.category, v_product.active, v_product.inventoried, v_product.created_at, now(), public.app_current_user_id()
  )
  on conflict (id) do update
  set
    name = excluded.name,
    price = excluded.price,
    guest_price = excluded.guest_price,
    category = excluded.category,
    active = excluded.active,
    inventoried = excluded.inventoried,
    created_at = excluded.created_at,
    deleted_at = excluded.deleted_at,
    deleted_by = excluded.deleted_by;

  delete from public.products p
  where p.id = p_product_id;
end;
$function$;

create or replace function public.admin_perform_monthly_settlement()
returns void
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  perform public.perform_monthly_settlement(public.app_current_user_id());
end;
$function$;

create or replace function public.admin_apply_inventory_count(
  p_items jsonb,
  p_note text default null
)
returns table(
  product_id uuid,
  name text,
  soll_warehouse_stock integer,
  ist_warehouse_stock integer,
  delta_warehouse integer,
  soll_fridge_stock integer,
  ist_fridge_stock integer,
  delta_fridge integer
)
language plpgsql
security definer
as $function$
declare
  v_wh uuid;
  v_fr uuid;
  v_item record;
  v_product record;
  v_stock record;
  v_ist_wh integer;
  v_ist_fr integer;
  v_delta_wh integer;
  v_delta_fr integer;
begin
  perform public.assert_admin();

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  v_fr := public.get_stock_location_id('fridge');
  if v_wh is null or v_fr is null then
    raise exception 'Stock locations are not configured';
  end if;

  for v_item in
    select *
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      ist_warehouse_stock integer,
      ist_fridge_stock integer
    )
  loop
    if v_item.product_id is null then
      raise exception 'product_id is required';
    end if;
    if v_item.ist_warehouse_stock is null or v_item.ist_fridge_stock is null then
      raise exception 'ist_warehouse_stock and ist_fridge_stock are required';
    end if;
    if v_item.ist_warehouse_stock < 0 or v_item.ist_fridge_stock < 0 then
      raise exception 'Ist stock cannot be negative';
    end if;

    select p.id, p.name
    into v_product
    from public.products p
    where p.id = v_item.product_id
      and p.inventoried = true
    limit 1;

    if v_product.id is null then
      raise exception 'Inventoried product not found: %', v_item.product_id;
    end if;

    select warehouse_qty, fridge_qty
    into v_stock
    from public.get_product_stock(v_item.product_id);

    v_ist_wh := v_item.ist_warehouse_stock;
    v_ist_fr := v_item.ist_fridge_stock;
    v_delta_wh := v_ist_wh - coalesce(v_stock.warehouse_qty, 0);
    v_delta_fr := v_ist_fr - coalesce(v_stock.fridge_qty, 0);

    if v_delta_wh <> 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_wh),
        case when v_delta_wh < 0 then v_wh else null end,
        case when v_delta_wh > 0 then v_wh else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Lager'),
        public.app_current_user_id(),
        jsonb_build_object(
          'source', 'inventory_count',
          'location', 'warehouse',
          'expected', coalesce(v_stock.warehouse_qty, 0),
          'counted', v_ist_wh,
          'delta', v_delta_wh
        )
      );
    end if;

    if v_delta_fr <> 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_fr),
        case when v_delta_fr < 0 then v_fr else null end,
        case when v_delta_fr > 0 then v_fr else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Kuehlschrank'),
        public.app_current_user_id(),
        jsonb_build_object(
          'source', 'inventory_count',
          'location', 'fridge',
          'expected', coalesce(v_stock.fridge_qty, 0),
          'counted', v_ist_fr,
          'delta', v_delta_fr
        )
      );
    end if;

    product_id := v_item.product_id;
    name := v_product.name;
    soll_warehouse_stock := coalesce(v_stock.warehouse_qty, 0);
    ist_warehouse_stock := v_ist_wh;
    delta_warehouse := v_delta_wh;
    soll_fridge_stock := coalesce(v_stock.fridge_qty, 0);
    ist_fridge_stock := v_ist_fr;
    delta_fridge := v_delta_fr;
    return next;
  end loop;

  return;
end;
$function$;

-- ------------------------------------------------------------
-- 8) RLS hardening (deny direct table access)
-- ------------------------------------------------------------
drop policy if exists read_own_admin_row on public.admins;
drop policy if exists no_direct_insert_stock_adjustments on public.stock_adjustments;
drop policy if exists read_stock_adjustments_admins on public.stock_adjustments;

alter table public.admins enable row level security;
alter table public.kiosk_devices enable row level security;
alter table public.products enable row level security;
alter table public.members enable row level security;
alter table public.stock_adjustments enable row level security;
alter table public.settlements enable row level security;
alter table public.transactions enable row level security;
alter table public.members_archive enable row level security;
alter table public.products_archive enable row level security;
alter table public.stock_locations enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.app_users enable row level security;
alter table public.app_sessions enable row level security;

revoke all on table public.admins from public;
revoke all on table public.kiosk_devices from public;
revoke all on table public.products from public;
revoke all on table public.members from public;
revoke all on table public.stock_adjustments from public;
revoke all on table public.settlements from public;
revoke all on table public.transactions from public;
revoke all on table public.members_archive from public;
revoke all on table public.products_archive from public;
revoke all on table public.stock_locations from public;
revoke all on table public.inventory_movements from public;
revoke all on table public.app_users from public;
revoke all on table public.app_sessions from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.admins from anon';
    execute 'revoke all on table public.kiosk_devices from anon';
    execute 'revoke all on table public.products from anon';
    execute 'revoke all on table public.members from anon';
    execute 'revoke all on table public.stock_adjustments from anon';
    execute 'revoke all on table public.settlements from anon';
    execute 'revoke all on table public.transactions from anon';
    execute 'revoke all on table public.members_archive from anon';
    execute 'revoke all on table public.products_archive from anon';
    execute 'revoke all on table public.stock_locations from anon';
    execute 'revoke all on table public.inventory_movements from anon';
    execute 'revoke all on table public.app_users from anon';
    execute 'revoke all on table public.app_sessions from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.admins from authenticated';
    execute 'revoke all on table public.kiosk_devices from authenticated';
    execute 'revoke all on table public.products from authenticated';
    execute 'revoke all on table public.members from authenticated';
    execute 'revoke all on table public.stock_adjustments from authenticated';
    execute 'revoke all on table public.settlements from authenticated';
    execute 'revoke all on table public.transactions from authenticated';
    execute 'revoke all on table public.members_archive from authenticated';
    execute 'revoke all on table public.products_archive from authenticated';
    execute 'revoke all on table public.stock_locations from authenticated';
    execute 'revoke all on table public.inventory_movements from authenticated';
    execute 'revoke all on table public.app_users from authenticated';
    execute 'revoke all on table public.app_sessions from authenticated';
  end if;
end
$$;

-- Supabase role grants removed; function execution is now meant for backend DB role only.
revoke all on function public.assert_admin() from public;
revoke all on function public.assert_device() from public;
revoke all on function public.app_login_user(text, text, integer) from public;
revoke all on function public.app_login_device(text, text, integer) from public;
revoke all on function public.app_apply_session(text) from public;
revoke all on function public.app_logout(text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.assert_admin() from anon';
    execute 'revoke all on function public.assert_device() from anon';
    execute 'revoke all on function public.app_login_user(text, text, integer) from anon';
    execute 'revoke all on function public.app_login_device(text, text, integer) from anon';
    execute 'revoke all on function public.app_apply_session(text) from anon';
    execute 'revoke all on function public.app_logout(text) from anon';
    execute 'revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid) from anon';
    execute 'revoke all on function public.cancel_transaction(uuid, uuid, uuid, text) from anon';
    execute 'revoke all on function public.admin_list_members() from anon';
    execute 'revoke all on function public.admin_create_member(text, text) from anon';
    execute 'revoke all on function public.admin_update_member(uuid, text, text, integer, boolean) from anon';
    execute 'revoke all on function public.admin_delete_member(uuid, boolean) from anon';
    execute 'revoke all on function public.admin_list_products() from anon';
    execute 'revoke all on function public.admin_create_product(text, integer, integer, text, boolean, boolean) from anon';
    execute 'revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean) from anon';
    execute 'revoke all on function public.admin_delete_product(uuid, boolean) from anon';
    execute 'revoke all on function public.admin_get_all_bookings_grouped(timestamp with time zone, timestamp with time zone) from anon';
    execute 'revoke all on function public.admin_perform_monthly_settlement() from anon';
    execute 'revoke all on function public.admin_get_inventory_snapshot() from anon';
    execute 'revoke all on function public.admin_apply_inventory_count(jsonb, text) from anon';
    execute 'revoke all on function public.admin_get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) from anon';
    execute 'revoke all on function public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone) from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.assert_admin() from authenticated';
    execute 'revoke all on function public.assert_device() from authenticated';
    execute 'revoke all on function public.app_login_user(text, text, integer) from authenticated';
    execute 'revoke all on function public.app_login_device(text, text, integer) from authenticated';
    execute 'revoke all on function public.app_apply_session(text) from authenticated';
    execute 'revoke all on function public.app_logout(text) from authenticated';
    execute 'revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid) from authenticated';
    execute 'revoke all on function public.cancel_transaction(uuid, uuid, uuid, text) from authenticated';
    execute 'revoke all on function public.admin_list_members() from authenticated';
    execute 'revoke all on function public.admin_create_member(text, text) from authenticated';
    execute 'revoke all on function public.admin_update_member(uuid, text, text, integer, boolean) from authenticated';
    execute 'revoke all on function public.admin_delete_member(uuid, boolean) from authenticated';
    execute 'revoke all on function public.admin_list_products() from authenticated';
    execute 'revoke all on function public.admin_create_product(text, integer, integer, text, boolean, boolean) from authenticated';
    execute 'revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean) from authenticated';
    execute 'revoke all on function public.admin_delete_product(uuid, boolean) from authenticated';
    execute 'revoke all on function public.admin_get_all_bookings_grouped(timestamp with time zone, timestamp with time zone) from authenticated';
    execute 'revoke all on function public.admin_perform_monthly_settlement() from authenticated';
    execute 'revoke all on function public.admin_get_inventory_snapshot() from authenticated';
    execute 'revoke all on function public.admin_apply_inventory_count(jsonb, text) from authenticated';
    execute 'revoke all on function public.admin_get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) from authenticated';
    execute 'revoke all on function public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone) from authenticated';
  end if;
end
$$;
