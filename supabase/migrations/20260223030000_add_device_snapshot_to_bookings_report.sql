-- Preserve device UID for reports even if kiosk device row is deleted later.
alter table public.transactions
  add column if not exists device_id_snapshot uuid null;

update public.transactions t
set device_id_snapshot = t.device_id
where t.device_id_snapshot is null
  and t.device_id is not null;

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
  v_device_id uuid;
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
    transaction_type,
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
    v_tx_type,
    v_device_id,
    v_device_id
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
      device_id,
      meta
    ) values (
      pid,
      1,
      v_fr,
      null,
      'sale',
      txid,
      'Verkauf',
      v_device_id,
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

create or replace function public.get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(local_day date, member_id uuid, member_name text, member_active boolean, total integer, items jsonb)
language sql
security definer
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  t.member_id as member_id,
  (
    coalesce(
      nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
      nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
      t.member_name_snapshot,
      '[Geloeschtes Mitglied]'
    )
    ||
    case when coalesce(m.is_guest, ma.is_guest, false) then ' (Gast)' else '' end
  ) as member_name,
  coalesce(m.active, false) as member_active,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'settled_at', t.settled_at,
      'product_id', t.product_id,
      'product_name', coalesce(p.name, pa.name, t.product_name_snapshot),
      'device_name', coalesce(kd.name, t.device_id_snapshot::text, t.device_id::text, '-'),
      'transaction_type', coalesce(
        t.transaction_type,
        case
          when coalesce(t.amount, 0) > 0 then 'credit_adjustment'
          when t.product_id is null then 'sale_free_amount'
          else 'sale_product'
        end
      )
    )
    order by t.created_at desc
  ) as items
from public.transactions t
left join public.members m on m.id = t.member_id
left join public.members_archive ma on ma.id = t.member_id
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
left join public.kiosk_devices kd on kd.id = t.device_id
where t.created_at >= p_start
  and t.created_at < p_end
group by local_day, t.member_id, member_name, member_active
order by local_day desc, member_name;
$function$;