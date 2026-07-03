-- Remote sync commands and central queue-size reporting for terminal devices.

create table if not exists public.device_sync_status (
  device_id uuid primary key references public.kiosk_devices(id) on delete cascade,
  pending_count integer not null default 0,
  failed_count integer not null default 0,
  total_count integer not null default 0,
  fatal_failed_count integer not null default 0,
  retryable_failed_count integer not null default 0,
  last_queue_report_at timestamp with time zone null,
  last_sync_started_at timestamp with time zone null,
  last_sync_finished_at timestamp with time zone null,
  last_sync_processed_count integer null,
  last_error text null,
  updated_at timestamp with time zone not null default now(),
  constraint device_sync_status_counts_chk check (
    pending_count >= 0
    and failed_count >= 0
    and total_count >= 0
    and fatal_failed_count >= 0
    and retryable_failed_count >= 0
  )
);

create table if not exists public.device_commands (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.kiosk_devices(id) on delete cascade,
  command text not null,
  status text not null default 'pending',
  requested_by uuid null references public.app_users(id) on delete set null,
  requested_at timestamp with time zone not null default now(),
  claimed_at timestamp with time zone null,
  completed_at timestamp with time zone null,
  result jsonb null,
  error text null,
  constraint device_commands_command_chk check (command in ('sync_now')),
  constraint device_commands_status_chk check (status in ('pending', 'claimed', 'done', 'failed'))
);

create index if not exists device_commands_device_status_idx
  on public.device_commands(device_id, status, requested_at desc);

create index if not exists device_commands_requested_idx
  on public.device_commands(requested_at desc);

alter table public.device_sync_status enable row level security;
alter table public.device_commands enable row level security;

revoke all on table public.device_sync_status from public;
revoke all on table public.device_commands from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.device_sync_status from anon';
    execute 'revoke all on table public.device_commands from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.device_sync_status from authenticated';
    execute 'revoke all on table public.device_commands from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on table public.device_sync_status to service_role';
    execute 'grant all on table public.device_commands to service_role';
  end if;
end
$$;

create or replace function public.admin_list_device_sync_status()
returns table(
  device_id uuid,
  device_name text,
  active boolean,
  device_last_seen_at timestamp with time zone,
  pending_count integer,
  failed_count integer,
  total_count integer,
  fatal_failed_count integer,
  retryable_failed_count integer,
  last_queue_report_at timestamp with time zone,
  last_sync_started_at timestamp with time zone,
  last_sync_finished_at timestamp with time zone,
  last_sync_processed_count integer,
  last_error text,
  pending_command_count integer,
  last_command_id uuid,
  last_command_status text,
  last_command_requested_at timestamp with time zone,
  last_command_completed_at timestamp with time zone
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.assert_admin();

  return query
  select
    d.id,
    d.name,
    d.active,
    d.last_seen_at,
    coalesce(s.pending_count, 0),
    coalesce(s.failed_count, 0),
    coalesce(s.total_count, 0),
    coalesce(s.fatal_failed_count, 0),
    coalesce(s.retryable_failed_count, 0),
    s.last_queue_report_at,
    s.last_sync_started_at,
    s.last_sync_finished_at,
    s.last_sync_processed_count,
    s.last_error,
    coalesce(pc.pending_command_count, 0)::integer,
    lc.id,
    lc.status,
    lc.requested_at,
    lc.completed_at
  from public.kiosk_devices d
  left join public.device_sync_status s on s.device_id = d.id
  left join lateral (
    select count(*)::integer as pending_command_count
    from public.device_commands c
    where c.device_id = d.id
      and c.status in ('pending', 'claimed')
  ) pc on true
  left join lateral (
    select c.id, c.status, c.requested_at, c.completed_at
    from public.device_commands c
    where c.device_id = d.id
    order by c.requested_at desc
    limit 1
  ) lc on true
  order by lower(d.name), d.created_at;
end;
$function$;

revoke all on function public.admin_list_device_sync_status() from public;
grant execute on function public.admin_list_device_sync_status() to authenticated;

create or replace function public.admin_enqueue_device_sync_command(
  p_device_id uuid default null::uuid
)
returns table(
  id uuid,
  device_id uuid,
  device_name text,
  command text,
  status text,
  requested_at timestamp with time zone
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.assert_admin();

  return query
  with target_devices as (
    select d.id, d.name
    from public.kiosk_devices d
    where d.active = true
      and (p_device_id is null or d.id = p_device_id)
      and not exists (
        select 1
        from public.device_commands existing
        where existing.device_id = d.id
          and existing.command = 'sync_now'
          and existing.status in ('pending', 'claimed')
      )
  ),
  inserted as (
    insert into public.device_commands (
      device_id,
      command,
      status,
      requested_by
    )
    select
      td.id,
      'sync_now',
      'pending',
      public.app_current_user_id()
    from target_devices td
    returning
      device_commands.id,
      device_commands.device_id,
      device_commands.command,
      device_commands.status,
      device_commands.requested_at
  )
  select
    i.id,
    i.device_id,
    d.name,
    i.command,
    i.status,
    i.requested_at
  from inserted i
  join public.kiosk_devices d on d.id = i.device_id
  order by lower(d.name), i.requested_at;
end;
$function$;

revoke all on function public.admin_enqueue_device_sync_command(uuid) from public;
grant execute on function public.admin_enqueue_device_sync_command(uuid) to authenticated;

create or replace function public.api_admin_list_device_sync_status(p_token text)
returns table(
  device_id uuid,
  device_name text,
  active boolean,
  device_last_seen_at timestamp with time zone,
  pending_count integer,
  failed_count integer,
  total_count integer,
  fatal_failed_count integer,
  retryable_failed_count integer,
  last_queue_report_at timestamp with time zone,
  last_sync_started_at timestamp with time zone,
  last_sync_finished_at timestamp with time zone,
  last_sync_processed_count integer,
  last_error text,
  pending_command_count integer,
  last_command_id uuid,
  last_command_status text,
  last_command_requested_at timestamp with time zone,
  last_command_completed_at timestamp with time zone
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_device_sync_status();
end;
$function$;

revoke all on function public.api_admin_list_device_sync_status(text) from public;

create or replace function public.api_admin_enqueue_device_sync_command(
  p_token text,
  p_device_id uuid default null::uuid
)
returns table(
  id uuid,
  device_id uuid,
  device_name text,
  command text,
  status text,
  requested_at timestamp with time zone
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_enqueue_device_sync_command(p_device_id);
end;
$function$;

revoke all on function public.api_admin_enqueue_device_sync_command(text, uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_list_device_sync_status(text) to service_role';
    execute 'grant execute on function public.api_admin_enqueue_device_sync_command(text, uuid) to service_role';
  end if;
end
$$;
