create table if not exists public.product_purchase_lots (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  inventory_movement_id uuid null references public.inventory_movements(id) on delete set null,
  source_reason text not null check (source_reason in ('purchase', 'opening_balance', 'count_adjustment', 'manual', 'migration_initial')),
  purchased_quantity integer not null check (purchased_quantity > 0),
  remaining_quantity integer not null check (remaining_quantity >= 0 and remaining_quantity <= purchased_quantity),
  unit_cost_cents integer not null check (unit_cost_cents >= 0),
  note text null,
  corrected_from_price_cents integer null,
  corrected_at timestamp with time zone null,
  corrected_by uuid null references auth.users(id),
  created_at timestamp with time zone not null default now()
);

create index if not exists product_purchase_lots_product_idx
  on public.product_purchase_lots(product_id, created_at asc, id asc);

create index if not exists product_purchase_lots_remaining_idx
  on public.product_purchase_lots(product_id, remaining_quantity desc);

create table if not exists public.product_lot_allocations (
  id uuid primary key default gen_random_uuid(),
  purchase_lot_id uuid not null references public.product_purchase_lots(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  inventory_movement_id uuid null references public.inventory_movements(id) on delete set null,
  source_transaction_id uuid null,
  reason text not null check (reason in ('sale', 'count_adjustment', 'shrinkage', 'waste')),
  quantity integer not null check (quantity > 0),
  unit_cost_cents integer not null check (unit_cost_cents >= 0),
  created_at timestamp with time zone not null default now(),
  reversed_at timestamp with time zone null,
  reversal_inventory_movement_id uuid null references public.inventory_movements(id) on delete set null,
  reversal_reason text null check (reversal_reason in ('sale_cancel'))
);

create index if not exists product_lot_allocations_product_idx
  on public.product_lot_allocations(product_id, created_at asc, id asc);

create index if not exists product_lot_allocations_transaction_idx
  on public.product_lot_allocations(source_transaction_id)
  where source_transaction_id is not null;

alter table public.product_purchase_lots enable row level security;
alter table public.product_lot_allocations enable row level security;
revoke all on table public.product_purchase_lots from public;
revoke all on table public.product_lot_allocations from public;
revoke all on table public.product_purchase_lots from anon;
revoke all on table public.product_purchase_lots from authenticated;
revoke all on table public.product_lot_allocations from anon;
revoke all on table public.product_lot_allocations from authenticated;

create or replace function public.refresh_product_inventory_value_from_lots(
  p_product_id uuid
)
returns void
language plpgsql
security definer
as $function$
declare
  v_inventory_value integer;
  v_last_purchase integer;
begin
  select
    coalesce(sum(l.remaining_quantity * l.unit_cost_cents), 0)::int
  into v_inventory_value
  from public.product_purchase_lots l
  where l.product_id = p_product_id;

  select l.unit_cost_cents
  into v_last_purchase
  from public.product_purchase_lots l
  where l.product_id = p_product_id
    and l.source_reason = 'purchase'
  order by l.created_at desc, l.id desc
  limit 1;

  update public.products p
  set
    inventory_value_cents = greatest(0, coalesce(v_inventory_value, 0)),
    last_purchase_price_cents = coalesce(greatest(0, v_last_purchase), p.last_purchase_price_cents)
  where p.id = p_product_id;
end;
$function$;

create or replace function public.create_purchase_lot(
  p_product_id uuid,
  p_inventory_movement_id uuid,
  p_quantity integer,
  p_unit_cost_cents integer,
  p_source_reason text,
  p_note text default null
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_lot_id uuid;
begin
  if coalesce(p_quantity, 0) <= 0 then
    raise exception 'Lot quantity must be positive';
  end if;

  insert into public.product_purchase_lots (
    product_id,
    inventory_movement_id,
    source_reason,
    purchased_quantity,
    remaining_quantity,
    unit_cost_cents,
    note,
    created_at
  )
  values (
    p_product_id,
    p_inventory_movement_id,
    p_source_reason,
    p_quantity,
    p_quantity,
    greatest(0, coalesce(p_unit_cost_cents, 0)),
    p_note,
    coalesce((select im.created_at from public.inventory_movements im where im.id = p_inventory_movement_id), now())
  )
  returning id into v_lot_id;

  return v_lot_id;
end;
$function$;

create or replace function public.consume_purchase_lots(
  p_product_id uuid,
  p_quantity integer,
  p_reason text,
  p_transaction_id uuid default null::uuid,
  p_inventory_movement_id uuid default null::uuid,
  p_cost_fallback_cents integer default 0
)
returns integer
language plpgsql
security definer
as $function$
declare
  v_needed integer;
  v_total_cost integer;
  v_take integer;
  v_lot record;
  v_fallback_cost integer;
  v_fallback_lot uuid;
begin
  v_needed := greatest(0, coalesce(p_quantity, 0));
  v_total_cost := 0;

  if v_needed = 0 then
    return 0;
  end if;

  for v_lot in
    select
      l.id,
      l.remaining_quantity,
      l.unit_cost_cents
    from public.product_purchase_lots l
    where l.product_id = p_product_id
      and l.remaining_quantity > 0
    order by l.created_at asc, l.id asc
    for update
  loop
    exit when v_needed <= 0;
    v_take := least(v_needed, v_lot.remaining_quantity);

    update public.product_purchase_lots l
    set remaining_quantity = l.remaining_quantity - v_take
    where l.id = v_lot.id;

    insert into public.product_lot_allocations (
      purchase_lot_id,
      product_id,
      inventory_movement_id,
      source_transaction_id,
      reason,
      quantity,
      unit_cost_cents,
      created_at
    ) values (
      v_lot.id,
      p_product_id,
      p_inventory_movement_id,
      p_transaction_id,
      p_reason,
      v_take,
      v_lot.unit_cost_cents,
      coalesce((select im.created_at from public.inventory_movements im where im.id = p_inventory_movement_id), now())
    );

    v_total_cost := v_total_cost + (v_take * v_lot.unit_cost_cents);
    v_needed := v_needed - v_take;
  end loop;

  if v_needed > 0 then
    select coalesce(p.last_purchase_price_cents, 0)
    into v_fallback_cost
    from public.products p
    where p.id = p_product_id
    for update;

    v_fallback_cost := greatest(0, coalesce(p_cost_fallback_cents, 0), coalesce(v_fallback_cost, 0));

    if v_fallback_cost <= 0 then
      raise exception 'NO_PURCHASE_LOTS_AVAILABLE';
    end if;

    insert into public.product_purchase_lots (
      product_id,
      inventory_movement_id,
      source_reason,
      purchased_quantity,
      remaining_quantity,
      unit_cost_cents,
      note,
      created_at
    ) values (
      p_product_id,
      p_inventory_movement_id,
      'manual',
      v_needed,
      0,
      v_fallback_cost,
      'Automatisch erzeugter Fallback-Lot',
      coalesce((select im.created_at from public.inventory_movements im where im.id = p_inventory_movement_id), now())
    )
    returning id into v_fallback_lot;

    insert into public.product_lot_allocations (
      purchase_lot_id,
      product_id,
      inventory_movement_id,
      source_transaction_id,
      reason,
      quantity,
      unit_cost_cents,
      created_at
    ) values (
      v_fallback_lot,
      p_product_id,
      p_inventory_movement_id,
      p_transaction_id,
      p_reason,
      v_needed,
      v_fallback_cost,
      coalesce((select im.created_at from public.inventory_movements im where im.id = p_inventory_movement_id), now())
    );

    v_total_cost := v_total_cost + (v_needed * v_fallback_cost);
    v_needed := 0;
  end if;

  return v_total_cost;
end;
$function$;

create or replace function public.restore_purchase_lot_allocations(
  p_product_id uuid,
  p_transaction_id uuid,
  p_inventory_movement_id uuid default null::uuid
)
returns integer
language plpgsql
security definer
as $function$
declare
  v_alloc record;
  v_total_cost integer;
begin
  v_total_cost := 0;

  for v_alloc in
    select
      a.id,
      a.purchase_lot_id,
      a.quantity,
      a.unit_cost_cents
    from public.product_lot_allocations a
    where a.product_id = p_product_id
      and a.source_transaction_id = p_transaction_id
      and a.reason = 'sale'
      and a.reversed_at is null
    order by a.created_at desc, a.id desc
    for update
  loop
    update public.product_purchase_lots l
    set remaining_quantity = least(l.purchased_quantity, l.remaining_quantity + v_alloc.quantity)
    where l.id = v_alloc.purchase_lot_id;

    update public.product_lot_allocations a
    set
      reversed_at = now(),
      reversal_inventory_movement_id = p_inventory_movement_id,
      reversal_reason = 'sale_cancel'
    where a.id = v_alloc.id;

    v_total_cost := v_total_cost + (v_alloc.quantity * v_alloc.unit_cost_cents);
  end loop;

  return v_total_cost;
end;
$function$;

create or replace function public.rebuild_purchase_lots(
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
  v_delta integer;
  v_total_cost integer;
  v_unit_cost integer;
  v_last_purchase integer;
begin
  if p_product_id is null then
    for v_target_id in
      select p.id
      from public.products p
      order by p.created_at asc, p.id asc
    loop
      perform public.rebuild_purchase_lots(v_target_id);
    end loop;
    return;
  end if;

  delete from public.product_lot_allocations a
  where a.product_id = p_product_id;

  delete from public.product_purchase_lots l
  where l.product_id = p_product_id;

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

  v_last_purchase := greatest(0, coalesce(v_product.last_purchase_price_cents, 0));

  for v_event in
    select
      im.id,
      im.reason,
      im.quantity,
      im.from_location_id,
      im.to_location_id,
      coalesce(im.purchase_price_snapshot_cents, 0) as movement_cost_snapshot,
      im.transaction_id,
      coalesce(t.product_cost_snapshot_cents, 0) as tx_cost_snapshot
    from public.inventory_movements im
    left join public.transactions t on t.id = im.transaction_id
    where im.product_id = p_product_id
    order by im.created_at asc, im.id asc
  loop
    v_delta := (
      case when v_event.to_location_id is not null then v_event.quantity else 0 end
      -
      case when v_event.from_location_id is not null then v_event.quantity else 0 end
    );

    if v_event.reason in ('purchase', 'opening_balance') or (v_event.reason = 'count_adjustment' and v_delta > 0) then
      v_unit_cost := greatest(0, coalesce(nullif(v_event.movement_cost_snapshot, 0), nullif(v_last_purchase, 0), 0));
      if v_unit_cost > 0 and v_event.reason = 'purchase' then
        v_last_purchase := v_unit_cost;
      end if;
      if v_event.movement_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.inventory_movements im
        set purchase_price_snapshot_cents = v_unit_cost
        where im.id = v_event.id;
      end if;
      if v_delta > 0 then
        perform public.create_purchase_lot(
          p_product_id,
          v_event.id,
          v_delta,
          v_unit_cost,
          case when v_event.reason = 'count_adjustment' then 'count_adjustment' else v_event.reason end,
          null
        );
      end if;
    elsif v_event.reason = 'sale' then
      v_total_cost := public.consume_purchase_lots(
        p_product_id,
        abs(v_delta),
        'sale',
        v_event.transaction_id,
        v_event.id,
        coalesce(nullif(v_event.tx_cost_snapshot, 0), nullif(v_event.movement_cost_snapshot, 0), v_last_purchase, 0)
      );
      v_unit_cost := case when abs(v_delta) > 0 then round(v_total_cost::numeric / abs(v_delta))::integer else 0 end;
      if coalesce(v_event.tx_cost_snapshot, 0) = 0 and v_total_cost > 0 then
        update public.transactions t
        set product_cost_snapshot_cents = v_total_cost
        where t.id = v_event.transaction_id;
      end if;
      if v_event.movement_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.inventory_movements im
        set purchase_price_snapshot_cents = v_unit_cost
        where im.id = v_event.id;
      end if;
    elsif v_event.reason = 'sale_cancel' then
      v_total_cost := public.restore_purchase_lot_allocations(
        p_product_id,
        (case
          when (select (im.meta ->> 'canceled_tx_id') from public.inventory_movements im where im.id = v_event.id) ~* '^[0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12}$'
            then ((select im.meta ->> 'canceled_tx_id' from public.inventory_movements im where im.id = v_event.id))::uuid
          else null
        end),
        v_event.id
      );
      v_unit_cost := case when abs(v_delta) > 0 then round(v_total_cost::numeric / abs(v_delta))::integer else 0 end;
      if v_event.movement_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.inventory_movements im
        set purchase_price_snapshot_cents = v_unit_cost
        where im.id = v_event.id;
      end if;
    elsif v_event.reason in ('count_adjustment', 'shrinkage', 'waste') and v_delta < 0 then
      v_total_cost := public.consume_purchase_lots(
        p_product_id,
        abs(v_delta),
        v_event.reason,
        null,
        v_event.id,
        coalesce(nullif(v_event.movement_cost_snapshot, 0), v_last_purchase, 0)
      );
      v_unit_cost := case when abs(v_delta) > 0 then round(v_total_cost::numeric / abs(v_delta))::integer else 0 end;
      if v_event.movement_cost_snapshot = 0 and v_unit_cost > 0 then
        update public.inventory_movements im
        set purchase_price_snapshot_cents = v_unit_cost
        where im.id = v_event.id;
      end if;
    end if;
  end loop;

  perform public.refresh_product_inventory_value_from_lots(p_product_id);
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
  v_abs_amount integer;
  v_movement_id uuid;
  v_total_cost integer;
  v_unit_cost integer;
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

  v_abs_amount := abs(amount);

  if amount > 0 then
    v_price := greatest(0, coalesce(purchase_price_cents, v_product.last_purchase_price_cents, 0));

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
    )
    returning id into v_movement_id;

    perform public.create_purchase_lot(product_id, v_movement_id, amount, v_price, 'purchase', 'Einlagerung');

    update public.products p
    set
      last_restocked_at = now(),
      last_purchase_price_cents = v_price
    where p.id = product_id;
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
      product_id,
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
      product_id,
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

  perform public.refresh_product_inventory_value_from_lots(product_id);
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
  v_fr uuid;
  v_tx_type text;
  v_device_id uuid;
  v_movement_id uuid;
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
      p.name
    into amt, v_inventoried, v_product_name
    from public.products p
    where p.id = product_id
      and p.active = true
    for update;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    v_price_snapshot := amt;
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
    0,
    v_tx_type,
    v_device_id,
    v_device_id
  )
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null and coalesce(v_inventoried, true) then
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
      public.get_stock_location_id('fridge'),
      null,
      'sale',
      txid,
      'Verkauf',
      v_device_id,
      v_device_id,
      0,
      jsonb_build_object('source', 'book_transaction')
    )
    returning id into v_movement_id;

    v_cost_snapshot := public.consume_purchase_lots(pid, 1, 'sale', txid, v_movement_id, 0);

    update public.transactions t
    set product_cost_snapshot_cents = v_cost_snapshot
    where t.id = txid;

    update public.inventory_movements im
    set purchase_price_snapshot_cents = v_cost_snapshot
    where im.id = v_movement_id;

    perform public.refresh_product_inventory_value_from_lots(pid);
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
  v_device_id uuid;
  v_movement_id uuid;
  v_cost_snapshot integer;
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

  if v_tx.product_id is not null then
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
      public.get_stock_location_id('fridge'),
      'sale_cancel',
      'Storno Rueckbuchung',
      v_device_id,
      v_device_id,
      0,
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    )
    returning id into v_movement_id;

    v_cost_snapshot := public.restore_purchase_lot_allocations(v_tx.product_id, v_tx.id, v_movement_id);
  else
    v_cost_snapshot := 0;
  end if;

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
    coalesce(nullif(v_tx.product_cost_snapshot_cents, 0), v_cost_snapshot, 0)
  );

  if v_tx.product_id is not null then
    update public.inventory_movements im
    set purchase_price_snapshot_cents = coalesce(nullif(v_tx.product_cost_snapshot_cents, 0), v_cost_snapshot, 0)
    where im.id = v_movement_id;

    perform public.refresh_product_inventory_value_from_lots(v_tx.product_id);
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
  v_total_stock integer;
  v_avg_cost integer;
  v_movement_id uuid;
  v_total_cost integer;
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

    if v_delta_wh <> 0 then
      if v_delta_wh > 0 then
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
          null,
          v_wh,
          'count_adjustment',
          coalesce(p_note, 'Inventurabgleich Lager'),
          public.app_current_user_id(),
          v_avg_cost,
          jsonb_build_object('source', 'inventory_count', 'location', 'warehouse', 'expected', coalesce(v_stock.warehouse_qty, 0), 'counted', v_ist_wh, 'delta', v_delta_wh)
        )
        returning id into v_movement_id;

        perform public.create_purchase_lot(v_item.product_id, v_movement_id, abs(v_delta_wh), v_avg_cost, 'count_adjustment', coalesce(p_note, 'Inventurabgleich Lager'));
      else
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
          v_wh,
          null,
          'count_adjustment',
          coalesce(p_note, 'Inventurabgleich Lager'),
          public.app_current_user_id(),
          0,
          jsonb_build_object('source', 'inventory_count', 'location', 'warehouse', 'expected', coalesce(v_stock.warehouse_qty, 0), 'counted', v_ist_wh, 'delta', v_delta_wh)
        )
        returning id into v_movement_id;

        v_total_cost := public.consume_purchase_lots(v_item.product_id, abs(v_delta_wh), 'count_adjustment', null, v_movement_id, v_avg_cost);
        update public.inventory_movements im
        set purchase_price_snapshot_cents = case when abs(v_delta_wh) > 0 then round(v_total_cost::numeric / abs(v_delta_wh))::integer else 0 end
        where im.id = v_movement_id;
      end if;
    end if;

    if v_delta_fr <> 0 then
      if v_delta_fr > 0 then
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
          null,
          v_fr,
          'count_adjustment',
          coalesce(p_note, 'Inventurabgleich Kuehlschrank'),
          public.app_current_user_id(),
          v_avg_cost,
          jsonb_build_object('source', 'inventory_count', 'location', 'fridge', 'expected', coalesce(v_stock.fridge_qty, 0), 'counted', v_ist_fr, 'delta', v_delta_fr)
        )
        returning id into v_movement_id;

        perform public.create_purchase_lot(v_item.product_id, v_movement_id, abs(v_delta_fr), v_avg_cost, 'count_adjustment', coalesce(p_note, 'Inventurabgleich Kuehlschrank'));
      else
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
          v_fr,
          null,
          'count_adjustment',
          coalesce(p_note, 'Inventurabgleich Kuehlschrank'),
          public.app_current_user_id(),
          0,
          jsonb_build_object('source', 'inventory_count', 'location', 'fridge', 'expected', coalesce(v_stock.fridge_qty, 0), 'counted', v_ist_fr, 'delta', v_delta_fr)
        )
        returning id into v_movement_id;

        v_total_cost := public.consume_purchase_lots(v_item.product_id, abs(v_delta_fr), 'count_adjustment', null, v_movement_id, v_avg_cost);
        update public.inventory_movements im
        set purchase_price_snapshot_cents = case when abs(v_delta_fr) > 0 then round(v_total_cost::numeric / abs(v_delta_fr))::integer else 0 end
        where im.id = v_movement_id;
      end if;
    end if;

    perform public.refresh_product_inventory_value_from_lots(v_item.product_id);

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

