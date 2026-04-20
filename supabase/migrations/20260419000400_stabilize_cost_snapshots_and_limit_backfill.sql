create or replace function public.apply_product_cost_baseline(
  p_product_id uuid default null::uuid
)
returns void
language plpgsql
security definer
as $function$
declare
  v_target_id uuid;
  v_product record;
  v_event record;
  v_running_qty integer;
  v_running_value integer;
  v_unit_cost integer;
  v_avg_cost integer;
  v_delta integer;
  v_last_purchase_price integer;
begin
  if p_product_id is null then
    for v_target_id in
      select p.id
      from public.products p
      order by p.created_at asc, p.id asc
    loop
      perform public.apply_product_cost_baseline(v_target_id);
    end loop;
    return;
  end if;

  select
    p.id,
    coalesce(p.last_purchase_price_cents, 0) as last_purchase_price_cents
  into v_product
  from public.products p
  where p.id = p_product_id
  for update;

  if not found then
    return;
  end if;

  v_last_purchase_price := greatest(0, coalesce(v_product.last_purchase_price_cents, 0));

  if v_last_purchase_price = 0 then
    select coalesce(im.purchase_price_snapshot_cents, 0)
    into v_last_purchase_price
    from public.inventory_movements im
    where im.product_id = p_product_id
      and im.reason = 'purchase'
      and coalesce(im.purchase_price_snapshot_cents, 0) > 0
    order by im.created_at desc, im.id desc
    limit 1;

    v_last_purchase_price := greatest(0, coalesce(v_last_purchase_price, 0));
  end if;

  v_running_qty := 0;
  v_running_value := 0;

  for v_event in
    select
      im.id,
      im.reason,
      im.quantity,
      im.from_location_id,
      im.to_location_id,
      coalesce(im.purchase_price_snapshot_cents, 0) as movement_cost_snapshot,
      im.transaction_id,
      coalesce(t.product_cost_snapshot_cents, 0) as tx_cost_snapshot,
      s.id as storno_id,
      coalesce(s.product_cost_snapshot_cents, 0) as storno_cost_snapshot
    from public.inventory_movements im
    left join public.transactions t
      on t.id = im.transaction_id
    left join public.storno_log s
      on im.reason = 'sale_cancel'
      and (im.meta ->> 'canceled_tx_id') ~* '^[0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12}$'
      and s.original_transaction_id = (im.meta ->> 'canceled_tx_id')::uuid
    where im.product_id = p_product_id
    order by im.created_at asc, im.id asc
  loop
    v_delta := (
      case
        when v_event.to_location_id is not null then v_event.quantity
        else 0
      end
      -
      case
        when v_event.from_location_id is not null then v_event.quantity
        else 0
      end
    );

    v_avg_cost := case
      when v_running_qty > 0 then greatest(0, round(v_running_value::numeric / v_running_qty)::integer)
      else greatest(0, v_last_purchase_price)
    end;

    if v_event.reason in ('purchase', 'opening_balance') then
      v_unit_cost := greatest(
        0,
        coalesce(
          nullif(v_event.movement_cost_snapshot, 0),
          nullif(v_last_purchase_price, 0),
          0
        )
      );

      if v_event.movement_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.inventory_movements im
        set purchase_price_snapshot_cents = v_unit_cost
        where im.id = v_event.id;
      end if;

      if v_unit_cost > 0 then
        v_last_purchase_price := v_unit_cost;
      end if;

      if v_delta > 0 then
        v_running_qty := v_running_qty + v_delta;
        v_running_value := v_running_value + (v_delta * v_unit_cost);
      elsif v_delta < 0 then
        v_running_value := greatest(0, v_running_value - (abs(v_delta) * v_unit_cost));
        v_running_qty := greatest(0, v_running_qty + v_delta);
      end if;
    elsif v_event.reason = 'sale' then
      v_unit_cost := greatest(
        0,
        coalesce(
          nullif(v_event.tx_cost_snapshot, 0),
          nullif(v_event.movement_cost_snapshot, 0),
          case
            when v_running_qty > 0 then v_avg_cost
            else v_last_purchase_price
          end,
          0
        )
      );

      if v_event.tx_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.transactions t
        set product_cost_snapshot_cents = v_unit_cost
        where t.id = v_event.transaction_id;
      end if;

      if v_event.movement_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.inventory_movements im
        set purchase_price_snapshot_cents = v_unit_cost
        where im.id = v_event.id;
      end if;

      if v_delta < 0 then
        v_running_value := greatest(0, v_running_value - (abs(v_delta) * v_unit_cost));
        v_running_qty := greatest(0, v_running_qty + v_delta);
      elsif v_delta > 0 then
        v_running_qty := v_running_qty + v_delta;
        v_running_value := v_running_value + (v_delta * v_unit_cost);
      end if;
    elsif v_event.reason = 'sale_cancel' then
      v_unit_cost := greatest(
        0,
        coalesce(
          nullif(v_event.storno_cost_snapshot, 0),
          nullif(v_event.movement_cost_snapshot, 0),
          nullif(v_event.tx_cost_snapshot, 0),
          case
            when v_running_qty > 0 then v_avg_cost
            else v_last_purchase_price
          end,
          0
        )
      );

      if v_event.storno_id is not null and v_event.storno_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.storno_log s
        set product_cost_snapshot_cents = v_unit_cost
        where s.id = v_event.storno_id;
      end if;

      if v_event.movement_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.inventory_movements im
        set purchase_price_snapshot_cents = v_unit_cost
        where im.id = v_event.id;
      end if;

      if v_delta > 0 then
        v_running_qty := v_running_qty + v_delta;
        v_running_value := v_running_value + (v_delta * v_unit_cost);
      elsif v_delta < 0 then
        v_running_value := greatest(0, v_running_value - (abs(v_delta) * v_unit_cost));
        v_running_qty := greatest(0, v_running_qty + v_delta);
      end if;
    elsif v_event.reason in ('count_adjustment', 'shrinkage', 'waste') then
      v_unit_cost := greatest(
        0,
        coalesce(
          nullif(v_event.movement_cost_snapshot, 0),
          case
            when v_running_qty > 0 then v_avg_cost
            else v_last_purchase_price
          end,
          0
        )
      );

      if v_event.movement_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.inventory_movements im
        set purchase_price_snapshot_cents = v_unit_cost
        where im.id = v_event.id;
      end if;

      if v_delta > 0 then
        v_running_qty := v_running_qty + v_delta;
        v_running_value := v_running_value + (v_delta * v_unit_cost);
      elsif v_delta < 0 then
        v_running_value := greatest(0, v_running_value - (abs(v_delta) * v_unit_cost));
        v_running_qty := greatest(0, v_running_qty + v_delta);
      end if;
    end if;
  end loop;

  update public.products p
  set
    inventory_value_cents = greatest(0, v_running_value),
    last_purchase_price_cents = case
      when v_last_purchase_price > 0 then v_last_purchase_price
      else p.last_purchase_price_cents
    end
  where p.id = p_product_id;

  with orphan_tx_costs as (
    select
      t.id,
      coalesce(prev_purchase.price, nullif(p.last_purchase_price_cents, 0), 0) as cost
    from public.transactions t
    join public.products p on p.id = t.product_id
    left join lateral (
      select im.purchase_price_snapshot_cents as price
      from public.inventory_movements im
      where im.product_id = t.product_id
        and im.reason = 'purchase'
        and coalesce(im.purchase_price_snapshot_cents, 0) > 0
        and im.created_at <= t.created_at
      order by im.created_at desc, im.id desc
      limit 1
    ) prev_purchase on true
    where t.product_id = p_product_id
      and coalesce(t.product_cost_snapshot_cents, 0) = 0
      and not exists (
        select 1
        from public.inventory_movements im
        where im.reason = 'sale'
          and im.transaction_id = t.id
      )
  )
  update public.transactions t
  set product_cost_snapshot_cents = c.cost
  from orphan_tx_costs c
  where t.id = c.id
    and c.cost > 0;

  with orphan_storno_costs as (
    select
      s.id,
      coalesce(
        nullif(tx.product_cost_snapshot_cents, 0),
        prev_purchase.price,
        nullif(p.last_purchase_price_cents, 0),
        0
      ) as cost
    from public.storno_log s
    left join public.transactions tx on tx.id = s.original_transaction_id
    join public.products p on p.id = s.product_id
    left join lateral (
      select im.purchase_price_snapshot_cents as price
      from public.inventory_movements im
      where im.product_id = s.product_id
        and im.reason = 'purchase'
        and coalesce(im.purchase_price_snapshot_cents, 0) > 0
        and im.created_at <= coalesce(s.transaction_created_at, s.canceled_at)
      order by im.created_at desc, im.id desc
      limit 1
    ) prev_purchase on true
    where s.product_id = p_product_id
      and coalesce(s.product_cost_snapshot_cents, 0) = 0
      and not exists (
        select 1
        from public.inventory_movements im
        where im.reason = 'sale_cancel'
          and (im.meta ->> 'canceled_tx_id') ~* '^[0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12}$'
          and (im.meta ->> 'canceled_tx_id')::uuid = s.original_transaction_id
      )
  )
  update public.storno_log s
  set product_cost_snapshot_cents = c.cost
  from orphan_storno_costs c
  where s.id = c.id
    and c.cost > 0;
