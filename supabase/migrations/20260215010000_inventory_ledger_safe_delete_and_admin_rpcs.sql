-- Inventory ledger (warehouse + fridge), safe hard delete with archives,
-- and admin RPC wrappers to reduce dependency on custom admin edge functions.

-- ------------------------------------------------------------
-- 1) Product stock split
-- ------------------------------------------------------------
alter table public.products
  add column if not exists warehouse_stock integer not null default 0,
  add column if not exists fridge_stock integer not null default 0,
  add column if not exists min_warehouse integer not null default 0,
  add column if not exists min_fridge integer not null default 0;

-- ------------------------------------------------------------
-- 2) Archive tables for hard deletes (history keeps stable names)
-- ------------------------------------------------------------
create table if not exists public.members_archive (
  id uuid primary key,
  firstname text null,
  lastname text null,
  is_guest boolean not null default false,
  active boolean not null default false,
  balance integer not null default 0,
  settled boolean not null default false,
  created_at timestamp with time zone null,
  last_settled_at timestamp with time zone null,
  deleted_at timestamp with time zone not null default now(),
  deleted_by uuid null references auth.users (id)
) tablespace pg_default;

create table if not exists public.products_archive (
  id uuid primary key,
  name text not null,
  price integer not null,
  guest_price integer not null default 0,
  category text not null default 'Sonstiges'::text,
  active boolean not null default false,
  inventoried boolean not null default true,
  created_at timestamp with time zone null,
  deleted_at timestamp with time zone not null default now(),
  deleted_by uuid null references auth.users (id)
) tablespace pg_default;

-- ------------------------------------------------------------
-- 3) Stock locations + movement ledger
-- ------------------------------------------------------------
create table if not exists public.stock_locations (
  id uuid not null default gen_random_uuid(),
  code text not null,
  name text not null,
  constraint stock_locations_pkey primary key (id),
  constraint stock_locations_code_key unique (code)
) tablespace pg_default;

insert into public.stock_locations (code, name)
values
  ('warehouse', 'Lager'),
  ('fridge', 'Kuehlschrank')
on conflict (code) do nothing;

create table if not exists public.inventory_movements (
  id uuid not null default gen_random_uuid(),
  product_id uuid not null,
  quantity integer not null,
  from_location_id uuid null references public.stock_locations (id),
  to_location_id uuid null references public.stock_locations (id),
  reason text not null,
  transaction_id uuid null,
  stock_adjustment_id uuid null,
  device_id uuid null references public.kiosk_devices (id),
  note text null,
  created_at timestamp with time zone not null default now(),
  created_by uuid null references auth.users (id),
  meta jsonb not null default '{}'::jsonb,
  constraint inventory_movements_pkey primary key (id),
  constraint inventory_movements_qty_chk check (quantity > 0),
  constraint inventory_movements_reason_chk check (
    reason in (
      'opening_balance',
      'purchase',
      'transfer',
      'sale',
      'sale_cancel',
      'count_adjustment',
      'shrinkage',
      'waste'
    )
  ),
  constraint inventory_movements_from_to_chk check (
    from_location_id is distinct from to_location_id
  ),
  constraint inventory_movements_any_side_chk check (
    from_location_id is not null or to_location_id is not null
  )
) tablespace pg_default;

create index if not exists inventory_movements_product_id_idx
  on public.inventory_movements using btree (product_id) tablespace pg_default;

create index if not exists inventory_movements_created_at_idx
  on public.inventory_movements using btree (created_at desc) tablespace pg_default;

create index if not exists inventory_movements_reason_idx
  on public.inventory_movements using btree (reason) tablespace pg_default;

create index if not exists inventory_movements_transaction_id_idx
  on public.inventory_movements using btree (transaction_id) tablespace pg_default;

create index if not exists inventory_movements_stock_adjustment_id_idx
  on public.inventory_movements using btree (stock_adjustment_id) tablespace pg_default;

-- Keep snapshots in transactions for resilient reporting after hard deletes.
alter table public.transactions
  add column if not exists member_name_snapshot text null,
  add column if not exists product_name_snapshot text null,
  add column if not exists product_price_snapshot integer null;

-- ------------------------------------------------------------
-- 4) Helpers and sync functions
-- ------------------------------------------------------------
create or replace function public.get_stock_location_id(p_code text)
returns uuid
language sql
stable
as $function$
  select sl.id
  from public.stock_locations sl
  where sl.code = p_code
  limit 1;
