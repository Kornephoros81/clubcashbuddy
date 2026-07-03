-- Central log for device sync failures reported by terminal clients.

create table if not exists public.device_sync_errors (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.kiosk_devices(id) on delete cascade,
  client_queue_id bigint null,
  client_tx_id text null,
  operation text not null,
  member_id uuid null,
  product_id uuid null,
  amount integer null,
  transaction_type text null,
  note text null,
  payload jsonb not null default '{}'::jsonb,
  error_message text not null,
  retry_class text null,
  attempts integer not null default 0,
  next_retry_at timestamp with time zone null,
  created_at timestamp with time zone not null default now(),
  constraint device_sync_errors_operation_chk
    check (operation in ('book', 'cancel', 'unknown')),
  constraint device_sync_errors_retry_class_chk
    check (retry_class is null or retry_class in ('retryable', 'fatal')),
  constraint device_sync_errors_attempts_chk
    check (attempts >= 0)
);

create index if not exists device_sync_errors_created_idx
  on public.device_sync_errors(created_at desc);

create index if not exists device_sync_errors_device_created_idx
  on public.device_sync_errors(device_id, created_at desc);

create index if not exists device_sync_errors_member_created_idx
  on public.device_sync_errors(member_id, created_at desc)
  where member_id is not null;

alter table public.device_sync_errors enable row level security;

revoke all on table public.device_sync_errors from public;

do $$
begin
  execute 'revoke all on table public.device_sync_errors from anon';
exception when undefined_object then
  null;
end $$;

do $$
begin
  execute 'revoke all on table public.device_sync_errors from authenticated';
exception when undefined_object then
  null;
end $$;

create or replace function public.admin_list_device_sync_errors(
  p_limit integer default 200,
  p_device_id uuid default null,
  p_since timestamp with time zone default null
)
returns table(
  id uuid,
  created_at timestamp with time zone,
  device_id uuid,
  device_name text,
  client_queue_id bigint,
  client_tx_id text,
  operation text,
  member_id uuid,
  member_name text,
  product_id uuid,
  product_name text,
  amount integer,
  transaction_type text,
  note text,
  error_message text,
  retry_class text,
  attempts integer,
  next_retry_at timestamp with time zone,
  payload jsonb
)
language plpgsql
security definer
as $function$
declare
  v_limit integer;
begin
  perform public.assert_admin();
  v_limit := least(greatest(coalesce(p_limit, 200), 1), 1000);

  return query
  select
    e.id,
    e.created_at,
    e.device_id,
    d.name as device_name,
    e.client_queue_id,
    e.client_tx_id,
    e.operation,
    e.member_id,
    trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')) as member_name,
    e.product_id,
    p.name as product_name,
    e.amount,
    e.transaction_type,
    e.note,
    e.error_message,
    e.retry_class,
    e.attempts,
    e.next_retry_at,
    e.payload
  from public.device_sync_errors e
  join public.kiosk_devices d on d.id = e.device_id
  left join public.members m on m.id = e.member_id
  left join public.products p on p.id = e.product_id
  where (p_device_id is null or e.device_id = p_device_id)
    and (p_since is null or e.created_at >= p_since)
  order by e.created_at desc
  limit v_limit;
end;
$function$;

revoke all on function public.admin_list_device_sync_errors(integer, uuid, timestamp with time zone) from public;
grant execute on function public.admin_list_device_sync_errors(integer, uuid, timestamp with time zone) to authenticated;

create or replace function public.api_admin_list_device_sync_errors(
  p_token text,
  p_limit integer default 200,
  p_device_id uuid default null,
  p_since timestamp with time zone default null
)
returns table(
  id uuid,
  created_at timestamp with time zone,
  device_id uuid,
  device_name text,
  client_queue_id bigint,
  client_tx_id text,
  operation text,
  member_id uuid,
  member_name text,
  product_id uuid,
  product_name text,
  amount integer,
  transaction_type text,
  note text,
  error_message text,
  retry_class text,
  attempts integer,
  next_retry_at timestamp with time zone,
  payload jsonb
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select *
  from public.admin_list_device_sync_errors(p_limit, p_device_id, p_since);
end;
$function$;

revoke all on function public.api_admin_list_device_sync_errors(text, integer, uuid, timestamp with time zone) from public;
