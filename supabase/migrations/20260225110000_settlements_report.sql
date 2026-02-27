-- Add settlements history report for admin UI.

create or replace function public.admin_get_settlements_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  settled_at timestamp with time zone,
  local_day date,
  settlement_id uuid,
  member_id uuid,
  member_name text,
  user_id uuid,
  user_name text,
  amount integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    s.settled_at,
    (s.settled_at at time zone 'Europe/Berlin')::date as local_day,
    s.id as settlement_id,
    s.member_id,
    coalesce(
      nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
      nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
      '[Unbekanntes Mitglied]'
    ) as member_name,
    s.user_id,
    coalesce(
      nullif(trim(u.username), ''),
      '[Unbekannter Benutzer]'
    ) as user_name,
    s.amount
  from public.settlements s
  left join public.members m on m.id = s.member_id
  left join public.members_archive ma on ma.id = s.member_id
  left join public.app_users u on u.id = s.user_id
  where s.settled_at >= p_start
    and s.settled_at < p_end
  order by s.settled_at desc;
end;
$function$;

revoke all on function public.admin_get_settlements_report_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_settlements_report_period(timestamp with time zone, timestamp with time zone) to authenticated;

create or replace function public.api_admin_get_settlements_report_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  settled_at timestamp with time zone,
  local_day date,
  settlement_id uuid,
  member_id uuid,
  member_name text,
  user_id uuid,
  user_name text,
  amount integer
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_settlements_report_period(p_start, p_end);
end;
$function$;

revoke all on function public.api_admin_get_settlements_report_period(text, timestamp with time zone, timestamp with time zone) from public;
