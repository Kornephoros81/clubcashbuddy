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