-- Replace member hard delete archive table with soft archives on members.

alter table public.members
  add column if not exists archived_at timestamp with time zone null;

alter table public.members
  add column if not exists archived_by uuid null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'members_archived_by_fkey'
      and conrelid = 'public.members'::regclass
  ) then
    alter table public.members
      add constraint members_archived_by_fkey
      foreign key (archived_by)
      references public.app_users (id)
      on delete set null;
  end if;
end $$;

create index if not exists members_archived_at_idx
  on public.members (archived_at);

create index if not exists members_active_unarchived_idx
  on public.members (active, archived_at)
  where archived_at is null;

create or replace function public.member_name_key(p_value text)
returns text
language sql
immutable
as $function$
  select lower(regexp_replace(btrim(coalesce(p_value, '')), '[[:space:]]+', ' ', 'g'));
$function$;

drop function if exists public.api_admin_list_members_token(text);
drop function if exists public.admin_list_members();

create or replace function public.admin_list_members()
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone,
  archived_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    m.id,
    m.firstname,
    m.lastname,
    m.balance,
    m.active,
    m.created_at,
    m.archived_at
  from public.members m
  where m.is_guest = false
    and m.archived_at is null
  order by m.lastname asc, m.firstname asc;
end;
$function$;

create or replace function public.api_admin_list_members_token(p_token text)
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone,
  archived_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_members();
end;
$function$;

create or replace function public.admin_list_archived_members()
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone,
  archived_at timestamp with time zone,
  last_settled_at timestamp with time zone,
  last_booking_at timestamp with time zone,
  open_transactions integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    m.id,
    m.firstname,
    m.lastname,
    m.balance,
    m.active,
    m.created_at,
    m.archived_at,
    m.last_settled_at,
    max(t.created_at) as last_booking_at,
    count(t.id) filter (where t.settled_at is null)::integer as open_transactions
  from public.members m
  left join public.transactions t on t.member_id = m.id
  where m.is_guest = false
    and m.archived_at is not null
  group by
    m.id,
    m.firstname,
    m.lastname,
    m.balance,
    m.active,
    m.created_at,
    m.archived_at,
    m.last_settled_at
  order by m.archived_at desc, m.lastname asc, m.firstname asc;
end;
$function$;

create or replace function public.admin_find_archived_member_candidates(
  p_firstname text,
  p_lastname text
)
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone,
  archived_at timestamp with time zone,
  last_settled_at timestamp with time zone,
  last_booking_at timestamp with time zone,
  open_transactions integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select *
  from public.admin_list_archived_members() m
  where public.member_name_key(m.firstname) = public.member_name_key(p_firstname)
    and public.member_name_key(m.lastname) = public.member_name_key(p_lastname)
  order by m.archived_at desc;
end;
$function$;

create or replace function public.admin_archive_member(p_member_id uuid)
returns public.members
language plpgsql
security definer
as $function$
declare
  v_member public.members;
  v_open_transactions integer;
begin
  perform public.assert_admin();

  select *
  into v_member
  from public.members m
  where m.id = p_member_id
    and m.is_guest = false;

  if v_member.id is null then
    raise exception 'Mitglied nicht gefunden';
  end if;

  if v_member.archived_at is not null then
    return v_member;
  end if;

  select count(*)::integer
  into v_open_transactions
  from public.transactions t
  where t.member_id = p_member_id
    and t.settled_at is null;

  if coalesce(v_open_transactions, 0) > 0 then
    raise exception 'ARCHIVE_OPEN_TRANSACTIONS:%', v_open_transactions;
  end if;

  if coalesce(v_member.balance, 0) <> 0 then
    raise exception 'ARCHIVE_BALANCE_NOT_ZERO:%', v_member.balance;
  end if;

  update public.members m
  set
    active = false,
    archived_at = now(),
    archived_by = public.app_current_user_id()
  where m.id = p_member_id
  returning * into v_member;

  return v_member;
end;
$function$;

create or replace function public.admin_restore_archived_member(p_member_id uuid)
returns public.members
language plpgsql
security definer
as $function$
declare
  v_member public.members;
begin
  perform public.assert_admin();

  update public.members m
  set
    active = false,
    archived_at = null,
    archived_by = null
  where m.id = p_member_id
    and m.is_guest = false
    and m.archived_at is not null
  returning * into v_member;

  if v_member.id is null then
    raise exception 'Archiviertes Mitglied nicht gefunden';
  end if;

  return v_member;
