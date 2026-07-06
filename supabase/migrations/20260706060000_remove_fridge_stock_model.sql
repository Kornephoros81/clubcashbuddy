-- Remove active fridge/Kuehlschrank data paths while keeping legacy columns for compatibility.

-- Old fridge refill RPCs are no longer part of the product flow.
drop function if exists public.api_admin_get_fridge_refills_period(text, timestamp with time zone, timestamp with time zone);
drop function if exists public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone);
drop function if exists public.get_fridge_refills_period(timestamp with time zone, timestamp with time zone);

do $migration$
begin
  if to_regclass('public.stock_adjustments') is not null then
    execute 'drop trigger if exists tg_stock_adjustments_to_inventory_movements on public.stock_adjustments';
  end if;
end;
$migration$;

drop function if exists public.trg_stock_adjustments_to_inventory_movements();

do $migration$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'products'
      and column_name = 'fridge_stock'
  ) then
    update public.products
    set fridge_stock = 0
    where coalesce(fridge_stock, 0) <> 0;
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'products'
      and column_name = 'min_fridge'
  ) then
    update public.products
    set min_fridge = 0
    where coalesce(min_fridge, 0) <> 0;
  end if;
end;
$migration$;

create or replace function public.get_product_stock(p_product_id uuid)
returns table(
  warehouse_qty integer,
  fridge_qty integer,
  total_qty integer
)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $function$
  select
    coalesce(sum(l.remaining_quantity), 0)::integer as warehouse_qty,
    0::integer as fridge_qty,
    coalesce(sum(l.remaining_quantity), 0)::integer as total_qty
  from public.product_purchase_lots l
  where l.product_id = p_product_id
    and l.source_reason <> 'sale_fallback'
    and l.remaining_quantity > 0;
$function$;

