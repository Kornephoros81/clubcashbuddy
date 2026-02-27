-- Admin report for fridge refills (positive stock adjustments).

drop function if exists public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone);
drop function if exists public.get_fridge_refills_period(timestamp with time zone, timestamp with time zone);

create or replace function public.get_fridge_refills_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  stock_adjustment_id uuid,
  product_id uuid,
  product_name text,
  product_category text,
  quantity integer,
  member_id uuid,
  member_name text,
  device_id uuid,
  device_name text,
  note text
)
language sql
security definer
as $function$
select
  sa.created_at,
  (sa.created_at at time zone 'Europe/Berlin')::date as local_day,
  sa.id as stock_adjustment_id,
  sa.product_id,
  coalesce(p.name, sa.product_name_snapshot, 'Unbekanntes Produkt') as product_name,
  coalesce(p.category, sa.product_category_snapshot, '-') as product_category,
  sa.quantity::int as quantity,
  sa.member_id,
  coalesce(
    nullif(sa.member_name_snapshot, ''),
    nullif(trim(concat_ws(' ', m.firstname, m.lastname)), ''),
    nullif(trim(concat_ws(' ', ma.firstname, ma.lastname)), ''),
    'Unbekannt'
  ) as member_name,
  sa.device_id,
  kd.name as device_name,
  sa.note
from public.stock_adjustments sa
left join public.products p
  on p.id = sa.product_id
left join public.members m
  on m.id = sa.member_id
left join public.members_archive ma
  on ma.id = sa.member_id
left join public.kiosk_devices kd
  on kd.id = sa.device_id
where sa.created_at >= p_start
  and sa.created_at < p_end
  and sa.quantity > 0
order by sa.created_at desc;
$function$;

create or replace function public.admin_get_fridge_refills_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  stock_adjustment_id uuid,
  product_id uuid,
  product_name text,
  product_category text,
  quantity integer,
  member_id uuid,
  member_name text,
  device_id uuid,
  device_name text,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_fridge_refills_period(p_start, p_end);
end;
$function$;

revoke all on function public.get_fridge_refills_period(timestamp with time zone, timestamp with time zone) from public;
revoke all on function public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone) to authenticated;
