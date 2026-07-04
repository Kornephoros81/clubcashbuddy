-- Fallback lots represent one retrospectively priced bucket. When their EK is
-- changed, all allocations from that fallback lot must be repriced.

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
    cost_pending = case
      when v_lot.source_reason = 'sale_fallback' and v_lot.unit_cost_cents > 0 then false
      when v_lot.source_reason = 'migration_initial' then false
      when a.cost_pending = true or a.unit_cost_cents = 0 then false
      else a.cost_pending
    end
  where a.purchase_lot_id = v_lot.id
    and (
      v_lot.source_reason in ('migration_initial', 'sale_fallback')
      or a.cost_pending = true
      or a.unit_cost_cents = 0
    );

  update public.transactions t
  set product_cost_snapshot_cents = alloc.total_cost
  from (
    select
      a.source_transaction_id as transaction_id,
      sum(a.quantity * a.unit_cost_cents)::int as total_cost
    from public.product_lot_allocations a
    where a.source_transaction_id in (
      select affected.source_transaction_id
      from public.product_lot_allocations affected
      where affected.purchase_lot_id = v_lot.id
        and affected.source_transaction_id is not null
    )
    group by a.source_transaction_id
  ) alloc
  where t.id = alloc.transaction_id;

  update public.inventory_movements im
  set purchase_price_snapshot_cents = alloc.total_cost
  from (
    select
      a.inventory_movement_id,
      sum(a.quantity * a.unit_cost_cents)::int as total_cost
    from public.product_lot_allocations a
    where a.inventory_movement_id in (
      select affected.inventory_movement_id
      from public.product_lot_allocations affected
      where affected.purchase_lot_id = v_lot.id
        and affected.inventory_movement_id is not null
    )
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
    where a.source_transaction_id in (
      select affected.source_transaction_id
      from public.product_lot_allocations affected
      where affected.purchase_lot_id = v_lot.id
        and affected.source_transaction_id is not null
        and affected.reversed_at is not null
    )
    group by a.source_transaction_id
  ) alloc
  where s.original_transaction_id = alloc.transaction_id;

  perform public.refresh_product_inventory_value_from_lots(v_lot.product_id);
  return v_lot;
end;
$function$;

-- Repair fallback lots already changed before this migration: the lot EK is the
-- authoritative EK for all allocations assigned to that fallback lot.
update public.product_lot_allocations a
set
  unit_cost_cents = l.unit_cost_cents,
  cost_pending = case when l.unit_cost_cents > 0 then false else a.cost_pending end
from public.product_purchase_lots l
where a.purchase_lot_id = l.id
  and l.source_reason = 'sale_fallback'
  and (
    a.unit_cost_cents is distinct from l.unit_cost_cents
    or (l.unit_cost_cents > 0 and a.cost_pending = true)
  );

update public.product_purchase_lots l
set cost_pending = false
where l.source_reason = 'sale_fallback'
  and l.unit_cost_cents > 0
  and l.cost_pending = true;

update public.transactions t
set product_cost_snapshot_cents = alloc.total_cost
from (
  select
    a.source_transaction_id as transaction_id,
    sum(a.quantity * a.unit_cost_cents)::int as total_cost
  from public.product_lot_allocations a
  where a.source_transaction_id is not null
    and exists (
      select 1
      from public.product_purchase_lots l
      where l.id = a.purchase_lot_id
        and l.source_reason = 'sale_fallback'
    )
  group by a.source_transaction_id
) alloc
where t.id = alloc.transaction_id
  and t.product_cost_snapshot_cents is distinct from alloc.total_cost;

update public.inventory_movements im
set purchase_price_snapshot_cents = alloc.total_cost
from (
  select
    a.inventory_movement_id,
    sum(a.quantity * a.unit_cost_cents)::int as total_cost
  from public.product_lot_allocations a
  where a.inventory_movement_id is not null
    and exists (
      select 1
      from public.product_purchase_lots l
      where l.id = a.purchase_lot_id
        and l.source_reason = 'sale_fallback'
    )
  group by a.inventory_movement_id
) alloc
where im.id = alloc.inventory_movement_id
  and im.purchase_price_snapshot_cents is distinct from alloc.total_cost;

update public.storno_log s
set product_cost_snapshot_cents = alloc.total_cost
from (
  select
    a.source_transaction_id as transaction_id,
    sum(a.quantity * a.unit_cost_cents)::int as total_cost
  from public.product_lot_allocations a
  where a.source_transaction_id is not null
    and a.reversed_at is not null
    and exists (
      select 1
      from public.product_purchase_lots l
      where l.id = a.purchase_lot_id
        and l.source_reason = 'sale_fallback'
    )
  group by a.source_transaction_id
) alloc
where s.original_transaction_id = alloc.transaction_id
  and s.product_cost_snapshot_cents is distinct from alloc.total_cost;

revoke all on function public.admin_update_purchase_lot_cost(uuid, integer, text) from public;

notify pgrst, 'reload schema';
