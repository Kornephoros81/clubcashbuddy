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
where t.created_at >= p_start
  and t.created_at < p_end
group by local_day, t.member_id, member_name, member_active
order by local_day desc, member_name;
$function$;

create or replace function public.admin_get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  local_day date,
  member_id uuid,
  member_name text,
  member_active boolean,
  total integer,
  items jsonb
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_all_bookings_grouped(p_start, p_end);
end;
$function$;
