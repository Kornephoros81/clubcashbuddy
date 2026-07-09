create or replace function public.settle_fallback_allocations_with_purchase_lot(
  v_product_id uuid,
  p_purchase_lot_id uuid,
  p_max_quantity integer,
  p_unit_cost_cents integer
)
returns integer
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_remaining integer;
  v_settled integer := 0;
  v_take integer;
  v_alloc record;
  v_new_alloc_id uuid;
begin
  v_remaining := greatest(0, coalesce(p_max_quantity, 0));

  if v_remaining = 0 then
    return 0;
  end if;

  for v_alloc in
    select
      a.*,
      l.id as fallback_lot_id
    from public.product_lot_allocations a
    join public.product_purchase_lots l on l.id = a.purchase_lot_id
    where l.product_id = v_product_id
      and l.source_reason = 'sale_fallback'
      and a.reason = 'sale'
      and a.reversed_at is null
      and a.quantity > 0
    order by a.created_at asc, a.id asc
    for update of a, l
  loop
    exit when v_remaining <= 0;

    v_take := least(v_remaining, v_alloc.quantity);

    if v_take = v_alloc.quantity then
      update public.product_lot_allocations a
      set
        purchase_lot_id = p_purchase_lot_id,
        unit_cost_cents = greatest(0, coalesce(p_unit_cost_cents, 0)),
        cost_pending = greatest(0, coalesce(p_unit_cost_cents, 0)) = 0
      where a.id = v_alloc.id;
    else
      update public.product_lot_allocations a
      set quantity = a.quantity - v_take
      where a.id = v_alloc.id;

      insert into public.product_lot_allocations (
        purchase_lot_id,
        product_id,
        inventory_movement_id,
        source_transaction_id,
        reason,
        quantity,
        unit_cost_cents,
        created_at,
        cost_pending,
        reversed_at,
        reversal_inventory_movement_id,
        reversal_reason
      ) values (
        p_purchase_lot_id,
        v_alloc.product_id,
        v_alloc.inventory_movement_id,
        v_alloc.source_transaction_id,
        v_alloc.reason,
        v_take,
        greatest(0, coalesce(p_unit_cost_cents, 0)),
        v_alloc.created_at,
        greatest(0, coalesce(p_unit_cost_cents, 0)) = 0,
        v_alloc.reversed_at,
        v_alloc.reversal_inventory_movement_id,
        v_alloc.reversal_reason
      )
      returning id into v_new_alloc_id;
    end if;

    v_settled := v_settled + v_take;
    v_remaining := v_remaining - v_take;
  end loop;

  if v_settled > 0 then
    update public.product_purchase_lots l
    set remaining_quantity = greatest(0, l.remaining_quantity - v_settled)
    where l.id = p_purchase_lot_id;

    update public.product_purchase_lots l
    set
      purchased_quantity = fallback_qty.qty,
      cost_pending = fallback_qty.has_pending,
      note = case
        when fallback_qty.has_pending then 'Fallback-Lot ohne gepflegten EK'
        else l.note
      end,
      closed_at = null
    from (
      select
        old_lot.id,
        sum(a.quantity)::integer as qty,
        bool_or(a.cost_pending or a.unit_cost_cents = 0) as has_pending
      from public.product_purchase_lots old_lot
      join public.product_lot_allocations a on a.purchase_lot_id = old_lot.id
      where old_lot.product_id = v_product_id
        and old_lot.source_reason = 'sale_fallback'
      group by old_lot.id
    ) fallback_qty
    where l.id = fallback_qty.id;

    delete from public.product_purchase_lots l
    where l.product_id = v_product_id
      and l.source_reason = 'sale_fallback'
      and not exists (
        select 1
        from public.product_lot_allocations a
        where a.purchase_lot_id = l.id
      );

    update public.transactions t
    set product_cost_snapshot_cents = alloc.total_cost
    from (
      select
        a.source_transaction_id as transaction_id,
        sum(a.quantity * a.unit_cost_cents)::integer as total_cost
      from public.product_lot_allocations a
      where a.purchase_lot_id = p_purchase_lot_id
        and a.source_transaction_id is not null
      group by a.source_transaction_id
    ) alloc
    where t.id = alloc.transaction_id;

    update public.inventory_movements im
    set purchase_price_snapshot_cents = alloc.unit_cost
    from (
      select
        a.inventory_movement_id,
        round(sum(a.quantity * a.unit_cost_cents)::numeric / nullif(sum(a.quantity), 0))::integer as unit_cost
      from public.product_lot_allocations a
      where a.purchase_lot_id = p_purchase_lot_id
        and a.inventory_movement_id is not null
      group by a.inventory_movement_id
    ) alloc
    where im.id = alloc.inventory_movement_id;
  end if;

  return v_settled;
end;
$function$;

drop function if exists public.add_storage(uuid, integer, integer);

create or replace function public.add_storage(
  product_id uuid,
  amount integer,
  purchase_price_cents integer default null)
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
  v_abs_amount integer;
  v_movement_id uuid;
  v_purchase_lot_id uuid;
  v_total_cost integer;
  v_unit_cost integer;
  v_settled_fallback_quantity integer;
begin
  v_product_id := product_id;
  v_amount := amount;
  v_purchase_price_cents := purchase_price_cents;

  if coalesce(v_amount, 0) = 0 then
    return;
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

  v_abs_amount := abs(v_amount);

  if v_amount > 0 then
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
  else
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
      v_abs_amount,
      v_wh,
      null,
      'count_adjustment',
      'Bestandskorrektur Lager',
      0,
      jsonb_build_object('source', 'add_storage')
    )
    returning id into v_movement_id;

    v_total_cost := public.consume_purchase_lots(
      v_product_id,
      v_abs_amount,
      'count_adjustment',
      null,
      v_movement_id,
      v_product.last_purchase_price_cents
    );
    v_unit_cost := case when v_abs_amount > 0 then round(v_total_cost::numeric / v_abs_amount)::integer else 0 end;

    update public.inventory_movements im
    set purchase_price_snapshot_cents = v_unit_cost
    where im.id = v_movement_id;
  end if;

  perform public.refresh_product_inventory_value_from_lots(v_product_id);
end;
$function$;

notify pgrst, 'reload schema';