end;
$function$;

create or replace function public.add_storage(
  product_id uuid,
  amount integer,
  purchase_price_cents integer default null
)
returns void
language plpgsql
security definer
as $function$
declare
  v_wh uuid;
  v_product public.products%rowtype;
  v_price integer;
  v_total_stock integer;
  v_avg_cost integer;
  v_abs_amount integer;
begin
  if coalesce(amount, 0) = 0 then
    return;
  end if;

  select *
  into v_product
  from public.products p
  where p.id = product_id
  for update;

  if not found then
    raise exception 'Produkt nicht gefunden';
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  if v_wh is null then
    raise exception 'Stock location warehouse not configured';
  end if;

  v_total_stock := greatest(0, coalesce(v_product.warehouse_stock, 0) + coalesce(v_product.fridge_stock, 0));
  v_abs_amount := abs(amount);

  if amount > 0 then
    v_price := greatest(
      0,
      coalesce(
        purchase_price_cents,
        v_product.last_purchase_price_cents,
        0
      )
    );

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
      product_id,
      amount,
      null,
      v_wh,
      'purchase',
      'Einlagerung',
      v_price,
      jsonb_build_object('source', 'add_storage')
    );

    update public.products p
    set
      last_restocked_at = now(),
      last_purchase_price_cents = v_price,
      inventory_value_cents = greatest(0, coalesce(p.inventory_value_cents, 0) + (amount * v_price))
    where p.id = product_id;
  else
    v_avg_cost := case
      when v_total_stock > 0 then greatest(0, round(coalesce(v_product.inventory_value_cents, 0)::numeric / v_total_stock)::integer)
      else 0
    end;

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
      product_id,
      v_abs_amount,
      v_wh,
      null,
      'count_adjustment',
      'Bestandskorrektur Lager',
      v_avg_cost,
      jsonb_build_object('source', 'add_storage')
    );

    update public.products p
    set inventory_value_cents = greatest(0, coalesce(p.inventory_value_cents, 0) - (v_abs_amount * v_avg_cost))
    where p.id = product_id;
  end if;
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
  v_total_stock integer;
  v_avg_cost integer;
  v_total_delta integer;
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

    select
      p.id,
      p.name,
      coalesce(p.inventory_value_cents, 0) as inventory_value_cents,
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

    v_ist_wh := v_item.ist_warehouse_stock;
    v_ist_fr := v_item.ist_fridge_stock;
    v_delta_wh := v_ist_wh - coalesce(v_stock.warehouse_qty, 0);
    v_delta_fr := v_ist_fr - coalesce(v_stock.fridge_qty, 0);
    v_total_stock := greatest(0, coalesce(v_stock.total_qty, 0));
    v_avg_cost := case
      when v_total_stock > 0 then greatest(0, round(coalesce(v_product.inventory_value_cents, 0)::numeric / v_total_stock)::integer)
      else greatest(0, coalesce(v_product.last_purchase_price_cents, 0))
    end;
    v_total_delta := v_delta_wh + v_delta_fr;

    if v_delta_wh <> 0 then
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
        abs(v_delta_wh),
        case when v_delta_wh < 0 then v_wh else null end,
        case when v_delta_wh > 0 then v_wh else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Lager'),
        public.app_current_user_id(),
        v_avg_cost,
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
        purchase_price_snapshot_cents,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_fr),
        case when v_delta_fr < 0 then v_fr else null end,
        case when v_delta_fr > 0 then v_fr else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Kuehlschrank'),
        public.app_current_user_id(),
        v_avg_cost,
        jsonb_build_object(
          'source', 'inventory_count',
          'location', 'fridge',
          'expected', coalesce(v_stock.fridge_qty, 0),
          'counted', v_ist_fr,
          'delta', v_delta_fr
        )
      );
    end if;

    if v_total_delta <> 0 then
      update public.products p
      set inventory_value_cents = greatest(0, coalesce(p.inventory_value_cents, 0) + (v_total_delta * v_avg_cost))
      where p.id = v_item.product_id;
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