create or replace function public.admin_list_purchase_lots(
  p_product_id uuid default null::uuid,
  p_remaining_only boolean default true
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
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    l.id,
    l.product_id,
    p.name as product_name,
    l.inventory_movement_id,
    l.source_reason,
    l.purchased_quantity,
    l.remaining_quantity,
    (l.purchased_quantity - l.remaining_quantity)::int as consumed_quantity,
    l.unit_cost_cents,
    l.created_at,
    l.corrected_from_price_cents,
    l.corrected_at,
    l.note
  from public.product_purchase_lots l
  join public.products p on p.id = l.product_id
  where (p_product_id is null or l.product_id = p_product_id)
    and (coalesce(p_remaining_only, true) = false or l.remaining_quantity > 0)
  order by l.created_at desc, l.id desc;
end;
$function$;

create or replace function public.api_admin_list_purchase_lots(
  p_token text,
  p_product_id uuid default null::uuid,
  p_remaining_only boolean default true
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
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_purchase_lots(p_product_id, p_remaining_only);
end;
$function$;

create or replace function public.bootstrap_legacy_purchase_lots(
  p_product_id uuid default null::uuid
)
returns void
language plpgsql
security definer
as $function$
declare
  v_target_id uuid;
  v_product record;
  v_stock record;
  v_consumed_qty integer;
  v_initial_qty integer;
  v_initial_cost integer;
  v_initial_lot_id uuid;
  v_event record;
  v_delta integer;
  v_tx_cost integer;
begin
  if p_product_id is null then
    for v_target_id in
      select p.id
      from public.products p
      order by p.created_at asc, p.id asc
    loop
      perform public.bootstrap_legacy_purchase_lots(v_target_id);
    end loop;
    return;
  end if;

  delete from public.product_lot_allocations a
  where a.product_id = p_product_id;

  delete from public.product_purchase_lots l
  where l.product_id = p_product_id;

  select
    p.id,
    p.name,
    coalesce(p.last_purchase_price_cents, 0) as last_purchase_price_cents
  into v_product
  from public.products p
  where p.id = p_product_id
  for update;

  if not found then
    return;
  end if;

  select warehouse_qty, fridge_qty, total_qty
  into v_stock
  from public.get_product_stock(p_product_id);

  select coalesce(sum(consumed_qty), 0)::int
  into v_consumed_qty
  from (
    select
      case
        when im.reason = 'sale' then im.quantity
        when im.reason = 'sale_cancel' then -im.quantity
        when im.reason in ('shrinkage', 'waste') then im.quantity
        when im.reason = 'count_adjustment' and im.from_location_id is not null and im.to_location_id is null then im.quantity
        else 0
      end as consumed_qty
    from public.inventory_movements im
    where im.product_id = p_product_id
  ) x;

  v_initial_qty := greatest(0, coalesce(v_stock.total_qty, 0) + coalesce(v_consumed_qty, 0));
  v_initial_cost := greatest(0, coalesce(v_product.last_purchase_price_cents, 0));

  if v_initial_qty > 0 then
    insert into public.product_purchase_lots (
      product_id,
      inventory_movement_id,
      source_reason,
      purchased_quantity,
      remaining_quantity,
      unit_cost_cents,
      note,
      created_at
    ) values (
      p_product_id,
      null,
      'migration_initial',
      v_initial_qty,
      v_initial_qty,
      v_initial_cost,
      'Initiales Migrations-Lot fuer Altverkaeufe und Altbestand',
      coalesce((select min(im.created_at) from public.inventory_movements im where im.product_id = p_product_id), now())
    )
    returning id into v_initial_lot_id;
  else
    v_initial_lot_id := null;
  end if;

  for v_event in
    select
      im.id,
      im.reason,
      im.quantity,
      im.transaction_id,
      im.from_location_id,
      im.to_location_id,
      (
        case
          when (im.meta ->> 'canceled_tx_id') ~* '^[0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12}$'
            then (im.meta ->> 'canceled_tx_id')::uuid
          else null
        end
      ) as canceled_tx_id
    from public.inventory_movements im
    where im.product_id = p_product_id
      and im.reason in ('sale', 'sale_cancel', 'count_adjustment', 'shrinkage', 'waste')
    order by im.created_at asc, im.id asc
  loop
    if v_initial_lot_id is null then
      exit;
    end if;

    v_delta := (
      case when v_event.to_location_id is not null then v_event.quantity else 0 end
      -
      case when v_event.from_location_id is not null then v_event.quantity else 0 end
    );

    if v_event.reason = 'sale' then
      update public.product_purchase_lots l
      set remaining_quantity = greatest(0, l.remaining_quantity - v_event.quantity)
      where l.id = v_initial_lot_id;

      insert into public.product_lot_allocations (
        purchase_lot_id,
        product_id,
        inventory_movement_id,
        source_transaction_id,
        reason,
        quantity,
        unit_cost_cents,
        created_at
      ) values (
        v_initial_lot_id,
        p_product_id,
        v_event.id,
        v_event.transaction_id,
        'sale',
        v_event.quantity,
        v_initial_cost,
        coalesce((select im.created_at from public.inventory_movements im where im.id = v_event.id), now())
      );

      v_tx_cost := v_event.quantity * v_initial_cost;

      update public.transactions t
      set product_cost_snapshot_cents = v_tx_cost
      where t.id = v_event.transaction_id;

      update public.inventory_movements im
      set purchase_price_snapshot_cents = v_initial_cost
      where im.id = v_event.id;
    elsif v_event.reason = 'sale_cancel' and v_event.canceled_tx_id is not null then
      update public.product_purchase_lots l
      set remaining_quantity = least(l.purchased_quantity, l.remaining_quantity + v_event.quantity)
      where l.id = v_initial_lot_id;

      update public.product_lot_allocations a
      set
        reversed_at = coalesce(a.reversed_at, now()),
        reversal_inventory_movement_id = v_event.id,
        reversal_reason = 'sale_cancel'
      where a.purchase_lot_id = v_initial_lot_id
        and a.source_transaction_id = v_event.canceled_tx_id
        and a.reason = 'sale'
        and a.reversed_at is null;

      update public.storno_log s
      set product_cost_snapshot_cents = v_event.quantity * v_initial_cost
      where s.original_transaction_id = v_event.canceled_tx_id
        and s.product_id = p_product_id;

      update public.inventory_movements im
      set purchase_price_snapshot_cents = v_initial_cost
      where im.id = v_event.id;
    elsif v_event.reason in ('count_adjustment', 'shrinkage', 'waste') and v_delta < 0 then
      update public.product_purchase_lots l
      set remaining_quantity = greatest(0, l.remaining_quantity - abs(v_delta))
      where l.id = v_initial_lot_id;

      insert into public.product_lot_allocations (
        purchase_lot_id,
        product_id,
        inventory_movement_id,
        source_transaction_id,
        reason,
        quantity,
        unit_cost_cents,
        created_at
      ) values (
        v_initial_lot_id,
        p_product_id,
        v_event.id,
        null,
        v_event.reason,
        abs(v_delta),
        v_initial_cost,
        coalesce((select im.created_at from public.inventory_movements im where im.id = v_event.id), now())
      );

      update public.inventory_movements im
      set purchase_price_snapshot_cents = v_initial_cost
      where im.id = v_event.id;
    end if;
  end loop;

  if v_initial_lot_id is not null then
    update public.product_purchase_lots l
    set remaining_quantity = greatest(0, least(l.purchased_quantity, coalesce(v_stock.total_qty, 0)))
    where l.id = v_initial_lot_id;
  end if;

  perform public.refresh_product_inventory_value_from_lots(p_product_id);
end;
$function$;

create or replace function public.admin_update_purchase_lot_cost(
  p_lot_id uuid,
  p_unit_cost_cents integer,
  p_note text default null
)
returns public.product_purchase_lots
language plpgsql
security definer
as $function$
declare
  v_lot public.product_purchase_lots;
begin
  perform public.assert_admin();

  select *
  into v_lot
  from public.product_purchase_lots l
  where l.id = p_lot_id
  for update;

  if not found then
    raise exception 'Lot nicht gefunden';
  end if;

  update public.product_purchase_lots l
  set
    corrected_from_price_cents = case
      when coalesce(l.corrected_from_price_cents, 0) = 0 and l.unit_cost_cents <> greatest(0, coalesce(p_unit_cost_cents, 0))
        then l.unit_cost_cents
      else l.corrected_from_price_cents
    end,
    unit_cost_cents = greatest(0, coalesce(p_unit_cost_cents, 0)),
    corrected_at = case
      when l.unit_cost_cents <> greatest(0, coalesce(p_unit_cost_cents, 0)) then now()
      else l.corrected_at
    end,
    corrected_by = case
      when l.unit_cost_cents <> greatest(0, coalesce(p_unit_cost_cents, 0)) then public.app_current_user_id()
      else l.corrected_by
    end,
    note = coalesce(p_note, l.note)
  where l.id = p_lot_id
  returning * into v_lot;

  if v_lot.inventory_movement_id is not null then
    update public.inventory_movements im
    set purchase_price_snapshot_cents = v_lot.unit_cost_cents
    where im.id = v_lot.inventory_movement_id
      and im.reason in ('purchase', 'opening_balance', 'count_adjustment');
  end if;

  update public.product_lot_allocations a
  set unit_cost_cents = v_lot.unit_cost_cents
  where a.purchase_lot_id = v_lot.id
    and v_lot.source_reason = 'migration_initial';

  if v_lot.source_reason = 'migration_initial' then
    update public.transactions t
    set product_cost_snapshot_cents = alloc.total_cost
    from (
      select
        a.source_transaction_id as transaction_id,
        sum(a.quantity * a.unit_cost_cents)::int as total_cost
      from public.product_lot_allocations a
      where a.purchase_lot_id = v_lot.id
        and a.source_transaction_id is not null
      group by a.source_transaction_id
    ) alloc
    where t.id = alloc.transaction_id;

    update public.inventory_movements im
    set purchase_price_snapshot_cents = alloc.unit_cost
    from (
      select
        a.inventory_movement_id,
        max(a.unit_cost_cents)::int as unit_cost
      from public.product_lot_allocations a
      where a.purchase_lot_id = v_lot.id
        and a.inventory_movement_id is not null
      group by a.inventory_movement_id
    ) alloc
    where im.id = alloc.inventory_movement_id;

    update public.storno_log s
    set product_cost_snapshot_cents = alloc.total_cost
    from (
      select
        a.source_transaction_id as transaction_id,
        sum(a.quantity * a.unit_cost_cents)::int as total_cost
      from public.product_lot_allocations a
      where a.purchase_lot_id = v_lot.id
        and a.source_transaction_id is not null
        and a.reversed_at is not null
      group by a.source_transaction_id
    ) alloc
    where s.original_transaction_id = alloc.transaction_id;
  end if;

  perform public.refresh_product_inventory_value_from_lots(v_lot.product_id);
  return v_lot;
end;
$function$;

create or replace function public.api_admin_update_purchase_lot_cost(
  p_token text,
  p_lot_id uuid,
  p_unit_cost_cents integer,
  p_note text default null
)
returns public.product_purchase_lots
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_update_purchase_lot_cost(p_lot_id, p_unit_cost_cents, p_note);
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

revoke all on function public.refresh_product_inventory_value_from_lots(uuid) from public;
revoke all on function public.create_purchase_lot(uuid, uuid, integer, integer, text, text) from public;
revoke all on function public.consume_purchase_lots(uuid, integer, text, uuid, uuid, integer) from public;
revoke all on function public.restore_purchase_lot_allocations(uuid, uuid, uuid) from public;
revoke all on function public.rebuild_purchase_lots(uuid) from public;
revoke all on function public.bootstrap_legacy_purchase_lots(uuid) from public;
revoke all on function public.admin_list_purchase_lots(uuid, boolean) from public;
revoke all on function public.api_admin_list_purchase_lots(text, uuid, boolean) from public;
revoke all on function public.admin_update_purchase_lot_cost(uuid, integer, text) from public;
revoke all on function public.api_admin_update_purchase_lot_cost(text, uuid, integer, text) from public;
revoke all on function public.admin_create_product(text, integer, integer, text, boolean, boolean, integer) from public;
revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean, integer) from public;
revoke all on function public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean, integer) from public;
revoke all on function public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean, integer) from public;

select public.bootstrap_legacy_purchase_lots(null);
notify pgrst, 'reload schema';
