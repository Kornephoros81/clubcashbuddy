alter table public.transactions
  add column if not exists sale_kind text not null default 'regular';

alter table public.transactions
  drop constraint if exists transactions_sale_kind_chk;

alter table public.transactions
  add constraint transactions_sale_kind_chk
  check (sale_kind in ('regular', 'mhd'));

alter table public.storno_log
  add column if not exists sale_kind text not null default 'regular';

alter table public.storno_log
  drop constraint if exists storno_log_sale_kind_chk;

alter table public.storno_log
  add constraint storno_log_sale_kind_chk
  check (sale_kind in ('regular', 'mhd'));

update public.transactions t
set sale_kind = 'mhd'
where t.product_id is not null
  and coalesce(t.sale_kind, 'regular') <> 'mhd'
  and coalesce(t.note, '') ilike '%MHD%';

update public.storno_log s
set sale_kind = 'mhd'
where s.product_id is not null
  and coalesce(s.sale_kind, 'regular') <> 'mhd'
  and coalesce(s.note, '') ilike '%MHD%';

create index if not exists transactions_sale_kind_created_idx
  on public.transactions (sale_kind, created_at desc);

create index if not exists storno_log_sale_kind_canceled_idx
  on public.storno_log (sale_kind, canceled_at desc);

drop function if exists public.book_transaction(uuid, uuid, integer, text, uuid, text);

create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid,
  p_transaction_type text default null::text,
  p_sale_kind text default 'regular'::text
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
  v_sale_kind text := 'regular';
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

    v_sale_kind := coalesce(nullif(trim(p_sale_kind), ''), 'regular');
    if v_sale_kind not in ('regular', 'mhd') then
      raise exception 'Ungueltiger sale_kind';
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

    v_sale_kind := 'regular';
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
    sale_kind,
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
    v_sale_kind,
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
      jsonb_build_object('source', 'book_transaction', 'sale_kind', v_sale_kind)
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

revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid, text, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid, text, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid, text, text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.book_transaction(uuid, uuid, integer, text, uuid, text, text) to service_role';
  end if;
end
$$;

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text,
  p_device_id uuid default null::uuid,
  p_client_cancel_id text default null::text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
  v_member_active boolean;
  v_canceled_at timestamp with time zone;
  v_device_id uuid;
  v_existing uuid;
  v_movement_id uuid;
  v_cost_snapshot integer := 0;
  v_restored_cost integer := 0;
  v_product_inventoried boolean := false;
  v_tx_inventoried boolean := false;
begin
  if p_client_cancel_id is not null then
    select sl.original_transaction_id into v_existing
    from public.storno_log sl
    where sl.client_cancel_id = p_client_cancel_id
    limit 1;
    if found then
      return v_existing;
    end if;
  end if;

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
    select coalesce(p.inventoried, true)
    into v_product_inventoried
    from public.products p
    where p.id = v_tx.product_id
    for update;

    v_tx_inventoried := coalesce(v_tx.product_inventoried_snapshot, v_product_inventoried, true);
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  v_canceled_at := now();
  v_cost_snapshot := coalesce(v_tx.product_cost_snapshot_cents, 0);

  if v_tx.product_id is not null and v_tx_inventoried = true then
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
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id, 'sale_kind', coalesce(v_tx.sale_kind, 'regular'))
    )
    returning id into v_movement_id;

    v_restored_cost := public.restore_purchase_lot_allocations(v_tx.product_id, v_tx.id, v_movement_id);
    v_cost_snapshot := coalesce(
      nullif(v_tx.product_cost_snapshot_cents, 0),
      v_restored_cost,
      0
    );
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
    sale_kind,
    device_id,
    device_id_snapshot,
    client_cancel_id,
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
    coalesce(v_tx.sale_kind, 'regular'),
    v_device_id,
    v_device_id,
    p_client_cancel_id,
    greatest(0, coalesce(v_cost_snapshot, 0))
  );

  if v_movement_id is not null then
    update public.inventory_movements im
    set purchase_price_snapshot_cents = greatest(0, coalesce(v_cost_snapshot, 0))
    where im.id = v_movement_id;

    perform public.refresh_product_inventory_value_from_lots(v_tx.product_id);
  end if;

  return v_cancel_id;
end;
$function$;

