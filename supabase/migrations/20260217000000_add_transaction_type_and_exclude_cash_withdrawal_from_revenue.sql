alter table public.transactions
  add column if not exists transaction_type text;

update public.transactions t
set transaction_type = case
  when coalesce(t.amount, 0) > 0 then 'credit_adjustment'
  when t.product_id is null then 'sale_free_amount'
  else 'sale_product'
end
where t.transaction_type is null;

alter table public.transactions
  alter column transaction_type set default 'sale_product';

alter table public.transactions
  alter column transaction_type set not null;

alter table public.transactions
  drop constraint if exists transactions_transaction_type_chk;

alter table public.transactions
  add constraint transactions_transaction_type_chk
  check (transaction_type in ('sale_product', 'sale_free_amount', 'cash_withdrawal', 'credit_adjustment'));

alter table public.storno_log
  add column if not exists transaction_type text;

update public.storno_log s
set transaction_type = case
  when coalesce(s.amount, 0) > 0 then 'credit_adjustment'
  when s.product_id is null then 'sale_free_amount'
  else 'sale_product'
end
where s.transaction_type is null;

alter table public.storno_log
  alter column transaction_type set default 'sale_product';

alter table public.storno_log
  alter column transaction_type set not null;

alter table public.storno_log
  drop constraint if exists storno_log_transaction_type_chk;

alter table public.storno_log
  add constraint storno_log_transaction_type_chk
  check (transaction_type in ('sale_product', 'sale_free_amount', 'cash_withdrawal', 'credit_adjustment'));

drop function if exists public.book_transaction(uuid, uuid, integer, text, uuid);

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
  v_fr uuid;
  v_tx_type text;
begin
  select
    m.is_guest,
    nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), '')
  into is_guest, v_member_name
  from public.members m
  where m.id = member_id;

  if product_id is not null then
    select
      case when is_guest then p.guest_price else p.price end,
      p.inventoried,
      p.name
    into amt, v_inventoried, v_product_name
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    v_price_snapshot := amt;
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
    transaction_type
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
    v_tx_type
  )
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null and coalesce(v_inventoried, true) then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      transaction_id,
      note,
      meta
    ) values (
      pid,
      1,
      v_fr,
      null,
      'sale',
      txid,
      'Verkauf',
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

grant execute on function public.book_transaction(uuid, uuid, integer, text, uuid, text) to anon, authenticated;

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text
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
begin
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
      meta
    ) values (
      v_tx.product_id,
      1,
      null,
      v_fr,
      'sale_cancel',
      'Storno Rueckbuchung',
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    );
  end if;

  return v_cancel_id;
end;
$function$;

drop function if exists public.api_admin_get_revenue_report_period(text, timestamp with time zone, timestamp with time zone);
drop function if exists public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone);

create or replace function public.admin_get_revenue_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
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
  select * from tx
  union all
  select * from sl
  order by event_at desc, event_type asc;
end;
$function$;

revoke all on function public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone) to authenticated;

create or replace function public.api_admin_get_revenue_report_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
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
  is_free_amount boolean,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_revenue_report_period(p_start, p_end);
end;
$function$;

revoke all on function public.api_admin_get_revenue_report_period(text, timestamp with time zone, timestamp with time zone) from public;

create or replace function public.api_admin_book_free_amount(
  p_token text,
  p_member_id uuid,
  p_amount_cents integer,
  p_note text default null
)
returns uuid
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return public.book_transaction(
    p_member_id,
    null,
    p_amount_cents,
    p_note,
    null,
    'credit_adjustment'
  );
end;
$function$;

-- Safety net for partially applied environments:
-- Ensure all positive amounts are always treated as non-revenue credit adjustments.
update public.transactions t
set transaction_type = 'credit_adjustment'
where coalesce(t.amount, 0) > 0
  and t.transaction_type <> 'credit_adjustment';

update public.storno_log s
set transaction_type = 'credit_adjustment'
where coalesce(s.amount, 0) > 0
  and s.transaction_type <> 'credit_adjustment';