$function$;

create or replace function public.get_product_stock(p_product_id uuid)
returns table(warehouse_qty integer, fridge_qty integer, total_qty integer)
language sql
stable
as $function$
with loc as (
  select
    public.get_stock_location_id('warehouse') as wh_id,
    public.get_stock_location_id('fridge') as fr_id
)
select
  coalesce(sum(
    case
      when im.to_location_id = loc.wh_id then im.quantity
      when im.from_location_id = loc.wh_id then -im.quantity
      else 0
    end
  ), 0)::int as warehouse_qty,
  coalesce(sum(
    case
      when im.to_location_id = loc.fr_id then im.quantity
      when im.from_location_id = loc.fr_id then -im.quantity
      else 0
    end
  ), 0)::int as fridge_qty,
  coalesce(sum(
    case
      when im.to_location_id = loc.wh_id then im.quantity
      when im.from_location_id = loc.wh_id then -im.quantity
      else 0
    end
  ), 0)::int
  +
  coalesce(sum(
    case
      when im.to_location_id = loc.fr_id then im.quantity
      when im.from_location_id = loc.fr_id then -im.quantity
      else 0
    end
  ), 0)::int as total_qty
from public.inventory_movements im
cross join loc
where im.product_id = p_product_id;
$function$;

create or replace function public.refresh_product_stock(p_product_id uuid)
returns void
language plpgsql
security definer
as $function$
declare
  v_warehouse integer;
  v_fridge integer;
  v_total integer;
begin
  select warehouse_qty, fridge_qty, total_qty
  into v_warehouse, v_fridge, v_total
  from public.get_product_stock(p_product_id);

  update public.products p
  set
    warehouse_stock = coalesce(v_warehouse, 0),
    fridge_stock = coalesce(v_fridge, 0),
    stored = greatest(least(coalesce(v_total, 0), 32767), -32768)::smallint
  where p.id = p_product_id;
end;
$function$;

create or replace function public.trg_refresh_product_stock_from_movement()
returns trigger
language plpgsql
security definer
as $function$
begin
  perform public.refresh_product_stock(new.product_id);
  return new;
end;
$function$;

drop trigger if exists tg_refresh_product_stock_from_movement on public.inventory_movements;
create trigger tg_refresh_product_stock_from_movement
after insert on public.inventory_movements
for each row
execute function public.trg_refresh_product_stock_from_movement();

-- ------------------------------------------------------------
-- 5) Backfill opening balance from current products.stored once
-- ------------------------------------------------------------
insert into public.inventory_movements (
  product_id,
  quantity,
  from_location_id,
  to_location_id,
  reason,
  note,
  created_at,
  meta
)
select
  p.id as product_id,
  abs(coalesce(p.stored, 0))::int as quantity,
  case
    when coalesce(p.stored, 0) < 0 then public.get_stock_location_id('warehouse')
    else null
  end as from_location_id,
  case
    when coalesce(p.stored, 0) > 0 then public.get_stock_location_id('warehouse')
    else null
  end as to_location_id,
  'opening_balance' as reason,
  'Initialer Bestandsuebertrag aus products.stored' as note,
  coalesce(p.last_restocked_at, now()) as created_at,
  jsonb_build_object('source', 'products.stored')
from public.products p
where coalesce(p.stored, 0) <> 0
  and not exists (
    select 1
    from public.inventory_movements im
    where im.product_id = p.id
  );

do $$
declare
  r record;
begin
  for r in select p.id from public.products p loop
    perform public.refresh_product_stock(r.id);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 6) Stock adjustments now represent transfer warehouse -> fridge
-- ------------------------------------------------------------
create or replace function public.trg_stock_adjustments_to_inventory_movements()
returns trigger
language plpgsql
security definer
as $function$
declare
  v_wh uuid;
  v_fr uuid;
