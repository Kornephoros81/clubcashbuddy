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

  insert into public.inventory_movements as im (
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
  returning im.id into v_movement_id;

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
  select
    listed.id,
    listed.product_id,
    listed.product_name,
    listed.inventory_movement_id,
    listed.source_reason,
    listed.purchased_quantity,
    listed.remaining_quantity,
    listed.consumed_quantity,
    listed.unit_cost_cents,
    listed.created_at,
    listed.corrected_from_price_cents,
    listed.corrected_at,
    listed.note,
    listed.closed_at,
    listed.cost_pending,
    listed.pending_allocation_count
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
  select
    cancelled.id,
    cancelled.product_id,
    cancelled.product_name,
    cancelled.inventory_movement_id,
    cancelled.source_reason,
    cancelled.purchased_quantity,
    cancelled.remaining_quantity,
    cancelled.consumed_quantity,
    cancelled.unit_cost_cents,
    cancelled.created_at,
    cancelled.corrected_from_price_cents,
    cancelled.corrected_at,
    cancelled.note,
    cancelled.closed_at,
    cancelled.cost_pending,
    cancelled.pending_allocation_count
  from public.admin_cancel_purchase_lot_remaining(p_lot_id, p_note) cancelled;
end;
$function$;

revoke all on function public.admin_cancel_purchase_lot_remaining(uuid, text) from public;
revoke all on function public.api_admin_cancel_purchase_lot_remaining(text, uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_cancel_purchase_lot_remaining(text, uuid, text) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';
