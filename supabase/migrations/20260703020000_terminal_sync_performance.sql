-- Performance improvements for terminal sync and admin observability.

alter table public.members
  add column if not exists updated_at timestamp with time zone not null default now();

alter table public.products
  add column if not exists updated_at timestamp with time zone not null default now();

create or replace function public.trg_set_updated_at()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

drop trigger if exists tg_members_updated_at on public.members;
create trigger tg_members_updated_at
before update on public.members
for each row
execute function public.trg_set_updated_at();

drop trigger if exists tg_products_updated_at on public.products;
create trigger tg_products_updated_at
before update on public.products
for each row
execute function public.trg_set_updated_at();

create or replace function public.get_terminal_catalog_versions()
returns table(
  member_catalog_version text,
  product_catalog_version text
)
language sql
security definer
set search_path = public, extensions, pg_temp
stable
as $function$
with member_version as (
  select md5(
    count(*)::text || ':' ||
    coalesce(max(m.updated_at)::text, '') || ':' ||
    coalesce((select max(mp.updated_at)::text from public.member_pins mp), '')
  ) as version
  from public.members m
  where m.active = true
),
product_version as (
  select md5(
    count(*)::text || ':' ||
    coalesce(max(p.updated_at)::text, '') || ':' ||
    coalesce(max(p.product_image_version)::text, '')
  ) as version
  from public.products p
  where p.active = true
)
select
  member_version.version,
  product_version.version
from member_version, product_version;
$function$;

revoke all on function public.get_terminal_catalog_versions() from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.get_terminal_catalog_versions() to service_role';
  end if;
end
$$;

