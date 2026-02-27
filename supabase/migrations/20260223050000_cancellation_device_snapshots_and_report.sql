-- Add device snapshots for cancellations and expose device in cancellation report.
alter table public.storno_log
  add column if not exists device_id uuid null,
  add column if not exists device_id_snapshot uuid null;

create index if not exists storno_log_device_id_idx
  on public.storno_log (device_id);

alter table public.storno_log
  drop constraint if exists storno_log_device_id_fkey;

alter table public.storno_log
  add constraint storno_log_device_id_fkey
  foreign key (device_id)
  references public.kiosk_devices (id)
  on delete set null;

alter table public.inventory_movements
  add column if not exists device_id_snapshot uuid null;

with matched as (
  select
    s.id as storno_id,
    im.device_id
  from public.storno_log s
  left join lateral (
    select i.device_id
    from public.inventory_movements i
    where i.reason = 'sale_cancel'
      and (i.meta ->> 'canceled_tx_id') ~* '^[0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12}$'
      and (i.meta ->> 'canceled_tx_id')::uuid = s.original_transaction_id
    order by i.created_at desc
    limit 1
  ) im on true
  where s.device_id is null
    and s.original_transaction_id is not null
)
update public.storno_log s
set
  device_id = coalesce(s.device_id, m.device_id),
  device_id_snapshot = coalesce(s.device_id_snapshot, s.device_id, m.device_id)
from matched m
where s.id = m.storno_id;

update public.storno_log s
set device_id_snapshot = coalesce(s.device_id_snapshot, s.device_id)
where s.device_id is not null;

update public.inventory_movements im
set device_id_snapshot = im.device_id
where im.device_id_snapshot is null
  and im.device_id is not null;

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
    transaction_type,
    device_id,
    device_id_snapshot
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
    v_device_id
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
      device_id_snapshot,
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
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    );
  end if;

  return v_cancel_id;
end;
$function$;

grant execute on function public.cancel_transaction(uuid, uuid, uuid, text, uuid) to anon, authenticated;

drop function if exists public.admin_get_cancellations_report_period(timestamp with time zone, timestamp with time zone);
create or replace function public.admin_get_cancellations_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  canceled_at timestamp with time zone,
  local_day date,
  original_transaction_id uuid,
  transaction_created_at timestamp with time zone,
  member_id uuid,
  member_name text,
  product_id uuid,
  product_name text,
  device_name text,
  amount integer,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select
    sl.canceled_at,
    (sl.canceled_at at time zone 'Europe/Berlin')::date as local_day,
    sl.original_transaction_id,
    sl.transaction_created_at,
    sl.member_id,
    coalesce(
      nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
      'Unbekanntes Mitglied'
    ) ||
      case when coalesce(m.is_guest, false) then ' (Gast)' else '' end as member_name,
    sl.product_id,
    coalesce(p.name, 'Freier Betrag') as product_name,
    coalesce(kd.name, sl.device_id_snapshot::text, sl.device_id::text, '-') as device_name,
    sl.amount,
    sl.note
  from public.storno_log sl
  left join public.members m on m.id = sl.member_id
  left join public.products p on p.id = sl.product_id
  left join public.kiosk_devices kd on kd.id = sl.device_id
  where sl.canceled_at >= p_start
    and sl.canceled_at < p_end
  order by sl.canceled_at desc;
end;
$function$;

drop function if exists public.api_admin_get_cancellations_report_period(text, timestamp with time zone, timestamp with time zone);
create or replace function public.api_admin_get_cancellations_report_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  canceled_at timestamp with time zone,
  local_day date,
  original_transaction_id uuid,
  transaction_created_at timestamp with time zone,
  member_id uuid,
  member_name text,
  product_id uuid,
  product_name text,
  device_name text,
  amount integer,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_cancellations_report_period(p_start, p_end);
end;
$function$;
