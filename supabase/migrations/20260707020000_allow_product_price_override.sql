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

    v_price_snapshot := case
      when coalesce(free_amount, 0) <> 0 then abs(free_amount)
      else amt
    end;
    amt := -abs(v_price_snapshot);
    pid := product_id;
    note := nullif(trim(p_note), '');
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
      coalesce(note, 'Verkauf'),
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

revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid, text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.book_transaction(uuid, uuid, integer, text, uuid, text) to service_role';
  end if;
end
$$;