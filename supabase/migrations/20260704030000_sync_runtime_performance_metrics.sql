-- Persist sync runtime telemetry so booking/sync performance is visible centrally.

alter table public.device_sync_status
  add column if not exists last_sync_duration_ms integer null,
  add column if not exists last_sync_attempted_count integer null,
  add column if not exists last_sync_success_count integer null,
  add column if not exists last_sync_failed_count integer null,
  add column if not exists last_sync_book_count integer null,
  add column if not exists last_sync_cancel_count integer null,
  add column if not exists last_sync_batch_count integer null,
  add column if not exists last_sync_avg_item_ms numeric null,
  add column if not exists last_sync_error_message text null;

alter table public.device_sync_status
  drop constraint if exists device_sync_status_runtime_chk;

alter table public.device_sync_status
  add constraint device_sync_status_runtime_chk check (
    coalesce(last_sync_duration_ms, 0) >= 0
    and coalesce(last_sync_attempted_count, 0) >= 0
    and coalesce(last_sync_success_count, 0) >= 0
    and coalesce(last_sync_failed_count, 0) >= 0
    and coalesce(last_sync_book_count, 0) >= 0
    and coalesce(last_sync_cancel_count, 0) >= 0
    and coalesce(last_sync_batch_count, 0) >= 0
    and coalesce(last_sync_avg_item_ms, 0) >= 0
  );

create index if not exists device_sync_status_finished_idx
  on public.device_sync_status(last_sync_finished_at desc);

