-- Consolidate automatic fallback purchase lots and keep one open fallback lot per product.

alter table public.product_purchase_lots
  add column if not exists closed_at timestamp with time zone null,
  add column if not exists cost_pending boolean not null default false;

alter table public.product_lot_allocations
  add column if not exists cost_pending boolean not null default false;

alter table public.product_purchase_lots
  drop constraint if exists product_purchase_lots_source_reason_check;

alter table public.product_purchase_lots
  add constraint product_purchase_lots_source_reason_check
  check (source_reason in ('purchase', 'opening_balance', 'count_adjustment', 'manual', 'migration_initial', 'sale_fallback'));

create unique index if not exists product_purchase_lots_open_fallback_uq
  on public.product_purchase_lots(product_id)
  where source_reason = 'sale_fallback' and closed_at is null;

create index if not exists product_purchase_lots_closed_idx
  on public.product_purchase_lots(closed_at desc);

create index if not exists product_lot_allocations_cost_pending_idx
  on public.product_lot_allocations(purchase_lot_id)
  where cost_pending = true;

do $$
declare
  r record;
  v_new_lot_id uuid;
begin
  for r in
    with fallback_lots as (
      select l.*
      from public.product_purchase_lots l
      where l.source_reason = 'manual'
        and l.note = 'Automatisch erzeugter Fallback-Lot'
    ),
    grouped as (
      select
        l.product_id,
        sum(l.purchased_quantity)::integer as purchased_quantity,
        min(l.created_at) as first_created_at,
        max(l.created_at) as last_created_at,
        case
          when sum(l.purchased_quantity) > 0 then round(
            sum(l.purchased_quantity * l.unit_cost_cents)::numeric / sum(l.purchased_quantity)
          )::integer
          else 0
        end as unit_cost_cents,
        count(*)::integer as lot_count,
        bool_or(l.unit_cost_cents = 0 or l.cost_pending = true) as cost_pending
      from fallback_lots l
      group by l.product_id
    )
    select
      g.*,
      (
        select min(real_lot.created_at)
        from public.product_purchase_lots real_lot
        where real_lot.product_id = g.product_id
          and real_lot.source_reason in ('purchase', 'opening_balance', 'count_adjustment', 'migration_initial')
          and real_lot.created_at > g.last_created_at
      ) as closed_at
    from grouped g
  loop
    insert into public.product_purchase_lots (
      product_id,
      inventory_movement_id,
      source_reason,
      purchased_quantity,
      remaining_quantity,
      unit_cost_cents,
      note,
      corrected_from_price_cents,
      corrected_at,
      corrected_by,
      created_at,
      closed_at,
      cost_pending
    ) values (
      r.product_id,
      null,
      'sale_fallback',
      greatest(1, r.purchased_quantity),
      0,
      greatest(0, coalesce(r.unit_cost_cents, 0)),
      'Gebündeltes Fallback-Lot aus ' || r.lot_count::text || ' Einzel-Lots',
      null,
      null,
      null,
      r.first_created_at,
      r.closed_at,
      r.cost_pending
    )
    on conflict do nothing
    returning id into v_new_lot_id;

    if v_new_lot_id is null then
      select l.id
      into v_new_lot_id
      from public.product_purchase_lots l
      where l.product_id = r.product_id
        and l.source_reason = 'sale_fallback'
        and l.created_at = r.first_created_at
      limit 1;
    end if;

    if v_new_lot_id is not null then
      update public.product_lot_allocations a
      set
        purchase_lot_id = v_new_lot_id,
        cost_pending = (a.unit_cost_cents = 0)
      where a.purchase_lot_id in (
        select old_lot.id
        from public.product_purchase_lots old_lot
        where old_lot.product_id = r.product_id
          and old_lot.source_reason = 'manual'
          and old_lot.note = 'Automatisch erzeugter Fallback-Lot'
      );

      delete from public.product_purchase_lots old_lot
      where old_lot.product_id = r.product_id
        and old_lot.source_reason = 'manual'
        and old_lot.note = 'Automatisch erzeugter Fallback-Lot';
    end if;
  end loop;
end $$;

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
set search_path = public, extensions, pg_temp
as $function$
declare
  v_needed integer;
  v_total_cost integer;
  v_take integer;
  v_lot record;
  v_fallback_cost integer;
  v_fallback_lot public.product_purchase_lots%rowtype;
  v_created_at timestamp with time zone;
  v_cost_pending boolean;
