-- Stornos hard-delete the original transaction. Revenue and gross profit reports
-- therefore use remaining transactions as authoritative revenue; storno_log is
-- audit/statistics data. Keep storno cost snapshots complete for those stats and
-- restore FIFO lots correctly on future cancellations.

alter table public.storno_log
  add column if not exists product_cost_snapshot_cents integer null;

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
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
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

do $$
declare
  r record;
  v_cost_snapshot integer;
begin
  for r in
    select
      s.id as storno_id,
      s.original_transaction_id,
      s.product_id,
      im.id as movement_id
    from public.storno_log s
    join public.inventory_movements im
      on im.product_id = s.product_id
      and im.reason = 'sale_cancel'
      and (im.meta ->> 'canceled_tx_id') ~* '^[0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12}$'
      and (im.meta ->> 'canceled_tx_id')::uuid = s.original_transaction_id
    where s.product_id is not null
      and not exists (
        select 1
        from public.product_lot_allocations a
        where a.source_transaction_id = s.original_transaction_id
          and a.reversed_at is not null
      )
  loop
    v_cost_snapshot := public.restore_purchase_lot_allocations(
      r.product_id,
      r.original_transaction_id,
      r.movement_id
    );

    update public.inventory_movements im
    set purchase_price_snapshot_cents = greatest(0, coalesce(v_cost_snapshot, 0))
    where im.id = r.movement_id
      and coalesce(im.purchase_price_snapshot_cents, 0) = 0;

    update public.storno_log s
    set product_cost_snapshot_cents = greatest(0, coalesce(v_cost_snapshot, 0))
    where s.id = r.storno_id
      and coalesce(s.product_cost_snapshot_cents, 0) = 0;

    perform public.refresh_product_inventory_value_from_lots(r.product_id);
  end loop;
end;
$$;

update public.storno_log s
set product_cost_snapshot_cents = alloc.total_cost
from (
  select
    a.source_transaction_id as transaction_id,
    sum(a.quantity * a.unit_cost_cents)::integer as total_cost
  from public.product_lot_allocations a
  where a.source_transaction_id is not null
    and a.reversed_at is not null
  group by a.source_transaction_id
) alloc
where s.original_transaction_id = alloc.transaction_id
  and coalesce(s.product_cost_snapshot_cents, 0) = 0
  and alloc.total_cost > 0;

update public.storno_log s
set product_cost_snapshot_cents = greatest(0, coalesce(p.last_purchase_price_cents, 0))
from public.products p
where p.id = s.product_id
  and coalesce(s.product_cost_snapshot_cents, 0) = 0
  and coalesce(p.last_purchase_price_cents, 0) > 0;

revoke all on function public.cancel_transaction(uuid, uuid, uuid, text, uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.cancel_transaction(uuid, uuid, uuid, text, uuid, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.cancel_transaction(uuid, uuid, uuid, text, uuid, text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.cancel_transaction(uuid, uuid, uuid, text, uuid, text) to service_role';
  end if;
end
$$;

notify pgrst, 'reload schema';
