-- Some very old product transactions predate the inventory movement ledger. The
-- original lot bootstrap can only allocate transactions that have a sale
-- movement, so these orphan transactions need synthetic fully-consumed lots.

do $$
declare
  r record;
  v_lot_id uuid;
begin
  for r in
    select
      t.product_id,
      greatest(0, coalesce(t.product_cost_snapshot_cents, p.last_purchase_price_cents, 0))::integer as unit_cost_cents,
      count(*)::integer as tx_count,
      min(t.created_at) as first_created_at,
      max(t.created_at) as last_created_at
    from public.transactions t
    join public.products p on p.id = t.product_id
    where t.product_id is not null
      and t.amount < 0
      and not exists (
        select 1
        from public.product_lot_allocations a
        where a.source_transaction_id = t.id
      )
    group by
      t.product_id,
      greatest(0, coalesce(t.product_cost_snapshot_cents, p.last_purchase_price_cents, 0))::integer
  loop
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
      r.product_id,
      null,
      'migration_initial',
      r.tx_count,
      0,
      r.unit_cost_cents,
      'Historisches Migrations-Lot fuer Altbuchungen ohne Lagerbewegung',
      coalesce(r.first_created_at, now()),
      coalesce(r.last_created_at, now()),
      r.unit_cost_cents = 0
    )
    returning id into v_lot_id;

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
    )
    select
      v_lot_id,
      t.product_id,
      null,
      t.id,
      'sale',
      1,
      r.unit_cost_cents,
      t.created_at,
      r.unit_cost_cents = 0
    from public.transactions t
    where t.product_id = r.product_id
      and t.amount < 0
      and greatest(0, coalesce(t.product_cost_snapshot_cents, r.unit_cost_cents, 0)) = r.unit_cost_cents
      and not exists (
        select 1
        from public.product_lot_allocations a
        where a.source_transaction_id = t.id
      );

    perform public.refresh_product_inventory_value_from_lots(r.product_id);
  end loop;
end;
$$;

notify pgrst, 'reload schema';