create or replace function public.get_terminal_member_activity_berlin()
returns table(
  id uuid,
  last_booking_at timestamp with time zone,
  has_booked_today boolean
)
language sql
security definer
set search_path = public, extensions, pg_temp
stable
as $function$
with bounds as (
  select
    (date_trunc('day', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin') as start_utc,
    ((date_trunc('day', now() at time zone 'Europe/Berlin') + interval '1 day') at time zone 'Europe/Berlin') as end_utc
),
booked_today as (
  select distinct t.member_id
  from public.transactions t
  cross join bounds b
  where t.created_at >= b.start_utc
    and t.created_at < b.end_utc
)
select
  m.id,
  lt.last_booking_at,
  (bt.member_id is not null) as has_booked_today
from public.members m
left join lateral (
  select t.created_at as last_booking_at
  from public.transactions t
  where t.member_id = m.id
  order by t.created_at desc
  limit 1
) lt on true
left join booked_today bt on bt.member_id = m.id
where m.active = true
order by m.lastname, m.firstname;
$function$;

revoke all on function public.get_terminal_member_activity_berlin() from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.get_terminal_member_activity_berlin() to service_role';
  end if;
end
$$;

create or replace function public.get_terminal_snapshot_berlin()
returns table(
  id uuid,
  firstname text,
  lastname text,
  active boolean,
  is_guest boolean,
  settled boolean,
  last_booking_at timestamp with time zone,
  has_booked_today boolean
)
language sql
security definer
set search_path = public, extensions, pg_temp
stable
as $function$
with bounds as (
  select
    (date_trunc('day', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin') as start_utc,
    ((date_trunc('day', now() at time zone 'Europe/Berlin') + interval '1 day') at time zone 'Europe/Berlin') as end_utc
),
booked_today as (
  select distinct t.member_id
  from public.transactions t
  cross join bounds b
  where t.created_at >= b.start_utc
    and t.created_at < b.end_utc
)
select
  m.id,
  m.firstname,
  m.lastname,
  m.active,
  m.is_guest,
  m.settled,
  lt.last_booking_at,
  (bt.member_id is not null) as has_booked_today
from public.members m
left join lateral (
  select t.created_at as last_booking_at
  from public.transactions t
  where t.member_id = m.id
  order by t.created_at desc
  limit 1
) lt on true
left join booked_today bt on bt.member_id = m.id
where m.active = true
order by m.lastname, m.firstname;
$function$;

revoke all on function public.get_terminal_snapshot_berlin() from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.get_terminal_snapshot_berlin() to service_role';
  end if;
end
$$;

create or replace function public.book_transactions_batch(
  p_items jsonb,
  p_device_id uuid default null::uuid
)
returns table(
  queue_id bigint,
  client_tx_id_param text,
  success boolean,
  data uuid,
  error text
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_item jsonb;
  v_tx_id uuid;
  v_queue_id bigint;
  v_client_tx_id_text text;
  v_client_tx_id uuid;
  v_device_id uuid;
  v_count integer := 0;
begin
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception 'ITEMS_MUST_BE_ARRAY';
  end if;

  v_device_id := coalesce(p_device_id, public.app_current_device_id());

  for v_item in
    select value
    from jsonb_array_elements(p_items)
    limit 100
  loop
    v_count := v_count + 1;
    begin
      v_queue_id := nullif(v_item->>'queue_id', '')::bigint;
    exception when others then
      v_queue_id := null;
    end;
    v_client_tx_id_text := nullif(v_item->>'client_tx_id_param', '');
    queue_id := v_queue_id;
    client_tx_id_param := v_client_tx_id_text;
    success := false;
    data := null;
    error := null;

    begin
      v_client_tx_id := v_client_tx_id_text::uuid;

      v_tx_id := public.book_transaction(
        nullif(v_item->>'member_id', '')::uuid,
        nullif(v_item->>'product_id', '')::uuid,
        coalesce(nullif(v_item->>'free_amount', '')::integer, 0),
        nullif(v_item->>'p_note', ''),
        v_client_tx_id,
        nullif(v_item->>'p_transaction_type', '')
      );

      if v_device_id is not null then
        update public.transactions t
        set
          device_id = v_device_id,
          device_id_snapshot = v_device_id
        where t.id = v_tx_id
          and (t.device_id is null or t.device_id_snapshot is null);

        update public.inventory_movements im
        set
          device_id = v_device_id,
          device_id_snapshot = v_device_id
        where im.transaction_id = v_tx_id
          and im.reason = 'sale'
          and (im.device_id is null or im.device_id_snapshot is null);
      end if;

      success := true;
      data := v_tx_id;
      return next;
    exception when others then
      success := false;
      data := null;
      error := sqlerrm;
      return next;
    end;
  end loop;
end;
$function$;

revoke all on function public.book_transactions_batch(jsonb, uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.book_transactions_batch(jsonb, uuid) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.book_transactions_batch(jsonb, uuid) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.book_transactions_batch(jsonb, uuid) to service_role';
  end if;
end
$$;

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

create or replace function public.api_admin_get_performance_metrics(p_token text)
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
begin
  perform public.app_apply_session(p_token);
  return query
  select *
  from public.admin_get_performance_metrics();
end;
$function$;

revoke all on function public.api_admin_get_performance_metrics(text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    begin
      execute 'grant execute on function public.api_admin_list_device_sync_errors(text, integer, uuid, timestamp with time zone) to service_role';
    exception when undefined_function or undefined_object then
      null;
    end;
    execute 'grant execute on function public.api_admin_get_performance_metrics(text) to service_role';
  end if;
end
$$;

create or replace function public.admin_prune_device_sync_errors(
  p_older_than interval default interval '180 days'
)
returns integer
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_deleted integer;
begin
  perform public.assert_admin();

  delete from public.device_sync_errors e
  where e.created_at < now() - greatest(coalesce(p_older_than, interval '180 days'), interval '7 days');

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$function$;

revoke all on function public.admin_prune_device_sync_errors(interval) from public;
grant execute on function public.admin_prune_device_sync_errors(interval) to authenticated;

create or replace function public.api_admin_prune_device_sync_errors(
  p_token text,
  p_days integer default 180
)
returns integer
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_prune_device_sync_errors(make_interval(days => greatest(coalesce(p_days, 180), 7)));
end;
$function$;

revoke all on function public.api_admin_prune_device_sync_errors(text, integer) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_prune_device_sync_errors(text, integer) to service_role';
  end if;
end
$$;