end;
$function$;

create or replace function public.admin_delete_member(
  p_member_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.admin_archive_member(p_member_id);
end;
$function$;

create or replace function public.delete_member_safely(
  p_member_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.admin_archive_member(p_member_id);
end;
$function$;

create or replace function public.api_admin_list_archived_members(p_token text)
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone,
  archived_at timestamp with time zone,
  last_settled_at timestamp with time zone,
  last_booking_at timestamp with time zone,
  open_transactions integer
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_archived_members();
end;
$function$;

create or replace function public.api_admin_find_archived_member_candidates(
  p_token text,
  p_firstname text,
  p_lastname text
)
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone,
  archived_at timestamp with time zone,
  last_settled_at timestamp with time zone,
  last_booking_at timestamp with time zone,
  open_transactions integer
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_find_archived_member_candidates(p_firstname, p_lastname);
end;
$function$;

create or replace function public.api_admin_archive_member(
  p_token text,
  p_member_id uuid
)
returns public.members
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_archive_member(p_member_id);
end;
$function$;

create or replace function public.api_admin_restore_archived_member(
  p_token text,
  p_member_id uuid
)
returns public.members
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_restore_archived_member(p_member_id);
end;
$function$;

create or replace function public.api_admin_delete_member(
  p_token text,
  p_member_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.admin_archive_member(p_member_id);
end;
$function$;

create or replace function public.get_fridge_refills_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  stock_adjustment_id uuid,
  product_id uuid,
  product_name text,
  product_category text,
  quantity integer,
  member_id uuid,
  member_name text,
  device_id uuid,
  device_name text,
  note text
)
language sql
security definer
as $function$
select
  sa.created_at,
  (sa.created_at at time zone 'Europe/Berlin')::date as local_day,
  sa.id as stock_adjustment_id,
  sa.product_id,
  coalesce(p.name, sa.product_name_snapshot, 'Unbekanntes Produkt') as product_name,
  coalesce(p.category, sa.product_category_snapshot, '-') as product_category,
  sa.quantity::int as quantity,
  sa.member_id,
  coalesce(
    nullif(sa.member_name_snapshot, ''),
    nullif(trim(concat_ws(' ', m.firstname, m.lastname)), ''),
    'Unbekannt'
  ) as member_name,
  sa.device_id,
  kd.name as device_name,
  sa.note
from public.stock_adjustments sa
left join public.products p
  on p.id = sa.product_id
left join public.members m
  on m.id = sa.member_id
left join public.kiosk_devices kd
  on kd.id = sa.device_id
where sa.created_at >= p_start
  and sa.created_at < p_end
  and sa.quantity > 0
order by sa.created_at desc;
$function$;

create or replace function public.get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  warehouse_stock integer,
  soll_warehouse_stock integer,
  delta_warehouse integer,
  fridge_stock integer,
  soll_fridge_stock integer,
  delta_fridge integer,
  current_stock integer,
  consumed integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer,
  refilled_by text
)
language sql
security definer
as $function$
with
  loc as (
    select
      public.get_stock_location_id('warehouse') as wh_id,
      public.get_stock_location_id('fridge') as fr_id
  ),
  mv_period as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.reason = 'purchase' and im.to_location_id = loc.wh_id then im.quantity
          else 0
        end
      ), 0)::int as purchased,
      coalesce(sum(
        case
          when im.reason = 'transfer'
           and im.from_location_id = loc.wh_id
           and im.to_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as transferred_to_fridge,
      coalesce(sum(
        case
          when im.reason = 'sale'
           and im.from_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as consumed_mv,
      coalesce(sum(
        case
          when im.reason in ('shrinkage', 'waste', 'count_adjustment')
          then im.quantity
          else 0
        end
      ), 0)::int as shrinkage
    from public.inventory_movements im
    cross join loc
    where im.created_at >= p_start
      and im.created_at < p_end
    group by im.product_id
  ),
  mv_total as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.to_location_id = loc.wh_id then im.quantity
          when im.from_location_id = loc.wh_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_warehouse_stock,
      coalesce(sum(
        case
          when im.to_location_id = loc.fr_id then im.quantity
          when im.from_location_id = loc.fr_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_fridge_stock
    from public.inventory_movements im
    cross join loc
    group by im.product_id
  ),
  tx as (
    select
      t.product_id,
      count(*)::int as consumed_tx
    from public.transactions t
    where t.product_id is not null
      and t.amount < 0
      and t.created_at >= p_start
      and t.created_at < p_end
    group by t.product_id
  ),
  sa_period as (
    select
      sa.product_id,
      string_agg(
        distinct coalesce(
          nullif(sa.member_name_snapshot, ''),
          nullif(trim(concat_ws(' ', m.firstname, m.lastname)), ''),
          'Unbekannt'
        ),
        ', '
      ) as refilled_by
    from public.stock_adjustments sa
    left join public.members m
      on m.id = sa.member_id
    where sa.created_at >= p_start
      and sa.created_at < p_end
      and sa.quantity > 0
      and sa.product_id is not null
    group by sa.product_id
  )
select
  p.id as product_id,
  p.name as name,
  p.category as category,
  p.active as active,
  coalesce(p.warehouse_stock, 0)::int as warehouse_stock,
  coalesce(mv_total.soll_warehouse_stock, 0)::int as soll_warehouse_stock,
  (coalesce(p.warehouse_stock, 0) - coalesce(mv_total.soll_warehouse_stock, 0))::int as delta_warehouse,
  coalesce(p.fridge_stock, 0)::int as fridge_stock,
  coalesce(mv_total.soll_fridge_stock, 0)::int as soll_fridge_stock,
  (coalesce(p.fridge_stock, 0) - coalesce(mv_total.soll_fridge_stock, 0))::int as delta_fridge,
  (coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0))::int as current_stock,
  greatest(coalesce(mv_period.consumed_mv, 0), coalesce(tx.consumed_tx, 0))::int as consumed,
  coalesce(mv_period.transferred_to_fridge, 0)::int as transferred_to_fridge,
  coalesce(mv_period.purchased, 0)::int as purchased,
  coalesce(mv_period.shrinkage, 0)::int as shrinkage,
  coalesce(sa_period.refilled_by, '-') as refilled_by
from public.products p
left join mv_period on mv_period.product_id = p.id
left join mv_total on mv_total.product_id = p.id
left join tx on tx.product_id = p.id
left join sa_period on sa_period.product_id = p.id
where p.inventoried = true
order by p.active desc, p.category, p.name;
$function$;

create or replace function public.get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(local_day date, member_id uuid, member_name text, member_active boolean, total integer, items jsonb)
language sql
security definer
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  t.member_id as member_id,
  (
    coalesce(
      nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
      t.member_name_snapshot,
      '[Geloeschtes Mitglied]'
    )
    ||
    case when coalesce(m.is_guest, false) then ' (Gast)' else '' end
  ) as member_name,
  coalesce(m.active, false) as member_active,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'settled_at', t.settled_at,
      'product_id', t.product_id,
      'product_name', coalesce(p.name, pa.name, t.product_name_snapshot),
      'device_name', coalesce(kd.name, t.device_id_snapshot::text, t.device_id::text, '-'),
      'transaction_type', coalesce(
        t.transaction_type,
        case
          when coalesce(t.amount, 0) > 0 then 'credit_adjustment'
          when t.product_id is null then 'sale_free_amount'
          else 'sale_product'
        end
      )
    )
    order by t.created_at desc
  ) as items
from public.transactions t
left join public.members m on m.id = t.member_id
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
left join public.kiosk_devices kd on kd.id = t.device_id
where t.created_at >= p_start
  and t.created_at < p_end
group by local_day, t.member_id, member_name, member_active
order by local_day desc, member_name;
$function$;

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
  product_cost_snapshot_cents integer,
  cost_amount_abs integer,
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
          t.member_name_snapshot,
          'Unbekanntes Mitglied'
        )
        || case when coalesce(m.is_guest, false) then ' (Gast)' else '' end
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
      coalesce(t.product_cost_snapshot_cents, 0)::int as product_cost_snapshot_cents,
      coalesce(t.product_cost_snapshot_cents, 0)::int as cost_amount_abs,
      (t.product_id is null) as is_free_amount,
      t.note
    from public.transactions t
    left join public.members m on m.id = t.member_id
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
          'Unbekanntes Mitglied'
        )
        || case when coalesce(m.is_guest, false) then ' (Gast)' else '' end
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
      coalesce(s.product_cost_snapshot_cents, 0)::int as product_cost_snapshot_cents,
      coalesce(s.product_cost_snapshot_cents, 0)::int as cost_amount_abs,
      (s.product_id is null) as is_free_amount,
      s.note
    from public.storno_log s
    left join public.members m on m.id = s.member_id
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