begin
  v_needed := greatest(0, coalesce(p_quantity, 0));
  v_total_cost := 0;

  if v_needed = 0 then
    return 0;
  end if;

  v_created_at := coalesce(
    (select im.created_at from public.inventory_movements im where im.id = p_inventory_movement_id),
    now()
  );

  for v_lot in
    select
      l.id,
      l.remaining_quantity,
      l.unit_cost_cents
    from public.product_purchase_lots l
    where l.product_id = p_product_id
      and l.remaining_quantity > 0
      and l.source_reason <> 'sale_fallback'
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
      created_at,
      cost_pending
    ) values (
      v_lot.id,
      p_product_id,
      p_inventory_movement_id,
      p_transaction_id,
      p_reason,
      v_take,
      v_lot.unit_cost_cents,
      v_created_at,
      false
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

    if coalesce(p_reason, '') <> 'sale' and v_fallback_cost <= 0 then
      raise exception 'NO_PURCHASE_LOTS_AVAILABLE';
    end if;

    if coalesce(p_reason, '') <> 'sale' then
      insert into public.product_purchase_lots (
        product_id,
        inventory_movement_id,
        source_reason,
        purchased_quantity,
        remaining_quantity,
        unit_cost_cents,
        note,
        created_at,
        closed_at,
        cost_pending
      ) values (
        p_product_id,
        p_inventory_movement_id,
        'manual',
        v_needed,
        0,
        v_fallback_cost,
        'Automatisch erzeugter Fallback-Lot',
        v_created_at,
        v_created_at,
        false
      )
      returning * into v_fallback_lot;
    else
      v_cost_pending := v_fallback_cost <= 0;

      select *
      into v_fallback_lot
      from public.product_purchase_lots l
      where l.product_id = p_product_id
        and l.source_reason = 'sale_fallback'
        and l.closed_at is null
      for update;

      if not found then
        begin
          insert into public.product_purchase_lots (
            product_id,
            inventory_movement_id,
            source_reason,
            purchased_quantity,
            remaining_quantity,
            unit_cost_cents,
            note,
            created_at,
            closed_at,
            cost_pending
          ) values (
            p_product_id,
            null,
            'sale_fallback',
            v_needed,
            0,
            v_fallback_cost,
            case when v_cost_pending then 'Fallback-Lot ohne gepflegten EK' else 'Fallback-Lot aus letztem EK' end,
            v_created_at,
            null,
            v_cost_pending
          )
          returning * into v_fallback_lot;
        exception when unique_violation then
          select *
          into v_fallback_lot
          from public.product_purchase_lots l
          where l.product_id = p_product_id
            and l.source_reason = 'sale_fallback'
            and l.closed_at is null
          for update;

          update public.product_purchase_lots l
          set
            purchased_quantity = l.purchased_quantity + v_needed,
            cost_pending = l.cost_pending or v_cost_pending,
            note = case
              when l.cost_pending or v_cost_pending then 'Fallback-Lot ohne gepflegten EK'
              else l.note
            end
          where l.id = v_fallback_lot.id
          returning * into v_fallback_lot;
        end;
      else
        update public.product_purchase_lots l
        set
          purchased_quantity = l.purchased_quantity + v_needed,
          cost_pending = l.cost_pending or v_cost_pending,
          note = case
            when l.cost_pending or v_cost_pending then 'Fallback-Lot ohne gepflegten EK'
            else l.note
          end
        where l.id = v_fallback_lot.id
        returning * into v_fallback_lot;
      end if;
    end if;

    insert into public.product_lot_allocations (
      purchase_lot_id,
      product_id,
      inventory_movement_id,
      source_transaction_id,
      reason,
      quantity,
      unit_cost_cents,
      created_at,
      cost_pending
    ) values (
      v_fallback_lot.id,
      p_product_id,
      p_inventory_movement_id,
      p_transaction_id,
      p_reason,
      v_needed,
      v_fallback_lot.unit_cost_cents,
      v_created_at,
      v_fallback_lot.cost_pending or v_fallback_lot.unit_cost_cents = 0
    );

    v_total_cost := v_total_cost + (v_needed * v_fallback_lot.unit_cost_cents);
    v_needed := 0;
  end if;

  return v_total_cost;
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
set search_path = public, extensions, pg_temp
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

    update public.product_purchase_lots l
    set closed_at = now()
    where l.product_id = product_id
      and l.source_reason = 'sale_fallback'
      and l.closed_at is null;

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

create or replace function public.admin_update_purchase_lot_cost(
  p_lot_id uuid,
  p_unit_cost_cents integer,
  p_note text default null
)
returns public.product_purchase_lots
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_lot public.product_purchase_lots;
  v_new_cost integer;
begin
  perform public.assert_admin();

  v_new_cost := greatest(0, coalesce(p_unit_cost_cents, 0));

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
      when coalesce(l.corrected_from_price_cents, 0) = 0 and l.unit_cost_cents <> v_new_cost
        then l.unit_cost_cents
      else l.corrected_from_price_cents
    end,
    unit_cost_cents = v_new_cost,
    corrected_at = case
      when l.unit_cost_cents <> v_new_cost then now()
      else l.corrected_at
    end,
    corrected_by = case
      when l.unit_cost_cents <> v_new_cost then public.app_current_user_id()
      else l.corrected_by
    end,
    cost_pending = case when v_new_cost > 0 then false else l.cost_pending end,
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
  set
    unit_cost_cents = v_lot.unit_cost_cents,
    cost_pending = false
  where a.purchase_lot_id = v_lot.id
    and (
      v_lot.source_reason = 'migration_initial'
      or (
        v_lot.source_reason = 'sale_fallback'
        and (a.cost_pending = true or a.unit_cost_cents = 0)
      )
      or a.cost_pending = true
      or a.unit_cost_cents = 0
    );

  if v_lot.source_reason in ('migration_initial', 'sale_fallback') then
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
    where t.id = alloc.transaction_id
      and (coalesce(t.product_cost_snapshot_cents, 0) = 0 or v_lot.source_reason = 'migration_initial');

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
    where im.id = alloc.inventory_movement_id
      and (coalesce(im.purchase_price_snapshot_cents, 0) = 0 or v_lot.source_reason = 'migration_initial');

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
    where s.original_transaction_id = alloc.transaction_id
      and (coalesce(s.product_cost_snapshot_cents, 0) = 0 or v_lot.source_reason = 'migration_initial');
  end if;

  perform public.refresh_product_inventory_value_from_lots(v_lot.product_id);
  return v_lot;
end;
$function$;

drop function if exists public.admin_list_purchase_lots(uuid, boolean);
create or replace function public.admin_list_purchase_lots(
  p_product_id uuid default null::uuid,
  p_lot_state text default 'active'
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
  note text,
  closed_at timestamp with time zone,
  cost_pending boolean,
  pending_allocation_count integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_state text;
begin
  perform public.assert_admin();

  v_state := lower(coalesce(nullif(trim(p_lot_state), ''), 'active'));
  if v_state not in ('active', 'closed', 'all') then
    v_state := 'active';
  end if;

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
    l.note,
    l.closed_at,
    l.cost_pending,
    coalesce(pa.pending_allocation_count, 0)::integer
  from public.product_purchase_lots l
  join public.products p on p.id = l.product_id
  left join lateral (
    select count(*)::integer as pending_allocation_count
    from public.product_lot_allocations a
    where a.purchase_lot_id = l.id
      and a.cost_pending = true
  ) pa on true
  where (p_product_id is null or l.product_id = p_product_id)
    and (
      v_state = 'all'
      or (v_state = 'active' and l.closed_at is null and (l.remaining_quantity > 0 or l.source_reason = 'sale_fallback'))
      or (v_state = 'closed' and (l.closed_at is not null or (l.remaining_quantity = 0 and l.source_reason <> 'sale_fallback')))
    )
  order by coalesce(l.closed_at, l.created_at) desc, l.created_at desc, l.id desc;
end;
$function$;

drop function if exists public.api_admin_list_purchase_lots(text, uuid, boolean);
create or replace function public.api_admin_list_purchase_lots(
  p_token text,
  p_product_id uuid default null::uuid,
  p_lot_state text default 'active'
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
  note text,
  closed_at timestamp with time zone,
  cost_pending boolean,
  pending_allocation_count integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_purchase_lots(p_product_id, p_lot_state);
end;
$function$;

revoke all on function public.consume_purchase_lots(uuid, integer, text, uuid, uuid, integer) from public;
revoke all on function public.add_storage(uuid, integer, integer) from public;
revoke all on function public.admin_update_purchase_lot_cost(uuid, integer, text) from public;
revoke all on function public.admin_list_purchase_lots(uuid, text) from public;
revoke all on function public.api_admin_list_purchase_lots(text, uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_list_purchase_lots(text, uuid, text) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';
