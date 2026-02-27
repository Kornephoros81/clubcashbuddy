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
      and t.amount < 0
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
      and s.amount < 0
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