create or replace function public.book_transactions_batch(
  p_items jsonb,
  p_device_id uuid default null::uuid
)
returns table(
  queue_id bigint,
  client_tx_id_param text,
  success boolean,
  data uuid,
  error text
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_item jsonb;
  v_tx_id uuid;
  v_queue_id bigint;
  v_client_tx_id_text text;
  v_client_tx_id uuid;
  v_device_id uuid;
  v_count integer := 0;
begin
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception 'ITEMS_MUST_BE_ARRAY';
  end if;

  v_device_id := coalesce(p_device_id, public.app_current_device_id());

  for v_item in
    select value
    from jsonb_array_elements(p_items)
    limit 100
  loop
    v_count := v_count + 1;
    begin
      v_queue_id := nullif(v_item->>'queue_id', '')::bigint;
    exception when others then
      v_queue_id := null;
    end;
    v_client_tx_id_text := nullif(v_item->>'client_tx_id_param', '');
    queue_id := v_queue_id;
    client_tx_id_param := v_client_tx_id_text;
    success := false;
    data := null;
    error := null;

    begin
      v_client_tx_id := v_client_tx_id_text::uuid;

      v_tx_id := public.book_transaction(
        nullif(v_item->>'member_id', '')::uuid,
        nullif(v_item->>'product_id', '')::uuid,
        coalesce(nullif(v_item->>'free_amount', '')::integer, 0),
        nullif(v_item->>'p_note', ''),
        v_client_tx_id,
        nullif(v_item->>'p_transaction_type', ''),
        coalesce(nullif(v_item->>'p_sale_kind', ''), 'regular')
      );

      if v_device_id is not null then
        update public.transactions t
        set
          device_id = v_device_id,
          device_id_snapshot = v_device_id
        where t.id = v_tx_id
          and (t.device_id is null or t.device_id_snapshot is null);

        update public.inventory_movements im
        set
          device_id = v_device_id,
          device_id_snapshot = v_device_id
        where im.transaction_id = v_tx_id
          and im.reason = 'sale'
          and (im.device_id is null or im.device_id_snapshot is null);
      end if;

      success := true;
      data := v_tx_id;
      return next;
    exception when others then
      success := false;
      data := null;
      error := sqlerrm;
      return next;
    end;
  end loop;
end;
$function$;

create or replace function public.admin_get_product_activity_report(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_payload jsonb;
begin
  perform public.assert_admin();

  if p_start is null or p_end is null then
    raise exception 'start and end are required';
  end if;

  if p_end <= p_start then
    raise exception 'end must be after start';
  end if;

  with params as (
    select
      p_start as start_at,
      p_end as end_at,
      (p_start at time zone 'Europe/Berlin')::date as start_day,
      ((p_end - interval '1 millisecond') at time zone 'Europe/Berlin')::date as end_day
  ), days as (
    select gs::date as day
    from params p
    cross join generate_series(p.start_day, p.end_day, interval '1 day') gs
  ), product_scope as (
    select p.id, p.name, p.category, p.active, p.inventoried, coalesce(p.last_purchase_price_cents, 0)::integer as last_purchase_price_cents
    from public.products p
    where p.active = true
       or exists (
         select 1 from public.transactions t
         cross join params pa
         where t.product_id = p.id
           and t.created_at >= pa.start_at
           and t.created_at < pa.end_at
       )
       or exists (
         select 1 from public.inventory_movements im
         cross join params pa
         where im.product_id = p.id
           and im.created_at >= pa.start_at
           and im.created_at < pa.end_at
       )
  ), sales as (
    select
      t.product_id,
      count(*)::integer as sold_count,
      count(*) filter (where coalesce(t.sale_kind, 'regular') = 'mhd')::integer as mhd_count,
      coalesce(sum(abs(t.amount)), 0)::integer as revenue_cents,
      coalesce(sum(coalesce(t.product_cost_snapshot_cents, 0)), 0)::integer as goods_cost_cents
    from public.transactions t
    cross join params p
    where t.product_id is not null
      and t.created_at >= p.start_at
      and t.created_at < p.end_at
      and t.amount < 0
      and coalesce(t.transaction_type, 'sale_product') = 'sale_product'
    group by t.product_id
  ), current_stock as (
    select
      l.product_id,
      coalesce(sum(l.remaining_quantity), 0)::integer as current_stock,
      coalesce(sum(l.remaining_quantity * l.unit_cost_cents), 0)::integer as current_stock_value_cents
    from public.product_purchase_lots l
    where l.source_reason <> 'sale_fallback'
      and l.remaining_quantity > 0
    group by l.product_id
  ), movement_delta as (
    select
      im.product_id,
      (im.created_at at time zone 'Europe/Berlin')::date as day,
      sum(
        case when im.to_location_id is not null then im.quantity else 0 end
        - case when im.from_location_id is not null then im.quantity else 0 end
      )::integer as delta
    from public.inventory_movements im
    cross join params p
    where im.created_at >= p.start_at
      and im.created_at < p.end_at
    group by im.product_id, (im.created_at at time zone 'Europe/Berlin')::date
  ), period_delta as (
    select product_id, coalesce(sum(delta), 0)::integer as stock_delta_period
    from movement_delta
    group by product_id
  ), opening_stock as (
    select
      ps.id as product_id,
      coalesce(sum(
        case when im.to_location_id is not null then im.quantity else 0 end
        - case when im.from_location_id is not null then im.quantity else 0 end
      ), 0)::integer as opening_stock
    from product_scope ps
    cross join params p
    left join public.inventory_movements im
      on im.product_id = ps.id
     and im.created_at < p.start_at
    group by ps.id
  ), product_days as (
    select
      ps.id as product_id,
      d.day,
      os.opening_stock,
      coalesce(md.delta, 0)::integer as delta
    from product_scope ps
    cross join days d
    join opening_stock os on os.product_id = ps.id
    left join movement_delta md on md.product_id = ps.id and md.day = d.day
  ), stock_trend as (
    select
      product_id,
      day,
      (
        opening_stock
        + sum(delta) over (partition by product_id order by day rows between unbounded preceding and current row)
      )::integer as stock
    from product_days
  ), products_json as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product_id', ps.id,
        'name', ps.name,
        'category', coalesce(ps.category, 'Allgemein'),
        'active', ps.active,
        'inventoried', ps.inventoried,
        'sold_count', coalesce(s.sold_count, 0),
        'mhd_count', coalesce(s.mhd_count, 0),
        'mhd_share_percent', case when coalesce(s.sold_count, 0) > 0 then round((coalesce(s.mhd_count, 0)::numeric / s.sold_count::numeric) * 100, 1) else 0 end,
        'revenue_cents', coalesce(s.revenue_cents, 0),
        'goods_cost_cents', coalesce(s.goods_cost_cents, 0),
        'gross_profit_cents', coalesce(s.revenue_cents, 0) - coalesce(s.goods_cost_cents, 0),
        'current_stock', coalesce(cs.current_stock, 0),
        'current_stock_value_cents', coalesce(cs.current_stock_value_cents, 0),
        'stock_delta_period', coalesce(pd.stock_delta_period, 0),
        'last_purchase_price_cents', ps.last_purchase_price_cents
      ) order by coalesce(s.sold_count, 0) desc, ps.name asc
    ), '[]'::jsonb) as data
    from product_scope ps
    left join sales s on s.product_id = ps.id
    left join current_stock cs on cs.product_id = ps.id
    left join period_delta pd on pd.product_id = ps.id
  ), stock_trend_json as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product_id', st.product_id,
        'day', st.day,
        'stock', st.stock
      ) order by st.day asc, st.product_id
    ), '[]'::jsonb) as data
    from stock_trend st
  ), metrics as (
    select
      coalesce(sum(s.sold_count), 0)::integer as total_sold_count,
      coalesce(sum(s.mhd_count), 0)::integer as total_mhd_count,
      coalesce(sum(s.revenue_cents), 0)::integer as total_revenue_cents,
      coalesce(sum(s.goods_cost_cents), 0)::integer as total_goods_cost_cents,
      coalesce(sum(s.revenue_cents) - sum(s.goods_cost_cents), 0)::integer as total_gross_profit_cents,
      count(*) filter (where coalesce(s.sold_count, 0) > 0)::integer as sold_products_count,
      coalesce(sum(cs.current_stock), 0)::integer as current_stock_units,
      coalesce(sum(cs.current_stock_value_cents), 0)::integer as current_stock_value_cents
    from product_scope ps
    left join sales s on s.product_id = ps.id
    left join current_stock cs on cs.product_id = ps.id
  )
  select jsonb_build_object(
    'metrics', jsonb_build_object(
      'totalSoldCount', m.total_sold_count,
      'totalMhdCount', m.total_mhd_count,
      'mhdSharePercent', case when m.total_sold_count > 0 then round((m.total_mhd_count::numeric / m.total_sold_count::numeric) * 100, 1) else 0 end,
      'totalRevenueCents', m.total_revenue_cents,
      'totalGoodsCostCents', m.total_goods_cost_cents,
      'totalGrossProfitCents', m.total_gross_profit_cents,
      'grossMarginPercent', case when m.total_revenue_cents > 0 then round((m.total_gross_profit_cents::numeric / m.total_revenue_cents::numeric) * 100, 1) else 0 end,
      'soldProductsCount', m.sold_products_count,
      'currentStockUnits', m.current_stock_units,
      'currentStockValueCents', m.current_stock_value_cents
    ),
    'products', pj.data,
    'stockTrend', stj.data
  )
  into v_payload
  from metrics m
  cross join products_json pj
  cross join stock_trend_json stj;

  return coalesce(v_payload, jsonb_build_object('metrics', jsonb_build_object(), 'products', '[]'::jsonb, 'stockTrend', '[]'::jsonb));
end;
$function$;

notify pgrst, 'reload schema';