begin
  if coalesce(new.quantity, 0) = 0 then
    return new;
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  v_fr := public.get_stock_location_id('fridge');

  if new.quantity > 0 then
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      stock_adjustment_id,
      device_id,
      note,
      created_at,
      meta
    ) values (
      new.product_id,
      new.quantity,
      v_wh,
      v_fr,
      'transfer',
      new.id,
      new.device_id,
      new.note,
      new.created_at,
      jsonb_build_object('source', 'stock_adjustments')
    );
  else
    -- Negative quantity means moving stock back out of fridge to warehouse.
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      stock_adjustment_id,
      device_id,
      note,
      created_at,
      meta
    ) values (
      new.product_id,
      abs(new.quantity),
      v_fr,
      v_wh,
      'transfer',
      new.id,
      new.device_id,
      coalesce(new.note, 'Rueckraeumung'),
      new.created_at,
      jsonb_build_object('source', 'stock_adjustments')
    );
  end if;

  update public.products p
  set last_restocked_at = greatest(coalesce(p.last_restocked_at, '-infinity'::timestamptz), new.created_at)
  where p.id = new.product_id;

  return new;
end;
$function$;

drop trigger if exists tg_stock_adjustments_to_inventory_movements on public.stock_adjustments;
create trigger tg_stock_adjustments_to_inventory_movements
after insert on public.stock_adjustments
for each row
execute function public.trg_stock_adjustments_to_inventory_movements();

-- Backfill historical stock_adjustments into movements once.
insert into public.inventory_movements (
  product_id,
  quantity,
  from_location_id,
  to_location_id,
  reason,
  stock_adjustment_id,
  device_id,
  note,
  created_at,
  meta
)
select
  sa.product_id,
  abs(sa.quantity)::int,
  case when sa.quantity > 0 then public.get_stock_location_id('warehouse') else public.get_stock_location_id('fridge') end,
  case when sa.quantity > 0 then public.get_stock_location_id('fridge') else public.get_stock_location_id('warehouse') end,
  'transfer',
  sa.id,
  sa.device_id,
  sa.note,
  sa.created_at,
  jsonb_build_object('source', 'stock_adjustments_backfill')
from public.stock_adjustments sa
where not exists (
  select 1
  from public.inventory_movements im
  where im.stock_adjustment_id = sa.id
);

-- ------------------------------------------------------------
-- 7) FK behavior: preserve history when members/products are deleted
-- ------------------------------------------------------------
alter table public.transactions drop constraint if exists transactions_member_id_fkey;
alter table public.transactions drop constraint if exists transactions_product_id_fkey;
alter table public.stock_adjustments drop constraint if exists stock_adjustments_product_id_fkey;
alter table public.settlements drop constraint if exists settlements_member_id_fkey;

-- ------------------------------------------------------------
-- 8) add_storage now writes ledger (purchase / correction), not direct counters
-- ------------------------------------------------------------
create or replace function public.add_storage(product_id uuid, amount integer)
returns void
language plpgsql
security definer
as $function$
declare
  v_wh uuid;
begin
  if coalesce(amount, 0) = 0 then
    return;
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  if v_wh is null then
    raise exception 'Stock location warehouse not configured';
  end if;

  if amount > 0 then
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      meta
    ) values (
      product_id,
      amount,
      null,
      v_wh,
      'purchase',
      'Einlagerung',
      jsonb_build_object('source', 'add_storage')
    );

    update public.products p
    set last_restocked_at = now()
    where p.id = product_id;
  else
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      meta
    ) values (
      product_id,
      abs(amount),
      v_wh,
      null,
      'count_adjustment',
      'Bestandskorrektur Lager',
      jsonb_build_object('source', 'add_storage')
    );
  end if;
end;
$function$;

-- ------------------------------------------------------------
-- 9) Booking / cancellation now writes inventory movements
-- ------------------------------------------------------------
create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid
)
returns uuid
language plpgsql
security definer
as $function$
declare
  amt integer;
  pid uuid;
  note text;
  txid uuid;
  is_guest boolean;
  v_inventoried boolean;
  v_member_name text;
  v_product_name text;
  v_price_snapshot integer;
  v_fr uuid;
