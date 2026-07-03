-- 1) Regression der Härtung aus 20260215020000 zurücknehmen:
--    book_transaction/cancel_transaction sind SECURITY DEFINER ohne eigene
--    Session-Prüfung und dürfen nur vom Backend (service_role) aufgerufen werden.
--    Spätere Migrationen (20260217000000, 20260223020000/040000/050000) hatten
--    sie wieder für anon/authenticated freigegeben.
do $$
begin
  begin
    execute 'revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid, text) from public, anon, authenticated';
  exception when undefined_function or undefined_object then
    null;
  end;
  begin
    execute 'revoke all on function public.cancel_transaction(uuid, uuid, uuid, text, uuid) from public, anon, authenticated';
  exception when undefined_function or undefined_object then
    null;
  end;
end
$$;

-- 2) Lese-RPCs mit Mitgliederdaten ebenfalls nur dem Backend vorbehalten
--    (Zugriff läuft ausschließlich über die Serverless-API mit service_role).
do $$
begin
  begin
    execute 'revoke all on function public.get_today_transactions_berlin(uuid, integer) from public, anon, authenticated';
  exception when undefined_function or undefined_object then
    null;
  end;
  begin
    execute 'revoke all on function public.get_terminal_snapshot_berlin() from public, anon, authenticated';
  exception when undefined_function or undefined_object then
    null;
  end;
  begin
    execute 'revoke all on function public.get_members_with_last_booking() from public, anon, authenticated';
  exception when undefined_function or undefined_object then
    null;
  end;
  begin
    execute 'revoke all on function public.get_booked_today_berlin() from public, anon, authenticated';
  exception when undefined_function or undefined_object then
    null;
  end;
end
$$;

-- 3) Idempotenz für Stornos: verhindert Doppel-Storno, wenn der Client nach
--    einem Timeout denselben Storno erneut sendet (Offline-Queue-Retry).
alter table public.storno_log
  add column if not exists client_cancel_id text null;

create unique index if not exists storno_log_client_cancel_id_key
  on public.storno_log (client_cancel_id)
  where client_cancel_id is not null;

drop function if exists public.cancel_transaction(uuid, uuid, uuid, text, uuid);

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
  v_fr uuid;
  v_device_id uuid;
  v_existing uuid;
begin
  -- Idempotenz: bereits verarbeiteter Storno wird nicht erneut ausgeführt.
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
    client_cancel_id
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
    p_client_cancel_id
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
    execute 'grant execute on function public.book_transaction(uuid, uuid, integer, text, uuid, text) to service_role';
  end if;
end
$$;

-- 4) Atomare Saldo-Anpassung für das Backend: ersetzt das nicht-atomare
--    Read-Modify-Write in der Freigetränk-Verrechnung (api/app.js), bei dem
--    parallele Buchungen zwischen Lesen und Schreiben verloren gehen konnten.
create or replace function public.adjust_member_balance(
  p_member_id uuid,
  p_delta integer
)
returns void
language sql
security definer
set search_path = public, extensions, pg_temp
as $function$
  update public.members
  set balance = balance + p_delta
  where id = p_member_id;
$function$;

revoke all on function public.adjust_member_balance(uuid, integer) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.adjust_member_balance(uuid, integer) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.adjust_member_balance(uuid, integer) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.adjust_member_balance(uuid, integer) to service_role';
  end if;
end
$$;

-- 5) search_path für alle SECURITY-DEFINER-Funktionen pinnen
--    (Supabase-Advisor-Härtung; verhindert search_path-Hijacking und stellt
--    sicher, dass pgcrypto-Aufrufe wie crypt()/digest() stabil aufgelöst werden).
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
  loop
    execute format('alter function %s set search_path = public, extensions, pg_temp', r.sig);
  end loop;
end
$$;
