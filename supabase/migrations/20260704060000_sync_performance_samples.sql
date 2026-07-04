-- Store sync performance samples for charting over time.

create table if not exists public.device_sync_performance_samples (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.kiosk_devices(id) on delete cascade,
  measured_at timestamp with time zone not null default now(),
  duration_ms integer not null,
  attempted_count integer not null default 0,
  success_count integer not null default 0,
  failed_count integer not null default 0,
  book_count integer not null default 0,
  cancel_count integer not null default 0,
  batch_count integer not null default 0,
  avg_item_ms numeric null,
  error_message text null,
  source text not null default 'device',
  created_at timestamp with time zone not null default now(),
  constraint device_sync_performance_samples_values_chk check (
    duration_ms >= 0
    and attempted_count >= 0
    and success_count >= 0
    and failed_count >= 0
    and book_count >= 0
    and cancel_count >= 0
    and batch_count >= 0
    and coalesce(avg_item_ms, 0) >= 0
  )
);

create index if not exists device_sync_perf_samples_measured_idx
  on public.device_sync_performance_samples(measured_at desc);

create index if not exists device_sync_perf_samples_device_measured_idx
  on public.device_sync_performance_samples(device_id, measured_at desc);

alter table public.device_sync_performance_samples enable row level security;

revoke all on table public.device_sync_performance_samples from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.device_sync_performance_samples from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.device_sync_performance_samples from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on table public.device_sync_performance_samples to service_role';
  end if;
end $$;

insert into public.device_sync_performance_samples (
  device_id,
  measured_at,
  duration_ms,
  attempted_count,
  success_count,
  failed_count,
  book_count,
  cancel_count,
  batch_count,
  avg_item_ms,
  error_message,
  source
)
select
  s.device_id,
  coalesce(s.last_sync_finished_at, s.updated_at, now()),
  s.last_sync_duration_ms,
  coalesce(s.last_sync_attempted_count, s.last_sync_processed_count, 0),
  coalesce(s.last_sync_success_count, s.last_sync_processed_count, 0),
  coalesce(s.last_sync_failed_count, 0),
  coalesce(s.last_sync_book_count, 0),
  coalesce(s.last_sync_cancel_count, 0),
  coalesce(s.last_sync_batch_count, 0),
  s.last_sync_avg_item_ms,
  s.last_sync_error_message,
  'backfill'
from public.device_sync_status s
where s.last_sync_duration_ms is not null
  and not exists (
    select 1
    from public.device_sync_performance_samples existing
    where existing.device_id = s.device_id
      and existing.measured_at = coalesce(s.last_sync_finished_at, s.updated_at, now())
  );

create or replace function public.admin_list_sync_performance_samples(
  p_hours integer default 24,
  p_limit integer default 200
)
returns table(
  id uuid,
  device_id uuid,
  device_name text,
  measured_at timestamp with time zone,
  duration_ms integer,
  attempted_count integer,
  success_count integer,
  failed_count integer,
  book_count integer,
  cancel_count integer,
  batch_count integer,
  avg_item_ms numeric,
  error_message text,
  source text
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_hours integer;
  v_limit integer;
begin
  perform public.assert_admin();

  v_hours := least(greatest(coalesce(p_hours, 24), 1), 24 * 90);
  v_limit := least(greatest(coalesce(p_limit, 200), 1), 1000);

  return query
  with latest as (
    select
      s.id,
      s.device_id,
      d.name as device_name,
      s.measured_at,
      s.duration_ms,
      s.attempted_count,
      s.success_count,
      s.failed_count,
      s.book_count,
      s.cancel_count,
      s.batch_count,
      s.avg_item_ms,
      s.error_message,
      s.source
    from public.device_sync_performance_samples s
    left join public.kiosk_devices d on d.id = s.device_id
    where s.measured_at >= now() - make_interval(hours => v_hours)
    order by s.measured_at desc
    limit v_limit
  )
  select
    latest.id,
    latest.device_id,
    latest.device_name,
    latest.measured_at,
    latest.duration_ms,
    latest.attempted_count,
    latest.success_count,
    latest.failed_count,
    latest.book_count,
    latest.cancel_count,
    latest.batch_count,
    latest.avg_item_ms,
    latest.error_message,
    latest.source
  from latest
  order by latest.measured_at asc;
end;
$function$;

revoke all on function public.admin_list_sync_performance_samples(integer, integer) from public;
grant execute on function public.admin_list_sync_performance_samples(integer, integer) to authenticated;

create or replace function public.api_admin_list_sync_performance_samples(
  p_token text,
  p_hours integer default 24,
  p_limit integer default 200
)
returns table(
  id uuid,
  device_id uuid,
  device_name text,
  measured_at timestamp with time zone,
  duration_ms integer,
  attempted_count integer,
  success_count integer,
  failed_count integer,
  book_count integer,
  cancel_count integer,
  batch_count integer,
  avg_item_ms numeric,
  error_message text,
  source text
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select *
  from public.admin_list_sync_performance_samples(p_hours, p_limit);
end;
$function$;

revoke all on function public.api_admin_list_sync_performance_samples(text, integer, integer) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_list_sync_performance_samples(text, integer, integer) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';
