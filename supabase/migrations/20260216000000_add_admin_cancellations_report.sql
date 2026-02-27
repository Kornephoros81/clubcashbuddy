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
    sl.amount,
    sl.note
  from public.storno_log sl
  left join public.members m on m.id = sl.member_id
  left join public.products p on p.id = sl.product_id
  where sl.canceled_at >= p_start
    and sl.canceled_at < p_end
  order by sl.canceled_at desc;
end;
$function$;

revoke all on function public.admin_get_cancellations_report_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_cancellations_report_period(timestamp with time zone, timestamp with time zone) to authenticated;

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

revoke all on function public.api_admin_get_cancellations_report_period(text, timestamp with time zone, timestamp with time zone) from public;
