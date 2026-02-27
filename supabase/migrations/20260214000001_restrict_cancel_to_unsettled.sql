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
begin
  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null
    and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null
    and note is not null then
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

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is not null and cancel_transaction.product_id is not null then
    update public.products
    set stored = coalesce(stored, 0) + 1
    where id = cancel_transaction.product_id;
  end if;

  return v_cancel_id;
end;
$function$;

create or replace function public.get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(local_day date, member_id uuid, member_name text, total integer, items jsonb)
language sql
security definer
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  m.id as member_id,
  coalesce(
    m.firstname || ' ' || m.lastname ||
    case when m.is_guest then ' (Gast)' else '' end
  ) as member_name,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'settled_at', t.settled_at,
      'product_id', t.product_id,
      'product_name', p.name
    )
    order by t.created_at desc
  ) as items
from public.transactions t
join public.members m on m.id = t.member_id
left join public.products p on p.id = t.product_id
where t.created_at >= p_start and t.created_at < p_end
group by local_day, m.id, member_name
order by local_day desc, member_name;
$function$;