drop function if exists public.admin_create_product(text, integer, integer, text, boolean, boolean, integer);
create or replace function public.admin_create_product(
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean,
  p_last_purchase_price_cents integer default 0
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
    inventoried,
    last_purchase_price_cents
  ) values (
    coalesce(p_name, 'Neu'),
    coalesce(p_price, 0),
    coalesce(p_guest_price, 0),
    coalesce(p_category, 'Sonstiges'),
    coalesce(p_active, true),
    coalesce(p_inventoried, true),
    greatest(0, coalesce(p_last_purchase_price_cents, 0))
  )
  returning * into v_row;

  return v_row;
end;
$function$;

drop function if exists public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean, integer);
create or replace function public.admin_update_product(
  p_id uuid,
  p_name text default null,
  p_price integer default null,
  p_guest_price integer default null,
  p_category text default null,
  p_active boolean default null,
  p_inventoried boolean default null,
  p_last_purchase_price_cents integer default null
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
    inventoried = coalesce(p_inventoried, p.inventoried),
    last_purchase_price_cents = coalesce(greatest(0, p_last_purchase_price_cents), p.last_purchase_price_cents)
  where p.id = p_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Produkt nicht gefunden';
  end if;

  if p_last_purchase_price_cents is not null then
    perform public.apply_product_cost_baseline(v_row.id);
  end if;

  return v_row;
end;
$function$;

drop function if exists public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean, integer);
create or replace function public.api_admin_create_product(
  p_token text,
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean,
  p_last_purchase_price_cents integer default 0
)
returns public.products
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_create_product(
    p_name,
    p_price,
    p_guest_price,
    p_category,
    p_active,
    p_inventoried,
    p_last_purchase_price_cents
  );
end;
$function$;

drop function if exists public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean, integer);
create or replace function public.api_admin_update_product(
  p_token text,
  p_id uuid,
  p_name text default null,
  p_price integer default null,
  p_guest_price integer default null,
  p_category text default null,
  p_active boolean default null,
  p_inventoried boolean default null,
  p_last_purchase_price_cents integer default null
)
returns public.products
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_update_product(
    p_id,
    p_name,
    p_price,
    p_guest_price,
    p_category,
    p_active,
    p_inventoried,
    p_last_purchase_price_cents
  );
end;
$function$;

revoke all on function public.apply_product_cost_baseline(uuid) from public;
revoke all on function public.admin_create_product(text, integer, integer, text, boolean, boolean, integer) from public;
revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean, integer) from public;
revoke all on function public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean, integer) from public;
revoke all on function public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean, integer) from public;

select public.apply_product_cost_baseline(null);
notify pgrst, 'reload schema';