create or replace function public.admin_get_settlements_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  settled_at timestamp with time zone,
  local_day date,
  settlement_id uuid,
  member_id uuid,
  member_name text,
  user_id uuid,
  user_name text,
  amount integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    s.settled_at,
    (s.settled_at at time zone 'Europe/Berlin')::date as local_day,
    s.id as settlement_id,
    s.member_id,
    coalesce(
      nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
      '[Unbekanntes Mitglied]'
    ) as member_name,
    s.user_id,
    coalesce(
      nullif(trim(u.username), ''),
      '[Unbekannter Benutzer]'
    ) as user_name,
    s.amount
  from public.settlements s
  left join public.members m on m.id = s.member_id
  left join public.app_users u on u.id = s.user_id
  where s.settled_at >= p_start
    and s.settled_at < p_end
  order by s.settled_at desc;
end;
$function$;

create or replace function public.admin_get_complimentary_report_period(
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
  amount_abs integer,
  cost_amount_abs integer,
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
          t.member_name_snapshot,
          'Unbekanntes Mitglied'
        )
        || case when coalesce(m.is_guest, false) then ' (Gast)' else '' end
      ) as member_name,
      t.product_id,
      coalesce(p.name, pa.name, t.product_name_snapshot, 'Unbekanntes Produkt') as product_name,
      coalesce(p.category, pa.category, 'Unbekannt') as product_category,
      abs(coalesce(nullif(t.product_price_snapshot, 0), p.guest_price, pa.guest_price, p.price, pa.price, t.amount, 0))::int as amount_abs,
      coalesce(t.product_cost_snapshot_cents, 0)::int as cost_amount_abs,
      t.note
    from public.transactions t
    left join public.members m on m.id = t.member_id
    left join public.products p on p.id = t.product_id
    left join public.products_archive pa on pa.id = t.product_id
    where t.transaction_type = 'complimentary_product'
      and t.product_id is not null
      and t.created_at >= p_start
      and t.created_at < p_end
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
          'Unbekanntes Mitglied'
        )
        || case when coalesce(m.is_guest, false) then ' (Gast)' else '' end
      ) as member_name,
      s.product_id,
      coalesce(p.name, pa.name, 'Unbekanntes Produkt') as product_name,
      coalesce(p.category, pa.category, 'Unbekannt') as product_category,
      abs(coalesce(p.guest_price, pa.guest_price, p.price, pa.price, s.amount, 0))::int as amount_abs,
      coalesce(s.product_cost_snapshot_cents, 0)::int as cost_amount_abs,
      s.note
    from public.storno_log s
    left join public.members m on m.id = s.member_id
    left join public.products p on p.id = s.product_id
    left join public.products_archive pa on pa.id = s.product_id
    where s.transaction_type = 'complimentary_product'
      and s.product_id is not null
      and s.canceled_at >= p_start
      and s.canceled_at < p_end
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

