-- Remove synthetic historical lots that were accidentally created for products
-- that are currently configured as non-inventoried. The transactions keep their
-- cost snapshots, but must no longer be treated as lot/FIFO backed.

do $$
declare
  r record;
begin
  create temporary table tmp_non_inventory_migration_lots (
    lot_id uuid primary key,
    product_id uuid not null
  ) on commit drop;

  create temporary table tmp_non_inventory_migration_transactions (
    transaction_id uuid primary key
  ) on commit drop;

  insert into tmp_non_inventory_migration_lots (lot_id, product_id)
  select l.id, l.product_id
  from public.product_purchase_lots l
  join public.products p on p.id = l.product_id
  where p.inventoried = false
    and l.source_reason = 'migration_initial'
    and l.inventory_movement_id is null
    and l.note = 'Historisches Migrations-Lot fuer Altbuchungen ohne Lagerbewegung';

  insert into tmp_non_inventory_migration_transactions (transaction_id)
  select distinct a.source_transaction_id
  from public.product_lot_allocations a
  join tmp_non_inventory_migration_lots target on target.lot_id = a.purchase_lot_id
  where a.source_transaction_id is not null;

  delete from public.product_lot_allocations a
  using tmp_non_inventory_migration_lots target
  where a.purchase_lot_id = target.lot_id;

  delete from public.product_purchase_lots l
  using tmp_non_inventory_migration_lots target
  where l.id = target.lot_id;

  update public.transactions t
  set product_inventoried_snapshot = false
  from tmp_non_inventory_migration_transactions target
  where t.id = target.transaction_id
    and t.product_inventoried_snapshot is distinct from false;

  for r in
    select distinct product_id
    from tmp_non_inventory_migration_lots
  loop
    perform public.refresh_product_inventory_value_from_lots(r.product_id);
  end loop;
end;
$$;

notify pgrst, 'reload schema';
