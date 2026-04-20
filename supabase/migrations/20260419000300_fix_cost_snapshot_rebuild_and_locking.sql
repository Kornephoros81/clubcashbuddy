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

  v_running_qty := 0;
  v_running_value := 0;
  v_last_purchase_price := greatest(0, coalesce(v_product.last_purchase_price_cents, 0));

  for v_event in
    select
      im.id,
      im.reason,
      im.quantity,
      im.from_location_id,
      im.to_location_id,
      im.purchase_price_snapshot_cents,
      im.transaction_id,
      t.product_cost_snapshot_cents as tx_cost_snapshot,
      s.id as storno_id,
      s.product_cost_snapshot_cents as storno_cost_snapshot
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
      v_unit_cost := greatest(0, coalesce(v_event.purchase_price_snapshot_cents, v_last_purchase_price, 0));

      if v_unit_cost > 0 and coalesce(v_event.purchase_price_snapshot_cents, 0) <> v_unit_cost then
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
      end if;
    elsif v_event.reason = 'sale' then
      v_unit_cost := greatest(
        0,
        case
          when v_running_qty > 0 then v_avg_cost
          else v_last_purchase_price
        end
      );

      update public.transactions t
      set product_cost_snapshot_cents = v_unit_cost
      where t.id = v_event.transaction_id
        and coalesce(t.product_cost_snapshot_cents, -1) <> v_unit_cost;

      update public.inventory_movements im
      set purchase_price_snapshot_cents = v_unit_cost
      where im.id = v_event.id
        and coalesce(im.purchase_price_snapshot_cents, -1) <> v_unit_cost;

      if v_delta < 0 then
        v_running_value := greatest(0, v_running_value - (abs(v_delta) * v_unit_cost));
        v_running_qty := greatest(0, v_running_qty + v_delta);
      end if;
    elsif v_event.reason = 'sale_cancel' then
      v_unit_cost := greatest(
        0,
        coalesce(
          v_event.tx_cost_snapshot,
          case
            when v_running_qty > 0 then v_avg_cost
            else v_last_purchase_price
          end,
          0
        )
      );

      if v_event.storno_id is not null then
        update public.storno_log s
        set product_cost_snapshot_cents = v_unit_cost
        where s.id = v_event.storno_id
          and coalesce(s.product_cost_snapshot_cents, -1) <> v_unit_cost;
      end if;

      update public.inventory_movements im
      set purchase_price_snapshot_cents = v_unit_cost
      where im.id = v_event.id
        and coalesce(im.purchase_price_snapshot_cents, -1) <> v_unit_cost;

      if v_delta > 0 then
        v_running_qty := v_running_qty + v_delta;
        v_running_value := v_running_value + (v_delta * v_unit_cost);
      end if;
    elsif v_event.reason in ('count_adjustment', 'shrinkage', 'waste') then
      v_unit_cost := greatest(
        0,
        case
          when v_running_qty > 0 then v_avg_cost
          else v_last_purchase_price
        end
      );

      update public.inventory_movements im
      set purchase_price_snapshot_cents = v_unit_cost
      where im.id = v_event.id
        and coalesce(im.purchase_price_snapshot_cents, -1) <> v_unit_cost;

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
      coalesce(prev_purchase.price, next_purchase.price, p.last_purchase_price_cents, 0) as cost
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
    left join lateral (
      select im.purchase_price_snapshot_cents as price
      from public.inventory_movements im
      where im.product_id = t.product_id
        and im.reason = 'purchase'
        and coalesce(im.purchase_price_snapshot_cents, 0) > 0
        and im.created_at > t.created_at
      order by im.created_at asc, im.id asc
      limit 1
    ) next_purchase on true
    where t.product_id = p_product_id
      and not exists (
        select 1
        from public.inventory_movements im
        where im.reason = 'sale'
          and im.transaction_id = t.id
      )
      and coalesce(t.product_cost_snapshot_cents, 0) = 0
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
        tx.product_cost_snapshot_cents,
        prev_purchase.price,
        next_purchase.price,
        p.last_purchase_price_cents,
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
    left join lateral (
      select im.purchase_price_snapshot_cents as price
      from public.inventory_movements im
      where im.product_id = s.product_id
        and im.reason = 'purchase'
        and coalesce(im.purchase_price_snapshot_cents, 0) > 0
        and im.created_at > coalesce(s.transaction_created_at, s.canceled_at)
      order by im.created_at asc, im.id asc
      limit 1
    ) next_purchase on true
    where s.product_id = p_product_id
      and not exists (
        select 1
        from public.inventory_movements im
        where im.reason = 'sale_cancel'
          and (im.meta ->> 'canceled_tx_id') ~* '^[0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12}$'
          and (im.meta ->> 'canceled_tx_id')::uuid = s.original_transaction_id
      )
      and coalesce(s.product_cost_snapshot_cents, 0) = 0
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

  if v_product.id is null then
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

  perform public.apply_product_cost_baseline(product_id);
