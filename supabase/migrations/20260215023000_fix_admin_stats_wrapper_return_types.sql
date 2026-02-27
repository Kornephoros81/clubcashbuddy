-- Fix return types of admin stats wrappers to match base stats functions.

drop function if exists public.api_admin_stats_sales_trend(text, text);
drop function if exists public.api_admin_stats_top_products_period(text, text);
drop function if exists public.api_admin_stats_activity_heatmap_period(text, text);
drop function if exists public.api_admin_stats_active_members_period(text, text);

create or replace function public.api_admin_stats_sales_trend(
  p_token text,
  p_range text
)
returns table(tag date, umsatz_eur numeric)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select * from public.stats_sales_trend(p_range);
end;
$function$;

create or replace function public.api_admin_stats_top_products_period(
  p_token text,
  p_range text
)
returns table(product text, qty integer)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select * from public.stats_top_products_period(p_range);
end;
$function$;

create or replace function public.api_admin_stats_activity_heatmap_period(
  p_token text,
  p_range text
)
returns table(wochentag integer, stunde integer, anzahl_tx integer)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select * from public.stats_activity_heatmap_period(p_range);
end;
$function$;

create or replace function public.api_admin_stats_active_members_period(
  p_token text,
  p_range text
)
returns table(active_count integer)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select * from public.stats_active_members_period(p_range);
end;
$function$;
