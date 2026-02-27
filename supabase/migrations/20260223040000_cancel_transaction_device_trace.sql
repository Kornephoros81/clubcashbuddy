-- Add device trace + validation for cancellation flow.
drop function if exists public.cancel_transaction(uuid, uuid, uuid, text);
drop function if exists public.cancel_transaction(uuid, uuid, uuid, text, uuid);

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
    transaction_type
  ) values (
    v_tx.id,
    v_tx.member_id,
    v_tx.product_id,
    v_tx.created_at,
    v_canceled_at,
    v_tx.amount,
    v_tx.note,
    coalesce(v_tx.transaction_type, case when v_tx.product_id is null then 'sale_free_amount' else 'sale_product' end)
  );

  if v_tx.product_id is not null then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      device_id,
      meta
    ) values (
      v_tx.product_id,
      1,
      null,
      v_fr,
      'sale_cancel',
      'Storno Rueckbuchung',
      v_device_id,
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    );
  end if;

  return v_cancel_id;
end;
$function$;

grant execute on function public.cancel_transaction(uuid, uuid, uuid, text, uuid) to anon, authenticated;