begin
  select
    m.is_guest,
    nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), '')
  into is_guest, v_member_name
  from public.members m
  where m.id = member_id;

  if product_id is not null then
    select
      case when is_guest then p.guest_price else p.price end,
      p.inventoried,
      p.name
    into amt, v_inventoried, v_product_name
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    v_price_snapshot := amt;
    amt := -abs(amt);
    pid := product_id;
    note := null;
  else
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;
    note := coalesce(p_note, 'frei');
    v_inventoried := false;
  end if;

  insert into public.transactions (
    member_id,
    product_id,
    amount,
    note,
    client_tx_id,
    member_name_snapshot,
    product_name_snapshot,
    product_price_snapshot
  )
  values (
    member_id,
    pid,
    amt,
    note,
    client_tx_id_param,
    coalesce(v_member_name, member_id::text),
    v_product_name,
    v_price_snapshot
  )
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null and coalesce(v_inventoried, true) then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      transaction_id,
      note,
      meta
    ) values (
      pid,
      1,
      v_fr,
      null,
      'sale',
      txid,
      'Verkauf',
      jsonb_build_object('source', 'book_transaction')
    );
  end if;

  if txid is null and client_tx_id_param is not null then
    select t.id into txid
    from public.transactions t
    where t.client_tx_id = client_tx_id_param;
  end if;

  return txid;
end;
$function$;

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
  v_member_active boolean;
  v_canceled_at timestamp with time zone;
  v_fr uuid;
begin
  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null and note is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen storniert werden';
  end if;

  select m.active into v_member_active
  from public.members m
  where m.id = v_tx.member_id;

  if coalesce(v_member_active, false) = false then
    raise exception 'Buchungen von inaktiven Mitgliedern duerfen nicht storniert werden';
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  v_canceled_at := now();

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is null then
    raise exception 'Storno fehlgeschlagen';
  end if;

  insert into public.storno_log (
    original_transaction_id,
    member_id,
    product_id,
    transaction_created_at,
    canceled_at,
    amount,
    note
  ) values (
    v_tx.id,
    v_tx.member_id,
    v_tx.product_id,
    v_tx.created_at,
    v_canceled_at,
    v_tx.amount,
    v_tx.note
  );

  if v_tx.product_id is not null then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      meta
    ) values (
      v_tx.product_id,
      1,
      null,
      v_fr,
      'sale_cancel',
      'Storno Rueckbuchung',
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    );
  end if;

  return v_cancel_id;
end;
$function$;

-- ------------------------------------------------------------
-- 10) Views/reports switched to the new stock fields
-- ------------------------------------------------------------
drop function if exists public.get_stock_report_period(timestamp with time zone, timestamp with time zone);
drop view if exists public.stock_overview;

create or replace view public.stock_overview as
select
  p.id as product_id,
  coalesce(p.warehouse_stock, 0) as warehouse_stock,
  coalesce(p.fridge_stock, 0) as fridge_stock,
  (coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0)) as current_stock,
  p.last_restocked_at as last_refill
from public.products p
where p.inventoried = true
  and p.active = true;

create or replace function public.get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  current_stock integer,
  refilled integer,
  consumed integer,
  warehouse_stock integer,
  fridge_stock integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer
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
  mv as (
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
  tx as (
    -- Legacy fallback for older data before movement backfill
    select
      t.product_id,
      count(*)::int as consumed_tx
    from public.transactions t
    where t.product_id is not null
      and t.amount < 0
      and t.created_at >= p_start
      and t.created_at < p_end
    group by t.product_id
  )
select
  p.id as product_id,
  p.name as name,
  p.category as category,
  (coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0))::int as current_stock,
  (coalesce(mv.purchased, 0) + coalesce(mv.transferred_to_fridge, 0))::int as refilled,
  greatest(coalesce(mv.consumed_mv, 0), coalesce(tx.consumed_tx, 0))::int as consumed,
  coalesce(p.warehouse_stock, 0)::int as warehouse_stock,
  coalesce(p.fridge_stock, 0)::int as fridge_stock,
  coalesce(mv.transferred_to_fridge, 0)::int as transferred_to_fridge,
  coalesce(mv.purchased, 0)::int as purchased,
  coalesce(mv.shrinkage, 0)::int as shrinkage
from public.products p
left join mv on mv.product_id = p.id
left join tx on tx.product_id = p.id
where p.inventoried = true
order by p.category, p.name;
$function$;

-- ------------------------------------------------------------
-- 11) Booking/report functions resilient to deleted members/products
-- ------------------------------------------------------------
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
      nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
      t.member_name_snapshot,
      '[Geloeschtes Mitglied]'
    )
    ||
    case when coalesce(m.is_guest, ma.is_guest, false) then ' (Gast)' else '' end
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
      'product_name', coalesce(p.name, pa.name, t.product_name_snapshot)
    )
    order by t.created_at desc
  ) as items