create or replace function public.refresh_product_stock(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_stock record;
begin
  select *
  into v_stock
  from public.get_product_stock(p_product_id);

  update public.products p
  set
    warehouse_stock = coalesce(v_stock.warehouse_qty, 0),
    fridge_stock = 0
  where p.id = p_product_id;
end;
$function$;

create or replace function public.refresh_product_inventory_value_from_lots(
  p_product_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_stock_qty integer;
  v_inventory_value integer;
  v_last_purchase integer;
begin
  select
    coalesce(sum(l.remaining_quantity), 0)::integer,
    coalesce(sum(l.remaining_quantity * l.unit_cost_cents), 0)::integer
  into v_stock_qty, v_inventory_value
  from public.product_purchase_lots l
  where l.product_id = p_product_id
    and l.source_reason <> 'sale_fallback'
    and l.remaining_quantity > 0;

  select l.unit_cost_cents
  into v_last_purchase
  from public.product_purchase_lots l
  where l.product_id = p_product_id
    and l.source_reason = 'purchase'
  order by l.created_at desc, l.id desc
  limit 1;

  update public.products p
  set
    warehouse_stock = greatest(0, coalesce(v_stock_qty, 0)),
    fridge_stock = 0,
    inventory_value_cents = greatest(0, coalesce(v_inventory_value, 0)),
    last_purchase_price_cents = case
      when v_last_purchase is not null then greatest(0, v_last_purchase)
      else p.last_purchase_price_cents
    end
  where p.id = p_product_id;
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
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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
    case when p.inventoried then coalesce(s.warehouse_qty, 0) else coalesce(p.warehouse_stock, 0) end::integer as warehouse_stock,
    0::integer as fridge_stock,
    p.last_restocked_at,
    p.last_purchase_price_cents,
    case when p.inventoried then coalesce(v.inventory_value_cents, 0) else coalesce(p.inventory_value_cents, 0) end::integer as inventory_value_cents
  from public.products p
  left join lateral public.get_product_stock(p.id) s on true
  left join lateral (
    select coalesce(sum(l.remaining_quantity * l.unit_cost_cents), 0)::integer as inventory_value_cents
    from public.product_purchase_lots l
    where l.product_id = p.id
      and l.source_reason <> 'sale_fallback'
      and l.remaining_quantity > 0
  ) v on true
  order by p.active desc, p.name asc;
end;
$function$;

create or replace function public.api_admin_list_products(p_token text)
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_products();
end;
$function$;

create or replace function public.get_inventory_snapshot()
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  soll_warehouse_stock integer,
  soll_fridge_stock integer,
  soll_total_stock integer
)
language sql
security definer
set search_path = public, extensions, pg_temp
as $function$
  select
    p.id as product_id,
    p.name as name,
    p.category as category,
    p.active as active,
    coalesce(s.warehouse_qty, 0)::integer as soll_warehouse_stock,
    0::integer as soll_fridge_stock,
    coalesce(s.total_qty, 0)::integer as soll_total_stock
  from public.products p
  left join lateral public.get_product_stock(p.id) s on true
  where p.inventoried = true
  order by p.active desc, p.category, p.name;
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
set search_path = public, extensions, pg_temp
as $function$
declare
  v_wh uuid;
  v_item record;
  v_product record;
  v_stock record;
  v_target_total integer;
  v_current_total integer;
  v_delta_total integer;
  v_avg_cost integer;
  v_movement_id uuid;
  v_total_cost integer;
begin
  perform public.assert_admin();

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  if v_wh is null then
    raise exception 'Stock location warehouse is not configured';
  end if;

  for v_item in
    select *
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      ist_total_stock integer,
      ist_warehouse_stock integer,
      ist_fridge_stock integer
    )
  loop
    if v_item.product_id is null then
      raise exception 'product_id is required';
    end if;

    v_target_total := coalesce(v_item.ist_total_stock, v_item.ist_warehouse_stock);
    if v_target_total is null then
      raise exception 'ist_total_stock is required';
    end if;
    if v_target_total < 0 then
      raise exception 'Ist stock cannot be negative';
    end if;

    select
      p.id,
      p.name,
      coalesce(p.last_purchase_price_cents, 0) as last_purchase_price_cents
    into v_product
    from public.products p
    where p.id = v_item.product_id
      and p.inventoried = true
    for update;

    if not found then
      raise exception 'Inventoried product not found: %', v_item.product_id;
    end if;

    select warehouse_qty, fridge_qty, total_qty
    into v_stock
    from public.get_product_stock(v_item.product_id);

    v_current_total := coalesce(v_stock.total_qty, coalesce(v_stock.warehouse_qty, 0));
    v_delta_total := v_target_total - v_current_total;

    select
      case
        when coalesce(sum(l.remaining_quantity), 0) > 0
          then round(sum(l.remaining_quantity * l.unit_cost_cents)::numeric / sum(l.remaining_quantity))::integer
        else greatest(0, coalesce(v_product.last_purchase_price_cents, 0))
      end
    into v_avg_cost
    from public.product_purchase_lots l
    where l.product_id = v_item.product_id
      and l.source_reason <> 'sale_fallback'
      and l.remaining_quantity > 0;

    if v_delta_total > 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        purchase_price_snapshot_cents,
        meta
      ) values (
        v_item.product_id,
        v_delta_total,
        null,
        v_wh,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich'),
        public.app_current_user_id(),
        v_avg_cost,
        jsonb_build_object(
          'source', 'inventory_count',
          'mode', 'total',
          'expected_total', v_current_total,
          'counted_total', v_target_total,
          'delta_total', v_delta_total
        )
      )
      returning id into v_movement_id;

      perform public.create_purchase_lot(v_item.product_id, v_movement_id, v_delta_total, v_avg_cost, 'count_adjustment', coalesce(p_note, 'Inventurabgleich'));
    elsif v_delta_total < 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        purchase_price_snapshot_cents,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_total),
        v_wh,
        null,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich'),
        public.app_current_user_id(),
        0,
        jsonb_build_object(
          'source', 'inventory_count',
          'mode', 'total',
          'expected_total', v_current_total,
          'counted_total', v_target_total,
          'delta_total', v_delta_total
        )
      )
      returning id into v_movement_id;

      v_total_cost := public.consume_purchase_lots(
        v_item.product_id,
        abs(v_delta_total),
        'count_adjustment',
        null,
        v_movement_id,
        v_avg_cost
      );

      update public.inventory_movements im
      set purchase_price_snapshot_cents = case when abs(v_delta_total) > 0 then round(v_total_cost::numeric / abs(v_delta_total))::integer else 0 end
      where im.id = v_movement_id;
    end if;

    perform public.refresh_product_inventory_value_from_lots(v_item.product_id);

    product_id := v_item.product_id;
    name := v_product.name;
    soll_warehouse_stock := coalesce(v_stock.warehouse_qty, 0);
    ist_warehouse_stock := v_target_total;
    delta_warehouse := v_delta_total;
    soll_fridge_stock := 0;
    ist_fridge_stock := 0;
    delta_fridge := 0;
    return next;
  end loop;

  return;