revoke all on function public.member_name_key(text) from public;
revoke all on function public.admin_list_members() from public;
revoke all on function public.api_admin_list_members_token(text) from public;
revoke all on function public.admin_list_archived_members() from public;
revoke all on function public.admin_find_archived_member_candidates(text, text) from public;
revoke all on function public.admin_archive_member(uuid) from public;
revoke all on function public.admin_restore_archived_member(uuid) from public;
revoke all on function public.api_admin_list_archived_members(text) from public;
revoke all on function public.api_admin_find_archived_member_candidates(text, text, text) from public;
revoke all on function public.api_admin_archive_member(text, uuid) from public;
revoke all on function public.api_admin_restore_archived_member(text, uuid) from public;

grant execute on function public.admin_list_members() to authenticated;
grant execute on function public.admin_list_archived_members() to authenticated;
grant execute on function public.admin_find_archived_member_candidates(text, text) to authenticated;
grant execute on function public.admin_archive_member(uuid) to authenticated;
grant execute on function public.admin_restore_archived_member(uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_list_members_token(text) to service_role';
    execute 'grant execute on function public.api_admin_list_archived_members(text) to service_role';
    execute 'grant execute on function public.api_admin_find_archived_member_candidates(text, text, text) to service_role';
    execute 'grant execute on function public.api_admin_archive_member(text, uuid) to service_role';
    execute 'grant execute on function public.api_admin_restore_archived_member(text, uuid) to service_role';
    execute 'grant execute on function public.api_admin_delete_member(text, uuid, boolean) to service_role';
  end if;
end $$;

drop table if exists public.members_archive;

notify pgrst, 'reload schema';