from public.transactions t
left join public.members m on m.id = t.member_id
left join public.members_archive ma on ma.id = t.member_id
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
where t.created_at >= p_start
  and t.created_at < p_end
group by local_day, t.member_id, member_name, member_active
order by local_day desc, member_name;
$function$;

create or replace function public.get_member_bookings_grouped(
  p_member_id uuid,
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_exclude_settled boolean default false
)
returns table(local_day date, total integer, items json)
language sql
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'product_id', t.product_id,
      'product_name', coalesce(p.name, pa.name, t.product_name_snapshot),
      'settled_at', t.settled_at
    )
    order by t.created_at desc
  ) as items
from public.transactions t
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
where t.member_id = p_member_id
  and t.created_at >= p_start
  and t.created_at < p_end
  and (not p_exclude_settled or t.settled_at is null)
group by 1
order by 1 desc;
$function$;

create or replace function public.get_today_transactions_berlin(p_member uuid)
returns table(
  id uuid,
  amount integer,
  note text,
  created_at timestamp with time zone,
  product_id uuid,
  product_name text
)
language sql
security definer
as $function$
select
  t.id,
  t.amount,
  t.note,
  t.created_at,
  t.product_id,
  coalesce(p.name, pa.name, t.product_name_snapshot) as product_name
from public.transactions t
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
where t.member_id = p_member
  and (t.created_at at time zone 'Europe/Berlin')::date = (now() at time zone 'Europe/Berlin')::date
  and t.settled_at is null
order by t.created_at desc;
$function$;

create or replace function public.get_transactions_by_range_berlin(
  p_member uuid,
  p_start date,
  p_end date
)
returns table(
  id uuid,
  amount integer,
  note text,
  created_at timestamp with time zone,
  product_id uuid,
  product_name text
)
language sql
security definer
as $function$
select
  t.id,
  t.amount,
  t.note,
  t.created_at,
  t.product_id,
  coalesce(p.name, pa.name, t.product_name_snapshot) as product_name
from public.transactions t
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
where t.member_id = p_member
  and (t.created_at at time zone 'Europe/Berlin')::date between p_start and p_end
order by t.created_at desc;
$function$;

-- ------------------------------------------------------------
-- 12) Admin guard + safe delete + admin RPC wrappers
-- ------------------------------------------------------------
create or replace function public.assert_admin()
returns void
language plpgsql
security definer
as $function$
begin
  if auth.uid() is null then
    -- Edge Functions using service role key have no user uid in SQL context.
    if coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role' then
      return;
    end if;
    raise exception 'Unauthorized';
  end if;

  if not exists (
    select 1
    from public.admins a
    where a.user_id = auth.uid()
  ) then
    raise exception 'Forbidden';
  end if;
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
    v_member.id, v_member.firstname, v_member.lastname, v_member.is_guest, v_member.active, v_member.balance, v_member.settled, v_member.created_at, v_member.last_settled_at, now(), auth.uid()
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
    v_product.id, v_product.name, v_product.price, v_product.guest_price, v_product.category, v_product.active, v_product.inventoried, v_product.created_at, now(), auth.uid()
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

create or replace function public.admin_list_members()
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone
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
    m.created_at
  from public.members m
  where m.is_guest = false
  order by m.lastname asc, m.firstname asc;
end;
$function$;

create or replace function public.admin_create_member(
  p_firstname text,
  p_lastname text
)
returns public.members
language plpgsql
security definer
as $function$
declare
  v_row public.members;
begin
  perform public.assert_admin();

  insert into public.members (firstname, lastname, active, balance)
  values (p_firstname, p_lastname, true, 0)
  returning * into v_row;

  return v_row;
end;
$function$;

create or replace function public.admin_update_member(
  p_id uuid,
  p_firstname text default null,
  p_lastname text default null,
  p_balance integer default null,
  p_active boolean default null
)
returns public.members
language plpgsql
security definer
as $function$
declare
  v_row public.members;
begin
  perform public.assert_admin();

  update public.members m
  set
    firstname = coalesce(p_firstname, m.firstname),
    lastname = coalesce(p_lastname, m.lastname),
    balance = coalesce(p_balance, m.balance),
    active = coalesce(p_active, m.active)
  where m.id = p_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Mitglied nicht gefunden';
  end if;

  return v_row;
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
  perform public.delete_member_safely(p_member_id, p_force);
end;
$function$;

