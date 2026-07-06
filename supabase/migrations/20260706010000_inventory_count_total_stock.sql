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
  v_target_total integer;
  v_current_total integer;
  v_delta_total integer;
  v_avg_cost integer;
  v_movement_id uuid;
  v_total_cost integer;
  v_remaining integer;
  v_move_qty integer;
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
      ist_total_stock integer,
      ist_warehouse_stock integer,
      ist_fridge_stock integer
    )
  loop
    if v_item.product_id is null then
      raise exception 'product_id is required';
    end if;

    if v_item.ist_total_stock is not null then
      v_target_total := v_item.ist_total_stock;
    elsif v_item.ist_warehouse_stock is not null and v_item.ist_fridge_stock is not null then
      v_target_total := v_item.ist_warehouse_stock + v_item.ist_fridge_stock;
    else
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

    v_current_total := coalesce(v_stock.total_qty, coalesce(v_stock.warehouse_qty, 0) + coalesce(v_stock.fridge_qty, 0));
    v_delta_total := v_target_total - v_current_total;
    v_delta_wh := 0;
    v_delta_fr := 0;

    select
      case
        when coalesce(sum(l.remaining_quantity), 0) > 0
          then round(sum(l.remaining_quantity * l.unit_cost_cents)::numeric / sum(l.remaining_quantity))::integer
        else greatest(0, coalesce(v_product.last_purchase_price_cents, 0))
      end
    into v_avg_cost
    from public.product_purchase_lots l
    where l.product_id = v_item.product_id
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
      v_delta_wh := v_delta_total;
    elsif v_delta_total < 0 then
      v_remaining := abs(v_delta_total);

      if coalesce(v_stock.warehouse_qty, 0) > 0 and v_remaining > 0 then
        v_move_qty := least(coalesce(v_stock.warehouse_qty, 0), v_remaining);
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
          v_move_qty,
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

        v_total_cost := public.consume_purchase_lots(v_item.product_id, v_move_qty, 'count_adjustment', null, v_movement_id, v_avg_cost);
        update public.inventory_movements im
        set purchase_price_snapshot_cents = case when v_move_qty > 0 then round(v_total_cost::numeric / v_move_qty)::integer else 0 end
        where im.id = v_movement_id;

        v_delta_wh := v_delta_wh - v_move_qty;
        v_remaining := v_remaining - v_move_qty;
      end if;

      if coalesce(v_stock.fridge_qty, 0) > 0 and v_remaining > 0 then
        v_move_qty := least(coalesce(v_stock.fridge_qty, 0), v_remaining);
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
          v_move_qty,
          v_fr,
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

        v_total_cost := public.consume_purchase_lots(v_item.product_id, v_move_qty, 'count_adjustment', null, v_movement_id, v_avg_cost);
        update public.inventory_movements im
        set purchase_price_snapshot_cents = case when v_move_qty > 0 then round(v_total_cost::numeric / v_move_qty)::integer else 0 end
        where im.id = v_movement_id;

        v_delta_fr := v_delta_fr - v_move_qty;
        v_remaining := v_remaining - v_move_qty;
      end if;

      if v_remaining > 0 then
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
          v_remaining,
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
            'delta_total', v_delta_total,
            'overflow_reduction', true
          )
        )
        returning id into v_movement_id;

        v_total_cost := public.consume_purchase_lots(v_item.product_id, v_remaining, 'count_adjustment', null, v_movement_id, v_avg_cost);
        update public.inventory_movements im
        set purchase_price_snapshot_cents = case when v_remaining > 0 then round(v_total_cost::numeric / v_remaining)::integer else 0 end
        where im.id = v_movement_id;

        v_delta_wh := v_delta_wh - v_remaining;
        v_remaining := 0;
      end if;
    end if;

    perform public.refresh_product_inventory_value_from_lots(v_item.product_id);

    product_id := v_item.product_id;
    name := v_product.name;
    soll_warehouse_stock := coalesce(v_stock.warehouse_qty, 0);
    ist_warehouse_stock := coalesce(v_stock.warehouse_qty, 0) + v_delta_wh;
    delta_warehouse := v_delta_wh;
    soll_fridge_stock := coalesce(v_stock.fridge_qty, 0);
    ist_fridge_stock := coalesce(v_stock.fridge_qty, 0) + v_delta_fr;
    delta_fridge := v_delta_fr;
    return next;
  end loop;

  return;
end;
$function$;