create or replace function public.admin_get_performance_metrics()
returns table(
  metric_key text,
  metric_label text,
  metric_group text,
  value_numeric numeric,
  value_text text,
  detail jsonb
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_today_start timestamp with time zone;
  v_today_end timestamp with time zone;
  v_terminal_members integer;
  v_active_products integer;
begin
  perform public.assert_admin();

  v_today_start := (date_trunc('day', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin');
  v_today_end := ((date_trunc('day', now() at time zone 'Europe/Berlin') + interval '1 day') at time zone 'Europe/Berlin');

  select count(*) into v_terminal_members
  from public.members m
  where m.active = true;

  select count(*) into v_active_products
  from public.products p
  where p.active = true;

  return query
  select
    'transactions_total',
    'Buchungen gesamt',
    'table_size',
    count(*)::numeric,
    null::text,
    jsonb_build_object('last_created_at', max(t.created_at))
  from public.transactions t;

  return query
  select
    'transactions_today',
    'Buchungen heute',
    'terminal_hot_path',
    count(*)::numeric,
    null::text,
    jsonb_build_object('start_utc', v_today_start, 'end_utc', v_today_end)
  from public.transactions t
  where t.created_at >= v_today_start
    and t.created_at < v_today_end;

  return query
  select
    'transactions_7d',
    'Buchungen letzte 7 Tage',
    'recent_activity',
    count(*)::numeric,
    null::text,
    jsonb_build_object('since', now() - interval '7 days')
  from public.transactions t
  where t.created_at >= now() - interval '7 days';

  return query
  select
    'open_transactions',
    'Offene Buchungen',
    'terminal_hot_path',
    count(*)::numeric,
    null::text,
    jsonb_build_object('note', 'settled_at is null')
  from public.transactions t
  where t.settled_at is null;

  return query
  select
    'storno_log_total',
    'Stornos gesamt',
    'table_size',
    count(*)::numeric,
    null::text,
    jsonb_build_object('last_canceled_at', max(s.canceled_at))
  from public.storno_log s;

  return query
  select
    'sync_errors_24h',
    'Sync-Fehler letzte 24h',
    'sync',
    count(*)::numeric,
    null::text,
    jsonb_build_object(
      'fatal', count(*) filter (where e.retry_class = 'fatal'),
      'retryable', count(*) filter (where e.retry_class = 'retryable')
    )
  from public.device_sync_errors e
  where e.created_at >= now() - interval '24 hours';

  return query
  with latest as (
    select d.name, s.*
    from public.device_sync_status s
    join public.kiosk_devices d on d.id = s.device_id
    where s.last_sync_finished_at is not null
    order by s.last_sync_finished_at desc
    limit 1
  )
  select
    'sync_last_duration_ms',
    'Letzter Sync Dauer',
    'sync',
    latest.last_sync_duration_ms::numeric,
    case
      when latest.last_sync_duration_ms is null then 'keine Daten'
      when latest.last_sync_duration_ms < 1000 then latest.last_sync_duration_ms::text || ' ms'
      else round(latest.last_sync_duration_ms::numeric / 1000, 2)::text || ' s'
    end,
    jsonb_build_object(
      'device', latest.name,
      'finished_at', latest.last_sync_finished_at,
      'attempted', latest.last_sync_attempted_count,
      'success', coalesce(latest.last_sync_success_count, latest.last_sync_processed_count),
      'failed', latest.last_sync_failed_count,
      'avg_item_ms', latest.last_sync_avg_item_ms
    )
  from latest;

  return query
  select
    'sync_avg_duration_24h',
    'Ø Sync-Dauer letzte 24h',
    'sync',
    avg(s.last_sync_duration_ms)::numeric,
    case
      when count(*) = 0 then 'keine Daten'
      when avg(s.last_sync_duration_ms) < 1000 then round(avg(s.last_sync_duration_ms))::text || ' ms'
      else round(avg(s.last_sync_duration_ms)::numeric / 1000, 2)::text || ' s'
    end,
    jsonb_build_object('devices', count(*), 'since', now() - interval '24 hours')
  from public.device_sync_status s
  where s.last_sync_finished_at >= now() - interval '24 hours'
    and s.last_sync_duration_ms is not null;

  return query
  with slowest as (
    select d.name, s.*
    from public.device_sync_status s
    join public.kiosk_devices d on d.id = s.device_id
    where s.last_sync_finished_at >= now() - interval '24 hours'
      and s.last_sync_duration_ms is not null
    order by s.last_sync_duration_ms desc
    limit 1
  )
  select
    'sync_slowest_duration_24h',
    'Langsamster Sync letzte 24h',
    'sync',
    slowest.last_sync_duration_ms::numeric,
    case
      when slowest.last_sync_duration_ms is null then 'keine Daten'
      when slowest.last_sync_duration_ms < 1000 then slowest.last_sync_duration_ms::text || ' ms'
      else round(slowest.last_sync_duration_ms::numeric / 1000, 2)::text || ' s'
    end,
    jsonb_build_object(
      'device', slowest.name,
      'finished_at', slowest.last_sync_finished_at,
      'attempted', slowest.last_sync_attempted_count,
      'success', coalesce(slowest.last_sync_success_count, slowest.last_sync_processed_count),
      'failed', slowest.last_sync_failed_count
    )
  from slowest;

  return query
  with latest as (
    select d.name, s.*
    from public.device_sync_status s
    join public.kiosk_devices d on d.id = s.device_id
    where s.last_sync_finished_at is not null
    order by s.last_sync_finished_at desc
    limit 1
  )
  select
    'sync_last_items',
    'Letzter Sync Einträge',
    'sync',
    latest.last_sync_attempted_count::numeric,
    concat(
      coalesce(latest.last_sync_success_count, latest.last_sync_processed_count, 0),
      ' / ',
      coalesce(latest.last_sync_attempted_count, 0),
      ' erfolgreich'
    ),
    jsonb_build_object(
      'device', latest.name,
      'bookings', latest.last_sync_book_count,
      'cancellations', latest.last_sync_cancel_count,
      'batches', latest.last_sync_batch_count,
      'error', latest.last_sync_error_message
    )
  from latest;

  return query
  select
    'sync_success_rate_24h',
    'Sync-Erfolgsquote letzte 24h',
    'sync',
    case
      when sum(coalesce(s.last_sync_attempted_count, 0)) > 0
        then round((sum(coalesce(s.last_sync_success_count, s.last_sync_processed_count, 0))::numeric / sum(coalesce(s.last_sync_attempted_count, 0))::numeric) * 100, 1)
      else null::numeric
    end,
    case
      when sum(coalesce(s.last_sync_attempted_count, 0)) > 0
        then round((sum(coalesce(s.last_sync_success_count, s.last_sync_processed_count, 0))::numeric / sum(coalesce(s.last_sync_attempted_count, 0))::numeric) * 100, 1)::text || ' %'
      else 'keine Daten'
    end,
    jsonb_build_object(
      'attempted', sum(coalesce(s.last_sync_attempted_count, 0)),
      'success', sum(coalesce(s.last_sync_success_count, s.last_sync_processed_count, 0)),
      'failed', sum(coalesce(s.last_sync_failed_count, 0)),
      'devices', count(*)
    )
  from public.device_sync_status s
  where s.last_sync_finished_at >= now() - interval '24 hours';

  return query
  select
    'sync_devices_with_queue',
    'Geräte mit lokaler Queue',
    'sync',
    count(*)::numeric,
    null::text,
    jsonb_build_object(
      'pending_total', coalesce(sum(s.pending_count), 0),
      'failed_total', coalesce(sum(s.failed_count), 0),
      'fatal_failed_total', coalesce(sum(s.fatal_failed_count), 0)
    )
  from public.device_sync_status s
  where s.total_count > 0;

  return query
  select
    'terminal_catalog_size',
    'Terminal-Kataloggröße',
    'terminal_payload',
    (v_terminal_members + v_active_products)::numeric,
    null::text,
    jsonb_build_object(
      'active_members', v_terminal_members,
      'active_products', v_active_products
    );

  return query
  select
    'booked_today_members',
    'Mitglieder mit Buchung heute',
    'terminal_hot_path',
    count(distinct t.member_id)::numeric,
    null::text,
    jsonb_build_object('start_utc', v_today_start, 'end_utc', v_today_end)
  from public.transactions t
  where t.created_at >= v_today_start
    and t.created_at < v_today_end;

  return query
  select
    'transactions_table_bytes',
    'Speicher transactions',
    'storage',
    pg_total_relation_size('public.transactions')::numeric,
    pg_size_pretty(pg_total_relation_size('public.transactions')),
    jsonb_build_object(
      'table_bytes', pg_relation_size('public.transactions'),
      'total_bytes', pg_total_relation_size('public.transactions')
    );
end;
$function$;

revoke all on function public.admin_get_performance_metrics() from public;
grant execute on function public.admin_get_performance_metrics() to authenticated;
