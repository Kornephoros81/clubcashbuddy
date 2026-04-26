drop function if exists public.api_admin_get_complimentary_report_period(text, timestamp with time zone, timestamp with time zone, integer, integer);
drop function if exists public.admin_get_complimentary_report_period(timestamp with time zone, timestamp with time zone, integer, integer);

create or replace function public.admin_get_complimentary_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_limit integer default null,
  p_offset integer default 0
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
  amount_abs integer,
  cost_amount_abs integer,
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
        'Unbekanntes Produkt'
      ) as product_name,
      coalesce(p.category, pa.category, 'Unbekannt') as product_category,
      abs(coalesce(nullif(t.product_price_snapshot, 0), p.guest_price, pa.guest_price, p.price, pa.price, t.amount, 0))::int as amount_abs,
      coalesce(t.product_cost_snapshot_cents, 0)::int as cost_amount_abs,
      t.note
    from public.transactions t
    left join public.members m on m.id = t.member_id
    left join public.members_archive ma on ma.id = t.member_id
    left join public.products p on p.id = t.product_id
    left join public.products_archive pa on pa.id = t.product_id
    where t.transaction_type = 'complimentary_product'
      and t.product_id is not null
      and t.created_at >= p_start
      and t.created_at < p_end
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
      coalesce(p.name, pa.name, 'Unbekanntes Produkt') as product_name,
      coalesce(p.category, pa.category, 'Unbekannt') as product_category,
      abs(coalesce(p.guest_price, pa.guest_price, p.price, pa.price, s.amount, 0))::int as amount_abs,
      coalesce(s.product_cost_snapshot_cents, 0)::int as cost_amount_abs,
      s.note
    from public.storno_log s
    left join public.members m on m.id = s.member_id
    left join public.members_archive ma on ma.id = s.member_id
    left join public.products p on p.id = s.product_id
    left join public.products_archive pa on pa.id = s.product_id
    where s.transaction_type = 'complimentary_product'
      and s.product_id is not null
      and s.canceled_at >= p_start
      and s.canceled_at < p_end
  )
  select * from (
    select * from tx
    union all
    select * from sl
  ) u
  order by u.event_at desc, u.event_type asc
  limit coalesce(p_limit, 2147483647)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$function$;

revoke all on function public.admin_get_complimentary_report_period(timestamp with time zone, timestamp with time zone, integer, integer) from public;
grant execute on function public.admin_get_complimentary_report_period(timestamp with time zone, timestamp with time zone, integer, integer) to authenticated;

create or replace function public.api_admin_get_complimentary_report_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_limit integer default null,
  p_offset integer default 0
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
  amount_abs integer,
  cost_amount_abs integer,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_complimentary_report_period(p_start, p_end, p_limit, p_offset);
end;
$function$;

revoke all on function public.api_admin_get_complimentary_report_period(text, timestamp with time zone, timestamp with time zone, integer, integer) from public;
