alter table public.products
  add column if not exists last_purchase_price_cents integer not null default 0,
  add column if not exists inventory_value_cents integer not null default 0;

alter table public.inventory_movements
  add column if not exists purchase_price_snapshot_cents integer null;

alter table public.transactions
  add column if not exists product_cost_snapshot_cents integer null;

alter table public.storno_log
  add column if not exists product_cost_snapshot_cents integer null;

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
  limit 1;

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
      and p.active = true;

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

drop function if exists public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone, integer, integer);
create or replace function public.admin_get_revenue_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_limit integer default null,
  p_offset integer default 0
)
returns table(
  event_type text,
  event_at timestamp with time zone,
  local_day date,
  transaction_created_at timestamp with time zone,
  member_id uuid,
  member_name text,
  product_id uuid,
  product_name text,
  product_category text,
  transaction_type text,
  amount integer,
  amount_abs integer,
  product_cost_snapshot_cents integer,
  cost_amount_abs integer,
  is_free_amount boolean,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  with tx as (
    select
      'booking'::text as event_type,
      t.created_at as event_at,
      (t.created_at at time zone 'Europe/Berlin')::date as local_day,
      t.created_at as transaction_created_at,
      t.member_id,
      (
        coalesce(
          nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
          nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
          t.member_name_snapshot,
          'Unbekanntes Mitglied'
        )
        || case when coalesce(m.is_guest, ma.is_guest, false) then ' (Gast)' else '' end
      ) as member_name,
      t.product_id,
      coalesce(
        p.name,
        pa.name,
        t.product_name_snapshot,
        case when t.product_id is null then 'Freier Betrag' else 'Unbekanntes Produkt' end
      ) as product_name,
      coalesce(
        p.category,
        pa.category,
        case when t.product_id is null then 'Freier Betrag' else 'Unbekannt' end
      ) as product_category,
      coalesce(t.transaction_type, case when t.product_id is null then 'sale_free_amount' else 'sale_product' end) as transaction_type,
      t.amount,
      abs(t.amount)::int as amount_abs,
      coalesce(t.product_cost_snapshot_cents, 0)::int as product_cost_snapshot_cents,
      coalesce(t.product_cost_snapshot_cents, 0)::int as cost_amount_abs,
      (t.product_id is null) as is_free_amount,
      t.note
    from public.transactions t
    left join public.members m on m.id = t.member_id
    left join public.members_archive ma on ma.id = t.member_id
    left join public.products p on p.id = t.product_id
    left join public.products_archive pa on pa.id = t.product_id
    where t.created_at >= p_start
      and t.created_at < p_end
      and t.amount <> 0
  ),
  sl as (
    select
      'cancellation'::text as event_type,
      s.canceled_at as event_at,
      (s.canceled_at at time zone 'Europe/Berlin')::date as local_day,
      s.transaction_created_at,
      s.member_id,
      (
        coalesce(
          nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
          nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
          'Unbekanntes Mitglied'
        )
        || case when coalesce(m.is_guest, ma.is_guest, false) then ' (Gast)' else '' end
      ) as member_name,
      s.product_id,
      coalesce(
        p.name,
        pa.name,
        case when s.product_id is null then 'Freier Betrag' else 'Unbekanntes Produkt' end
      ) as product_name,
      coalesce(
        p.category,
        pa.category,
        case when s.product_id is null then 'Freier Betrag' else 'Unbekannt' end
      ) as product_category,
      coalesce(s.transaction_type, case when s.product_id is null then 'sale_free_amount' else 'sale_product' end) as transaction_type,
      s.amount,
      abs(s.amount)::int as amount_abs,
      coalesce(s.product_cost_snapshot_cents, 0)::int as product_cost_snapshot_cents,
      coalesce(s.product_cost_snapshot_cents, 0)::int as cost_amount_abs,
      (s.product_id is null) as is_free_amount,
      s.note
    from public.storno_log s
    left join public.members m on m.id = s.member_id
    left join public.members_archive ma on ma.id = s.member_id
    left join public.products p on p.id = s.product_id
    left join public.products_archive pa on pa.id = s.product_id
    where s.canceled_at >= p_start
      and s.canceled_at < p_end
      and s.amount <> 0
  )
  select * from (
    select * from tx
    union all
    select * from sl
  ) u
  order by u.event_at desc, u.event_type asc
  limit coalesce(p_limit, 2147483647)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$function$;

drop function if exists public.api_admin_get_revenue_report_period(text, timestamp with time zone, timestamp with time zone, integer, integer);
create or replace function public.api_admin_get_revenue_report_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_limit integer default null,
  p_offset integer default 0
)
returns table(
  event_type text,
  event_at timestamp with time zone,
  local_day date,
  transaction_created_at timestamp with time zone,
  member_id uuid,
  member_name text,
  product_id uuid,
  product_name text,
  product_category text,
  transaction_type text,
  amount integer,
  amount_abs integer,
  product_cost_snapshot_cents integer,
  cost_amount_abs integer,
  is_free_amount boolean,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_revenue_report_period(p_start, p_end, p_limit, p_offset);
end;
$function$;

drop function if exists public.admin_list_products();
create or replace function public.admin_list_products()
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    p.id,
    p.name,
    p.price,
    p.guest_price,
    p.category,
    p.active,
    p.inventoried,
    p.created_at,
    p.warehouse_stock,
    p.fridge_stock,
    p.last_restocked_at,
    p.last_purchase_price_cents,
    p.inventory_value_cents
  from public.products p
  order by p.active desc, p.name asc;
end;
$function$;

drop function if exists public.api_admin_list_products(text);
create or replace function public.api_admin_list_products(p_token text)
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select
    p.id,
    p.name,
    p.price,
    p.guest_price,
    p.category,
    p.active,
    p.inventoried,
    p.created_at,
    p.warehouse_stock,
    p.fridge_stock,
    p.last_restocked_at,
    p.last_purchase_price_cents,
    p.inventory_value_cents
  from public.admin_list_products() p;
end;
$function$;

create or replace function public.api_admin_add_storage(
  p_token text,
  p_product_id uuid,
  p_amount integer,
  p_purchase_price_cents integer default null
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  perform public.add_storage(p_product_id, p_amount, p_purchase_price_cents);
end;
$function$;

create or replace function public.apply_product_cost_baseline(
  p_product_id uuid default null::uuid
)
returns void
language plpgsql
security definer
as $function$
begin
  update public.products p
  set last_purchase_price_cents = latest.price
  from (
    select distinct on (im.product_id)
      im.product_id,
      im.purchase_price_snapshot_cents as price
    from public.inventory_movements im
    where im.reason = 'purchase'
      and coalesce(im.purchase_price_snapshot_cents, 0) > 0
      and (p_product_id is null or im.product_id = p_product_id)
    order by im.product_id, im.created_at desc, im.id desc
  ) latest
  where p.id = latest.product_id
    and (p_product_id is null or p.id = p_product_id)
    and coalesce(p.last_purchase_price_cents, 0) = 0;

  update public.inventory_movements im
  set purchase_price_snapshot_cents = p.last_purchase_price_cents
  from public.products p
  where p.id = im.product_id
    and im.reason = 'purchase'
    and im.purchase_price_snapshot_cents is null
    and coalesce(p.last_purchase_price_cents, 0) > 0
    and (p_product_id is null or im.product_id = p_product_id);

  with tx_costs as (
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
    where t.product_id is not null
      and coalesce(t.product_cost_snapshot_cents, 0) = 0
      and (p_product_id is null or t.product_id = p_product_id)
  )
  update public.transactions t
  set product_cost_snapshot_cents = c.cost
  from tx_costs c
  where t.id = c.id
    and c.cost > 0;

  with storno_costs as (
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
    where s.product_id is not null
      and coalesce(s.product_cost_snapshot_cents, 0) = 0
      and (p_product_id is null or s.product_id = p_product_id)
  )
  update public.storno_log s
  set product_cost_snapshot_cents = c.cost
  from storno_costs c
  where s.id = c.id
    and c.cost > 0;

  update public.inventory_movements im
  set purchase_price_snapshot_cents = t.product_cost_snapshot_cents
  from public.transactions t
  where im.reason = 'sale'
    and im.transaction_id = t.id
    and im.product_id = t.product_id
    and coalesce(im.purchase_price_snapshot_cents, 0) = 0
    and coalesce(t.product_cost_snapshot_cents, 0) > 0
    and (p_product_id is null or im.product_id = p_product_id);

  update public.inventory_movements im
  set purchase_price_snapshot_cents = s.product_cost_snapshot_cents
  from public.storno_log s
  where im.reason = 'sale_cancel'
    and (im.meta ->> 'canceled_tx_id') ~* '^[0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12}$'
    and (im.meta ->> 'canceled_tx_id')::uuid = s.original_transaction_id
    and im.product_id = s.product_id
    and coalesce(im.purchase_price_snapshot_cents, 0) = 0
    and coalesce(s.product_cost_snapshot_cents, 0) > 0
    and (p_product_id is null or im.product_id = p_product_id);

  update public.products p
  set inventory_value_cents =
    (greatest(0, coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0)) * coalesce(p.last_purchase_price_cents, 0))
  where (p_product_id is null or p.id = p_product_id)
    and greatest(0, coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0)) > 0
    and coalesce(p.last_purchase_price_cents, 0) > 0
    and coalesce(p.inventory_value_cents, 0) = 0;
end;
$function$;

drop function if exists public.admin_create_product(text, integer, integer, text, boolean, boolean);
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

  perform public.apply_product_cost_baseline(v_row.id);
  return v_row;
end;
$function$;

drop function if exists public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean);
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

  perform public.apply_product_cost_baseline(v_row.id);
  return v_row;
end;
$function$;

drop function if exists public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean);
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

drop function if exists public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean);
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
revoke all on function public.api_admin_add_storage(text, uuid, integer, integer) from public;

select public.apply_product_cost_baseline(null);

notify pgrst, 'reload schema';
