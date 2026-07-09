alter table public.product_purchase_lots
  add column if not exists canceled_quantity integer not null default 0;

alter table public.product_purchase_lots
  drop constraint if exists product_purchase_lots_canceled_quantity_chk;

alter table public.product_purchase_lots
  add constraint product_purchase_lots_canceled_quantity_chk
  check (canceled_quantity >= 0 and canceled_quantity <= purchased_quantity);

drop function if exists public.add_storage(uuid, integer, integer);

create or replace function public.add_storage(
  product_id uuid,
  amount integer,
  purchase_price_cents integer default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_product_id uuid;
  v_amount integer;
  v_purchase_price_cents integer;
  v_wh uuid;
  v_product public.products%rowtype;
  v_price integer;
  v_movement_id uuid;
  v_purchase_lot_id uuid;
  v_settled_fallback_quantity integer;
begin
  v_product_id := product_id;
  v_amount := amount;
  v_purchase_price_cents := purchase_price_cents;

  if coalesce(v_amount, 0) <= 0 then
    raise exception 'Einlagerung muss groesser als 0 sein';
  end if;

  select *
  into v_product
  from public.products p
  where p.id = v_product_id
  for update;

  if not found then
    raise exception 'Produkt nicht gefunden';
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  if v_wh is null then
    raise exception 'Stock location warehouse not configured';
  end if;

  v_price := greatest(0, coalesce(v_purchase_price_cents, v_product.last_purchase_price_cents, 0));

  insert into public.inventory_movements (
    product_id,
    quantity,
    from_location_id,
    to_location_id,
    reason,
    note,
    purchase_price_snapshot_cents,
    meta
  ) values (
    v_product_id,
    v_amount,
    null,
    v_wh,
    'purchase',
    'Einlagerung',
    v_price,
    jsonb_build_object('source', 'add_storage')
  )
  returning id into v_movement_id;

  v_purchase_lot_id := public.create_purchase_lot(v_product_id, v_movement_id, v_amount, v_price, 'purchase', 'Einlagerung');

  v_settled_fallback_quantity := public.settle_fallback_allocations_with_purchase_lot(
    v_product_id,
    v_purchase_lot_id,
    v_amount,
    v_price
  );

  update public.inventory_movements im
  set
    meta = coalesce(im.meta, '{}'::jsonb) || jsonb_build_object('settled_fallback_quantity', v_settled_fallback_quantity),
    note = case
      when v_settled_fallback_quantity > 0 then concat_ws(
        '; ',
        nullif(im.note, ''),
        v_settled_fallback_quantity::text || ' Stück mit bereits gebuchten Verkäufen verrechnet'
      )
      else im.note
    end
  where im.id = v_movement_id;

  update public.product_purchase_lots l
  set note = concat_ws(
    '; ',
    nullif(l.note, ''),
    v_settled_fallback_quantity::text || ' Stück mit bereits gebuchten Verkäufen verrechnet'
  )
  where l.id = v_purchase_lot_id
    and v_settled_fallback_quantity > 0;

  update public.products p
  set
    last_restocked_at = now(),
    last_purchase_price_cents = v_price
  where p.id = v_product_id;

  perform public.refresh_product_inventory_value_from_lots(v_product_id);
end;
$function$;

create or replace function public.admin_list_purchase_lots(
  p_product_id uuid default null::uuid,
  p_lot_state text default 'active'
)
returns table(
  id uuid,
  product_id uuid,
  product_name text,
  inventory_movement_id uuid,
  source_reason text,
  purchased_quantity integer,
  remaining_quantity integer,
  consumed_quantity integer,
  unit_cost_cents integer,
  created_at timestamp with time zone,
  corrected_from_price_cents integer,
  corrected_at timestamp with time zone,
  note text,
  closed_at timestamp with time zone,
  cost_pending boolean,
  pending_allocation_count integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_state text;
begin
  perform public.assert_admin();

  v_state := lower(coalesce(nullif(trim(p_lot_state), ''), 'active'));
  if v_state not in ('active', 'closed', 'all') then
    v_state := 'active';
  end if;

  return query
  select
    l.id,
    l.product_id,
    p.name as product_name,
    l.inventory_movement_id,
    l.source_reason,
    l.purchased_quantity,
    l.remaining_quantity,
    greatest(0, l.purchased_quantity - l.remaining_quantity - coalesce(l.canceled_quantity, 0))::int as consumed_quantity,
    l.unit_cost_cents,
    l.created_at,
    l.corrected_from_price_cents,
    l.corrected_at,
    l.note,
    l.closed_at,
    l.cost_pending,
    coalesce(pa.pending_allocation_count, 0)::integer
  from public.product_purchase_lots l
  join public.products p on p.id = l.product_id
  left join lateral (
    select count(*)::integer as pending_allocation_count
    from public.product_lot_allocations a
    where a.purchase_lot_id = l.id
      and a.cost_pending = true
  ) pa on true
  where (p_product_id is null or l.product_id = p_product_id)
    and (
      v_state = 'all'
      or (v_state = 'active' and l.closed_at is null and (l.remaining_quantity > 0 or l.source_reason = 'sale_fallback'))
      or (v_state = 'closed' and (l.closed_at is not null or (l.remaining_quantity = 0 and l.source_reason <> 'sale_fallback')))
    )
  order by coalesce(l.closed_at, l.created_at) desc, l.created_at desc, l.id desc;
end;
$function$;

create or replace function public.admin_cancel_purchase_lot_remaining(
  p_lot_id uuid,
  p_note text default null
)
returns table(
  id uuid,
  product_id uuid,
  product_name text,
  inventory_movement_id uuid,
  source_reason text,
  purchased_quantity integer,
  remaining_quantity integer,
  consumed_quantity integer,
  unit_cost_cents integer,
  created_at timestamp with time zone,
  corrected_from_price_cents integer,
  corrected_at timestamp with time zone,
  note text,
  closed_at timestamp with time zone,
  cost_pending boolean,
  pending_allocation_count integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_lot public.product_purchase_lots%rowtype;
  v_wh uuid;
  v_cancel_quantity integer;
  v_movement_id uuid;
begin
  perform public.assert_admin();

  select *
  into v_lot
  from public.product_purchase_lots l
  where l.id = p_lot_id
  for update;

  if not found then
    raise exception 'Einlagerung nicht gefunden';
  end if;

  if v_lot.source_reason <> 'purchase' then
    raise exception 'Nur Einlagerungen koennen storniert werden';
  end if;

  v_cancel_quantity := coalesce(v_lot.remaining_quantity, 0);
  if v_cancel_quantity <= 0 then
    raise exception 'Diese Einlagerung hat keinen offenen Restbestand';
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  if v_wh is null then
    raise exception 'Stock location warehouse not configured';
  end if;

  insert into public.inventory_movements (
    product_id,
    quantity,
    from_location_id,
    to_location_id,
    reason,
    note,
    purchase_price_snapshot_cents,
    meta
  ) values (
    v_lot.product_id,
    v_cancel_quantity,
    v_wh,
    null,
    'count_adjustment',
    coalesce(nullif(trim(p_note), ''), 'Einlagerung storniert'),
    v_lot.unit_cost_cents,
    jsonb_build_object(
      'source', 'purchase_lot_remaining_cancel',
      'purchase_lot_id', v_lot.id,
      'original_inventory_movement_id', v_lot.inventory_movement_id,
      'cancelled_quantity', v_cancel_quantity
    )
  )
  returning id into v_movement_id;

  update public.product_purchase_lots l
  set
    remaining_quantity = 0,
    canceled_quantity = least(l.purchased_quantity, coalesce(l.canceled_quantity, 0) + v_cancel_quantity),
    closed_at = coalesce(l.closed_at, now()),
    note = concat_ws(
      '; ',
      nullif(l.note, ''),
      v_cancel_quantity::text || ' Stück offene Einlagerung storniert'
    )
  where l.id = v_lot.id;

  update public.inventory_movements im
  set meta = coalesce(im.meta, '{}'::jsonb) || jsonb_build_object(
    'cancelled_remaining_quantity', v_cancel_quantity,
    'cancelled_by_movement_id', v_movement_id
  )
  where im.id = v_lot.inventory_movement_id;

  perform public.refresh_product_inventory_value_from_lots(v_lot.product_id);

  return query
  select *
  from public.admin_list_purchase_lots(v_lot.product_id, 'all') listed
  where listed.id = v_lot.id;
end;
$function$;

create or replace function public.api_admin_cancel_purchase_lot_remaining(
  p_token text,
  p_lot_id uuid,
  p_note text default null
)
returns table(
  id uuid,
  product_id uuid,
  product_name text,
  inventory_movement_id uuid,
  source_reason text,
  purchased_quantity integer,
  remaining_quantity integer,
  consumed_quantity integer,
  unit_cost_cents integer,
  created_at timestamp with time zone,
  corrected_from_price_cents integer,
  corrected_at timestamp with time zone,
  note text,
  closed_at timestamp with time zone,
  cost_pending boolean,
  pending_allocation_count integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_cancel_purchase_lot_remaining(p_lot_id, p_note);
end;
$function$;

revoke all on function public.add_storage(uuid, integer, integer) from public;
revoke all on function public.admin_cancel_purchase_lot_remaining(uuid, text) from public;
revoke all on function public.api_admin_cancel_purchase_lot_remaining(text, uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_cancel_purchase_lot_remaining(text, uuid, text) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';
