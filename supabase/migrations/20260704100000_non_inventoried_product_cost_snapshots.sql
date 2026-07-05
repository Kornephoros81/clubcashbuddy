-- Non-inventoried products do not create inventory movements or lot
-- allocations. They still need a cost snapshot for revenue/gross-profit
-- reports, using the product's maintained EK at booking time.

alter table public.transactions
  add column if not exists product_inventoried_snapshot boolean null;

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
set search_path = public, extensions, pg_temp
as $function$
declare
  v_current public.products;
  v_row public.products;
  v_stock record;
  v_lot record;
  v_next_inventoried boolean;
begin
  perform public.assert_admin();

  select *
  into v_current
  from public.products p
  where p.id = p_id
  for update;

  if not found then
    raise exception 'Produkt nicht gefunden';
  end if;

  v_next_inventoried := coalesce(p_inventoried, v_current.inventoried);

  if v_current.inventoried = true and v_next_inventoried = false then
    select *
    into v_stock
    from public.get_product_stock(p_id);

    if coalesce(v_stock.total_qty, 0) <> 0 then
      raise exception 'Artikel kann nur auf nicht inventarisiert umgestellt werden, wenn der Bestand 0 ist.';
    end if;
  end if;

  update public.products p
  set
    name = coalesce(p_name, p.name),
    price = coalesce(p_price, p.price),
    guest_price = coalesce(p_guest_price, p.guest_price),
    category = coalesce(p_category, p.category),
    active = coalesce(p_active, p.active),
    inventoried = v_next_inventoried,
    last_purchase_price_cents = coalesce(greatest(0, p_last_purchase_price_cents), p.last_purchase_price_cents)
  where p.id = p_id
  returning * into v_row;

  if p_last_purchase_price_cents is not null and greatest(0, p_last_purchase_price_cents) > 0 then
    if v_next_inventoried = true then
      for v_lot in
        select l.id, l.note
        from public.product_purchase_lots l
        where l.product_id = p_id
          and (
            coalesce(l.unit_cost_cents, 0) = 0
            or coalesce(l.cost_pending, false) = true
          )
        order by l.created_at asc, l.id asc
      loop
        perform public.admin_update_purchase_lot_cost(
          v_lot.id,
          greatest(0, p_last_purchase_price_cents),
          v_lot.note
        );
      end loop;
    end if;

    update public.transactions t
    set
      product_cost_snapshot_cents = greatest(0, p_last_purchase_price_cents),
      product_inventoried_snapshot = coalesce(t.product_inventoried_snapshot, false)
    where t.product_id = p_id
      and t.amount < 0
      and coalesce(t.product_cost_snapshot_cents, 0) = 0
      and (v_next_inventoried = false or t.product_inventoried_snapshot = false)
      and not exists (
        select 1
        from public.product_lot_allocations a
        where a.source_transaction_id = t.id
      );
  end if;

  return v_row;
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
set search_path = public, extensions, pg_temp
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
  v_cost_snapshot integer := 0;
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
      p.name,
      greatest(0, coalesce(p.last_purchase_price_cents, 0))
    into amt, v_inventoried, v_product_name, v_cost_snapshot
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
    product_inventoried_snapshot,
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
    case when pid is not null and coalesce(v_inventoried, true) = false then v_cost_snapshot else 0 end,
    case when pid is not null then coalesce(v_inventoried, true) else null end,
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

update public.transactions t
set product_cost_snapshot_cents = greatest(0, coalesce(p.last_purchase_price_cents, 0))
from public.products p
where p.id = t.product_id
  and p.inventoried = false
  and t.amount < 0
  and coalesce(t.product_cost_snapshot_cents, 0) = 0
  and not exists (
    select 1
    from public.product_lot_allocations a
    where a.source_transaction_id = t.id
  );

update public.transactions t
set product_inventoried_snapshot = true
where t.product_id is not null
  and t.amount < 0
  and exists (
    select 1
    from public.product_lot_allocations a
    where a.source_transaction_id = t.id
  )
  and t.product_inventoried_snapshot is null;

update public.transactions t
set product_inventoried_snapshot = false
from public.products p
where p.id = t.product_id
  and p.inventoried = false
  and t.amount < 0
  and not exists (
    select 1
    from public.product_lot_allocations a
    where a.source_transaction_id = t.id
  )
  and t.product_inventoried_snapshot is null;

revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean, integer) from public;
revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid, text) from public;

notify pgrst, 'reload schema';
