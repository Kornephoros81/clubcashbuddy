-- Performance improvements for terminal hot paths:
-- - index-friendly "today" filters in Europe/Berlin window
-- - additional indexes for open member bookings and cancel lookup
-- - combined terminal snapshot function (members + has_booked_today)

create index if not exists idx_tx_created_member
  on public.transactions using btree (created_at desc, member_id);

create index if not exists idx_tx_member_open_created
  on public.transactions using btree (member_id, created_at desc)
  where settled_at is null;

create index if not exists idx_tx_member_product_created
  on public.transactions using btree (member_id, product_id, created_at desc);

create or replace function public.get_booked_today_berlin()
returns table(member_id uuid)
language sql
security definer
stable
as $function$
with bounds as (
  select
    (date_trunc('day', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin') as start_utc,
    ((date_trunc('day', now() at time zone 'Europe/Berlin') + interval '1 day') at time zone 'Europe/Berlin') as end_utc
)
select distinct t.member_id
from public.transactions t
cross join bounds b
where t.created_at >= b.start_utc
  and t.created_at < b.end_utc;
$function$;

create or replace function public.get_today_transactions_berlin(p_member uuid)
returns table(
  id uuid,
  amount integer,
  note text,
  created_at timestamp with time zone,
  product_id uuid,
  product_name text
)
language sql
security definer
stable
as $function$
with bounds as (
  select
    (date_trunc('day', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin') as start_utc,
    ((date_trunc('day', now() at time zone 'Europe/Berlin') + interval '1 day') at time zone 'Europe/Berlin') as end_utc
)
select
  t.id,
  t.amount,
  t.note,
  t.created_at,
  t.product_id,
  coalesce(p.name, pa.name, t.product_name_snapshot) as product_name
from public.transactions t
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
cross join bounds b
where t.member_id = p_member
  and t.created_at >= b.start_utc
  and t.created_at < b.end_utc
  and t.settled_at is null
order by t.created_at desc;
$function$;

create or replace function public.get_today_transactions_berlin(
  p_member uuid,
  p_limit integer
)
returns table(
  id uuid,
  amount integer,
  note text,
  created_at timestamp with time zone,
  product_id uuid,
  product_name text
)
language sql
security definer
stable
as $function$
with bounds as (
  select
    (date_trunc('day', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin') as start_utc,
    ((date_trunc('day', now() at time zone 'Europe/Berlin') + interval '1 day') at time zone 'Europe/Berlin') as end_utc
)
select
  t.id,
  t.amount,
  t.note,
  t.created_at,
  t.product_id,
  coalesce(p.name, pa.name, t.product_name_snapshot) as product_name
from public.transactions t
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
cross join bounds b
where t.member_id = p_member
  and t.created_at >= b.start_utc
  and t.created_at < b.end_utc
  and t.settled_at is null
order by t.created_at desc
limit greatest(1, least(coalesce(p_limit, 200), 1000));
$function$;

grant execute on function public.get_today_transactions_berlin(uuid, integer) to anon, authenticated;

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
  max(t.created_at) as last_booking_at,
  (bt.member_id is not null) as has_booked_today
from public.members m
left join public.transactions t on t.member_id = m.id
left join booked_today bt on bt.member_id = m.id
where m.active = true
group by m.id, m.firstname, m.lastname, m.active, m.is_guest, m.settled, bt.member_id
order by m.lastname, m.firstname;
$function$;

grant execute on function public.get_terminal_snapshot_berlin() to anon, authenticated;

-- Ensure backend RPC/table access with SUPABASE_SERVICE_ROLE_KEY.
-- Required because prior hardening revokes public/anon/authenticated rights.
do $$
declare
  fn record;
  rel record;
  seq record;
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    for fn in
      select p.oid::regprocedure as signature
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
    loop
      execute format('grant execute on function %s to service_role', fn.signature);
    end loop;

    for rel in
      select c.oid::regclass as relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relkind in ('r', 'v', 'm', 'f', 'p')
    loop
      execute format('grant all on %s to service_role', rel.relname);
    end loop;

    for seq in
      select c.oid::regclass as relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relkind = 'S'
    loop
      execute format('grant all on %s to service_role', seq.relname);
    end loop;

    execute 'alter default privileges in schema public grant all on tables to service_role';
    execute 'alter default privileges in schema public grant all on sequences to service_role';
    execute 'alter default privileges in schema public grant execute on functions to service_role';
    execute 'grant usage on schema public to service_role';
  end if;
end
$$;