end;
$function$;

create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid,
  p_transaction_type text default null::text
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
  v_cost_snapshot integer;
  v_inventory_value integer;
  v_total_stock integer;
  v_fr uuid;
  v_tx_type text;
  v_device_id uuid;
begin
  v_device_id := public.app_current_device_id();

  select
    m.is_guest,
    nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), '')
  into is_guest, v_member_name
  from public.members m
  where m.id = member_id;

  if not found then
    raise exception 'MEMBER_NOT_FOUND';
  end if;

  if product_id is not null then
    select
      case when is_guest then p.guest_price else p.price end,
      p.inventoried,
      p.name,
      coalesce(p.inventory_value_cents, 0),
      greatest(0, coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0))
    into amt, v_inventoried, v_product_name, v_inventory_value, v_total_stock
    from public.products p
    where p.id = product_id
      and p.active = true
    for update;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    v_price_snapshot := amt;
    v_cost_snapshot := case
      when coalesce(v_inventoried, false) and v_total_stock > 0
        then greatest(0, round(v_inventory_value::numeric / v_total_stock)::integer)
      else 0
    end;
    amt := -abs(amt);
    pid := product_id;
    note := null;
    v_tx_type := 'sale_product';
  else
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;

    v_tx_type := coalesce(nullif(trim(p_transaction_type), ''), 'sale_free_amount');
    if v_tx_type not in ('sale_free_amount', 'cash_withdrawal', 'credit_adjustment') then
      raise exception 'Ungueltiger transaction_type fuer freien Betrag';
    end if;

    note := coalesce(
      nullif(trim(p_note), ''),
      case
        when v_tx_type = 'cash_withdrawal' then 'Bar-Entnahme'
        when v_tx_type = 'credit_adjustment' then 'Guthabenbuchung'
        else 'frei'
      end
    );
    v_inventoried := false;
    v_cost_snapshot := 0;
  end if;

  insert into public.transactions (
    member_id,
    product_id,
    amount,
    note,
    client_tx_id,
    member_name_snapshot,
    product_name_snapshot,
    product_price_snapshot,
    product_cost_snapshot_cents,
    transaction_type,
    device_id,
    device_id_snapshot
  )
  values (
    member_id,
    pid,
    amt,
    note,
    client_tx_id_param,
    coalesce(v_member_name, member_id::text),
    v_product_name,
    v_price_snapshot,
    v_cost_snapshot,
    v_tx_type,
    v_device_id,
    v_device_id
  )
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null and coalesce(v_inventoried, true) then
    update public.products p
    set inventory_value_cents = greatest(0, coalesce(p.inventory_value_cents, 0) - coalesce(v_cost_snapshot, 0))
    where p.id = pid;

    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      transaction_id,
      note,
      device_id,
      device_id_snapshot,
      purchase_price_snapshot_cents,
      meta
    ) values (
      pid,
      1,
      v_fr,
      null,
      'sale',
      txid,
      'Verkauf',
      v_device_id,
      v_device_id,
      v_cost_snapshot,
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
  note text default null::text,
  p_device_id uuid default null::uuid
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
  v_device_id uuid;
begin
  v_device_id := coalesce(p_device_id, public.app_current_device_id());

  if public.app_current_role() = 'device' and v_device_id is null then
    raise exception 'DEVICE_ID_REQUIRED';
  end if;

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

  if v_tx.product_id is not null then
    perform 1
    from public.products p
    where p.id = v_tx.product_id
    for update;
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
    note,
    transaction_type,
    device_id,
    device_id_snapshot,
    product_cost_snapshot_cents
  ) values (
    v_tx.id,
    v_tx.member_id,
    v_tx.product_id,
    v_tx.created_at,
    v_canceled_at,
    v_tx.amount,
    v_tx.note,
    coalesce(v_tx.transaction_type, case when v_tx.product_id is null then 'sale_free_amount' else 'sale_product' end),
    v_device_id,
    v_device_id,
    coalesce(v_tx.product_cost_snapshot_cents, 0)
  );

  if v_tx.product_id is not null then
    update public.products p
    set inventory_value_cents = greatest(0, coalesce(p.inventory_value_cents, 0) + coalesce(v_tx.product_cost_snapshot_cents, 0))
    where p.id = v_tx.product_id;

    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      device_id,
      device_id_snapshot,
      purchase_price_snapshot_cents,
      meta
    ) values (
      v_tx.product_id,
      1,
      null,
      v_fr,
      'sale_cancel',
      'Storno Rueckbuchung',
      v_device_id,
      v_device_id,
      coalesce(v_tx.product_cost_snapshot_cents, 0),
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    );
  end if;

  return v_cancel_id;
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

    perform public.apply_product_cost_baseline(v_item.product_id);

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

revoke all on function public.apply_product_cost_baseline(uuid) from public;
notify pgrst, 'reload schema';