create or replace function public.admin_list_products()
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  created_at timestamp with time zone,
  stored smallint,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    p.id,
    p.name,
    p.price,
    p.guest_price,
    p.category,
    p.active,
    p.inventoried,
    p.created_at,
    p.stored,
    p.warehouse_stock,
    p.fridge_stock,
    p.last_restocked_at
  from public.products p
  order by p.active desc, p.name asc;
end;
$function$;

create or replace function public.admin_create_product(
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean
)
returns public.products
language plpgsql
security definer
as $function$
declare
  v_row public.products;
begin
  perform public.assert_admin();

  insert into public.products (
    name,
    price,
    guest_price,
    category,
    active,
    inventoried
  ) values (
    coalesce(p_name, 'Neu'),
    coalesce(p_price, 0),
    coalesce(p_guest_price, 0),
    coalesce(p_category, 'Sonstiges'),
    coalesce(p_active, true),
    coalesce(p_inventoried, true)
  )
  returning * into v_row;

  return v_row;
end;
$function$;

create or replace function public.admin_update_product(
  p_id uuid,
  p_name text default null,
  p_price integer default null,
  p_guest_price integer default null,
  p_category text default null,
  p_active boolean default null,
  p_inventoried boolean default null
)
returns public.products
language plpgsql
security definer
as $function$
declare
  v_row public.products;
begin
  perform public.assert_admin();

  update public.products p
  set
    name = coalesce(p_name, p.name),
    price = coalesce(p_price, p.price),
    guest_price = coalesce(p_guest_price, p.guest_price),
    category = coalesce(p_category, p.category),
    active = coalesce(p_active, p.active),
    inventoried = coalesce(p_inventoried, p.inventoried)
  where p.id = p_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Produkt nicht gefunden';
  end if;

  return v_row;
end;
$function$;

create or replace function public.admin_delete_product(
  p_product_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.delete_product_safely(p_product_id, p_force);
end;
$function$;

create or replace function public.admin_get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  current_stock integer,
  refilled integer,
  consumed integer,
  warehouse_stock integer,
  fridge_stock integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_stock_report_period(p_start, p_end);
end;
$function$;

create or replace function public.admin_get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  local_day date,
  member_id uuid,
  member_name text,
  member_active boolean,
  total integer,
  items jsonb
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_all_bookings_grouped(p_start, p_end);
end;
$function$;

create or replace function public.admin_perform_monthly_settlement()
returns void
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  perform public.perform_monthly_settlement(auth.uid());
end;
$function$;

-- Restrict admin helper/functions to authenticated users.
revoke all on function public.assert_admin() from public;
grant execute on function public.assert_admin() to authenticated;

revoke all on function public.delete_member_safely(uuid, boolean) from public;
grant execute on function public.delete_member_safely(uuid, boolean) to authenticated;

revoke all on function public.delete_product_safely(uuid, boolean) from public;
grant execute on function public.delete_product_safely(uuid, boolean) to authenticated;

revoke all on function public.admin_list_members() from public;
grant execute on function public.admin_list_members() to authenticated;

revoke all on function public.admin_create_member(text, text) from public;
grant execute on function public.admin_create_member(text, text) to authenticated;

revoke all on function public.admin_update_member(uuid, text, text, integer, boolean) from public;
grant execute on function public.admin_update_member(uuid, text, text, integer, boolean) to authenticated;

revoke all on function public.admin_delete_member(uuid, boolean) from public;
grant execute on function public.admin_delete_member(uuid, boolean) to authenticated;

revoke all on function public.admin_list_products() from public;
grant execute on function public.admin_list_products() to authenticated;

revoke all on function public.admin_create_product(text, integer, integer, text, boolean, boolean) from public;
grant execute on function public.admin_create_product(text, integer, integer, text, boolean, boolean) to authenticated;

revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean) from public;
grant execute on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean) to authenticated;

revoke all on function public.admin_delete_product(uuid, boolean) from public;
grant execute on function public.admin_delete_product(uuid, boolean) to authenticated;

revoke all on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) to authenticated;

revoke all on function public.admin_get_all_bookings_grouped(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_all_bookings_grouped(timestamp with time zone, timestamp with time zone) to authenticated;

revoke all on function public.admin_perform_monthly_settlement() from public;
grant execute on function public.admin_perform_monthly_settlement() to authenticated;