end;
$function$;

create or replace function public.get_inventory_adjustments_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  value_delta_cents integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language sql
security definer
set search_path = public, extensions, pg_temp
as $function$
  with movement_adjustments as (
    select
      im.created_at,
      (im.created_at at time zone 'Europe/Berlin')::date as local_day,
      im.product_id,
      coalesce(p.name, '[Geloeschtes Produkt]') as product_name,
      coalesce(p.category, 'Unbekannt') as product_category,
      coalesce(p.active, false) as active,
      'warehouse'::text as location,
      (
        case when im.to_location_id is not null then im.quantity else 0 end
        - case when im.from_location_id is not null then im.quantity else 0 end
      )::integer as delta,
      (
        (
          case when im.to_location_id is not null then im.quantity else 0 end
          - case when im.from_location_id is not null then im.quantity else 0 end
        ) * greatest(
          0,
          coalesce(
            nullif(im.purchase_price_snapshot_cents, 0),
            nullif(p.last_purchase_price_cents, 0),
            nullif(latest_lot.unit_cost_cents, 0),
            0
          )
        )
      )::integer as value_delta_cents,
      case
        when (
          case when im.to_location_id is not null then im.quantity else 0 end
          - case when im.from_location_id is not null then im.quantity else 0 end
        ) < 0 then 'fehlbestand'
        when (
          case when im.to_location_id is not null then im.quantity else 0 end
          - case when im.from_location_id is not null then im.quantity else 0 end
        ) > 0 then 'ueberbestand'
        else 'neutral'
      end as adjustment_kind,
      im.reason,
      im.note,
      coalesce(im.meta->>'source', 'unknown') as source
    from public.inventory_movements im
    left join public.products p on p.id = im.product_id
    left join lateral (
      select l.unit_cost_cents
      from public.product_purchase_lots l
      where l.product_id = im.product_id
        and l.source_reason <> 'sale_fallback'
      order by l.created_at desc, l.id desc
      limit 1
    ) latest_lot on true
    where im.created_at >= p_start
      and im.created_at < p_end
      and im.reason in ('count_adjustment', 'shrinkage', 'waste')
  ), open_fallback_sales as (
    select
      a.created_at,
      (a.created_at at time zone 'Europe/Berlin')::date as local_day,
      a.product_id,
      coalesce(p.name, '[Geloeschtes Produkt]') as product_name,
      coalesce(p.category, 'Unbekannt') as product_category,
      coalesce(p.active, false) as active,
      'warehouse'::text as location,
      (-a.quantity)::integer as delta,
      (-a.quantity * greatest(
        0,
        coalesce(
          nullif(a.unit_cost_cents, 0),
          nullif(l.unit_cost_cents, 0),
          nullif(p.last_purchase_price_cents, 0),
          0
        )
      ))::integer as value_delta_cents,
      'fehlbestand'::text as adjustment_kind,
      'sale_fallback'::text as reason,
      coalesce(l.note, 'Verkauf ohne gedecktes Lot') as note,
      'fallback_lot'::text as source
    from public.product_lot_allocations a
    join public.product_purchase_lots l on l.id = a.purchase_lot_id
    left join public.products p on p.id = a.product_id
    where a.created_at >= p_start
      and a.created_at < p_end
      and a.reason = 'sale'
      and a.reversed_at is null
      and l.source_reason = 'sale_fallback'
  )
  select * from movement_adjustments
  union all
  select * from open_fallback_sales
  order by created_at desc;
$function$;

create or replace function public.admin_get_inventory_adjustments_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  value_delta_cents integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_inventory_adjustments_period(p_start, p_end);
end;
$function$;

create or replace function public.api_admin_get_inventory_adjustments_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  value_delta_cents integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_inventory_adjustments_period(p_start, p_end);
end;
$function$;

do $migration$
declare
  v_product record;
begin
  for v_product in select p.id from public.products p loop
    perform public.refresh_product_inventory_value_from_lots(v_product.id);
  end loop;
end;
$migration$;

notify pgrst, 'reload schema';
