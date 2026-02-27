-- Clean bootstrap for fresh Supabase/Postgres instances
-- WARNING: Destructive. This drops and recreates schema public.
-- Generated from supabase/migrations in lexical filename order.

begin;

drop schema if exists public cascade;
create schema public;

grant usage on schema public to postgres, anon, authenticated, service_role;
grant create on schema public to postgres, service_role;

-- Keep ownership/visibility defaults explicit for clean environments.
alter schema public owner to postgres;



-- >>> BEGIN 20260212000000_init.sql
create table if not exists public.admins (
  user_id uuid not null,
  constraint admins_pkey primary key (user_id)
) TABLESPACE pg_default;

create policy  read_own_admin_row
on public.admins
as permissive
for select
to authenticated
using (user_id = auth.uid());

drop function if exists public.add_storage(uuid, integer);
drop function if exists public.book_transaction(uuid, integer, uuid, text, uuid);
drop function if exists public.cancel_transaction(uuid, uuid, uuid, text);
drop function if exists public.export_month(integer, integer);
drop function if exists public.get_all_bookings_grouped(timestamp with time zone, timestamp with time zone);
drop function if exists public.get_booked_today_berlin();
drop function if exists public.get_member_bookings_grouped(uuid, timestamp with time zone, timestamp with time zone, boolean);
drop function if exists public.get_members_with_last_booking();
drop function if exists public.get_stock_report_period(timestamp with time zone, timestamp with time zone);
drop function if exists public.get_today_transactions_berlin(uuid);
drop function if exists public.get_transactions_by_range_berlin(uuid, date, date);
drop function if exists public.insert_random_transactions(integer);
drop function if exists public.perform_monthly_settlement(uuid);
drop function if exists public.stats_active_members_period(text);
drop function if exists public.stats_activity_heatmap_period(text);
drop function if exists public.stats_sales_trend(text);
drop function if exists public.stats_top_members();
drop function if exists public.stats_top_products();
drop function if exists public.stats_top_products_period(text);
do $$
begin
  if to_regclass('public.transactions') is not null then
    execute 'drop trigger if exists tg_update_balance on public.transactions';
  end if;
end
$$;
drop function if exists public.trg_update_balance();

create table if not exists public.kiosk_devices (
  id uuid not null default gen_random_uuid (),
  name text not null,
  device_secret text not null,
  active boolean null default true,
  last_seen_at timestamp with time zone null default now(),
  created_at timestamp with time zone null default now(),
  constraint kiosk_devices_pkey primary key (id),
  constraint kiosk_devices_name_key unique (name)
) TABLESPACE pg_default;

create table if not exists public.products (
  id uuid not null default gen_random_uuid (),
  name text not null,
  price integer not null,
  category text not null default 'Sonstiges'::text,
  active boolean not null default true,
  created_at timestamp with time zone not null default now(),
  inventoried boolean not null default true,
  guest_price integer not null default 0,
  stored smallint null default '0'::smallint,
  last_restocked_at timestamp with time zone null,
  constraint products_pkey primary key (id),
  constraint products_price_check check ((price >= 0))
) TABLESPACE pg_default;

create table if not exists public.members (
  id uuid not null default gen_random_uuid (),
  balance integer not null default 0,
  active boolean not null default true,
  created_at timestamp with time zone not null default now(),
  firstname text null,
  lastname text null,
  last_settled_at timestamp with time zone null,
  is_guest boolean not null default false,
  settled boolean not null default false,
  constraint members_pkey primary key (id)
) TABLESPACE pg_default;

create index IF not exists members_firstname_idx on public.members using btree (firstname) TABLESPACE pg_default;

create index IF not exists members_lastname_idx on public.members using btree (lastname) TABLESPACE pg_default;

create index IF not exists members_balance_idx on public.members using btree (balance) TABLESPACE pg_default;

create index IF not exists members_is_guest_idx on public.members using btree (is_guest) TABLESPACE pg_default;

create index IF not exists members_created_at_idx on public.members using btree (created_at) TABLESPACE pg_default;

create table if not exists public.stock_adjustments (
  id uuid not null default gen_random_uuid (),
  product_id uuid not null,
  quantity integer not null,
  device_id uuid not null,
  note text null,
  created_at timestamp with time zone not null default now(),
  constraint stock_adjustments_pkey primary key (id),
  constraint stock_adjustments_device_id_fkey foreign KEY (device_id) references kiosk_devices (id),
  constraint stock_adjustments_product_id_fkey foreign KEY (product_id) references products (id) on delete CASCADE
) TABLESPACE pg_default;

create index IF not exists stock_adjustments_product_id_idx on public.stock_adjustments using btree (product_id) TABLESPACE pg_default;

create index IF not exists stock_adjustments_created_at_idx on public.stock_adjustments using btree (created_at) TABLESPACE pg_default;


ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustments NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS no_direct_insert_stock_adjustments ON public.stock_adjustments;
DROP POLICY IF EXISTS read_stock_adjustments_admins ON public.stock_adjustments;
CREATE POLICY no_direct_insert_stock_adjustments ON public.stock_adjustments AS PERMISSIVE FOR INSERT TO authenticated, anon WITH CHECK (false);
CREATE POLICY read_stock_adjustments_admins ON public.stock_adjustments AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM admins a
  WHERE (a.user_id = auth.uid()))));
create table if not exists public.settlements (
  id uuid not null default gen_random_uuid (),
  member_id uuid not null,
  user_id uuid not null,
  settled_at timestamp with time zone not null default now(),
  amount integer not null,
  constraint settlements_pkey primary key (id),
  constraint settlements_member_user_unique unique (member_id, settled_at),
  constraint settlements_member_id_fkey foreign KEY (member_id) references members (id) on delete CASCADE,
  constraint settlements_user_id_fkey foreign KEY (user_id) references auth.users (id)
) TABLESPACE pg_default;



create table if not exists public.transactions (
  id uuid not null default gen_random_uuid (),
  member_id uuid not null,
  product_id uuid null,
  amount integer not null,
  note text null,
  created_at timestamp with time zone not null default now(),
  client_tx_id uuid null,
  settled_at timestamp with time zone null,
  constraint transactions_pkey primary key (id),
  constraint transactions_member_id_fkey foreign KEY (member_id) references members (id) on delete CASCADE,
  constraint transactions_product_id_fkey foreign KEY (product_id) references products (id)
) TABLESPACE pg_default;

create index IF not exists transactions_member_id_idx on public.transactions using btree (member_id) TABLESPACE pg_default;

create index IF not exists idx_tx_member_created on public.transactions using btree (member_id, created_at desc) TABLESPACE pg_default;

create index IF not exists idx_tx_created on public.transactions using btree (created_at desc) TABLESPACE pg_default;

create unique INDEX IF not exists transactions_client_tx_id_key on public.transactions using btree (client_tx_id) TABLESPACE pg_default
where
  (client_tx_id is not null);

create index IF not exists transactions_product_id_idx on public.transactions using btree (product_id) TABLESPACE pg_default;

create unique INDEX IF not exists ux_tx_client on public.transactions using btree (client_tx_id) TABLESPACE pg_default;

create or replace view public.stock_overview as
with
  sa as (
    select
      stock_adjustments.product_id,
      sum(stock_adjustments.quantity) as total_refilled,
      max(stock_adjustments.created_at) as last_refill
    from
      stock_adjustments
    group by
      stock_adjustments.product_id
  ),
  tx as (
    select
      transactions.product_id,
      count(*) filter (
        where
          transactions.amount < 0
      ) as total_sold
    from
      transactions
    group by
      transactions.product_id
  )
select
  p.id as product_id,
  COALESCE(sa.total_refilled, 0::bigint) as total_refilled,
  COALESCE(tx.total_sold, 0::bigint) as total_sold,
  COALESCE(sa.total_refilled, 0::bigint) - COALESCE(tx.total_sold, 0::bigint) as current_stock,
  sa.last_refill
from
  products p
  left join sa on sa.product_id = p.id
  left join tx on tx.product_id = p.id
where
  p.inventoried = true;

create or replace function public.add_storage(product_id uuid, amount integer)
returns void
language plpgsql
security definer
as $function$
begin
  update products
  set
    stored = greatest(0, coalesce(stored, 0) + amount),
    last_restocked_at = case when amount > 0 then now() else last_restocked_at end
  where id = product_id;
end;
$function$;

create or replace function public.book_transaction(
  client_tx_id_param uuid default null::uuid,
  free_amount integer default null::integer,
  member_id uuid default null::uuid,
  p_note text default null::text,
  product_id uuid default null::uuid
)
returns uuid
language plpgsql
security definer
as $function$
declare
  amt integer;
  pid uuid;
  note text;
  txid uuid;
  is_guest boolean;
begin
  -- pruefen, ob Mitglied Gast ist
  select m.is_guest into is_guest
  from public.members m
  where m.id = member_id;

  if product_id is not null then
    -- Preis je nach Mitgliedstyp bestimmen
    select
      case
        when is_guest then p.guest_price
        else p.price
      end
      into amt
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    amt := -abs(amt); -- Verbrauch immer negativ
    pid := product_id;
    note := null;
  else
    -- freier Betrag (z. B. Guthabenaufladung)
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;
    note := coalesce(p_note, 'frei');
  end if;

  -- Transaktion einfuegen (duplikatssicher)
  insert into public.transactions(member_id, product_id, amount, note, client_tx_id)
  values (member_id, pid, amt, note, client_tx_id_param)
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  -- Lagerbestand nur anpassen, wenn Transaktion wirklich eingefuegt wurde
  if txid is not null and pid is not null then
    update public.products
    set stored = coalesce(stored, 0) - 1
    where id = pid;
  end if;

  -- Falls Konflikt: vorhandene ID nachladen
  if txid is null and client_tx_id_param is not null then
    select t.id into txid
    from public.transactions t
    where t.client_tx_id = client_tx_id_param;
  end if;

  return txid;
end;
$function$;

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
begin
  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null
    and product_id is not null then
    -- Produktbuchung stornieren (neueste passende)
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null
    and note is not null then
    -- Freier Betrag stornieren (neueste passende, nur freie)
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  -- Saldo korrigieren
  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  -- Transaktion loeschen
  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  -- Lagerbestand nur anpassen, wenn Transaktion tatsaechlich geloescht wurde
  if v_cancel_id is not null and cancel_transaction.product_id is not null then
    update public.products
    set stored = coalesce(stored, 0) + 1
    where id = cancel_transaction.product_id;
  end if;

  return v_cancel_id;
end;
$function$;

create or replace function public.export_month(p_year integer, p_month integer)
returns table(lastname text, firstname text, total integer)
language sql
stable
as $function$
select
  m.lastname,
  m.firstname,
  sum(-t.amount) as total
from public.transactions t
join public.members m on m.id = t.member_id
where extract(year from t.created_at) = p_year
  and extract(month from t.created_at) = p_month
  and t.amount < 0
group by m.firstname, m.lastname
order by m.lastname, m.firstname;
$function$;

create or replace function public.get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(local_day date, member_id uuid, member_name text, total integer, items jsonb)
language sql
security definer
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  m.id as member_id,
  coalesce(
    m.firstname || ' ' || m.lastname ||
    case when m.is_guest then ' (Gast)' else '' end
  ) as member_name,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'product_id', t.product_id,
      'product_name', p.name
    )
    order by t.created_at desc
  ) as items
from public.transactions t
join public.members m on m.id = t.member_id
left join public.products p on p.id = t.product_id
where t.created_at >= p_start and t.created_at < p_end
group by local_day, m.id, member_name
order by local_day desc, member_name;
$function$;

create or replace function public.get_booked_today_berlin()
returns table(member_id uuid)
language sql
security definer
as $function$
  select distinct member_id
  from public.transactions
  where (created_at at time zone 'Europe/Berlin')::date = (now() at time zone 'Europe/Berlin')::date;
$function$;

create or replace function public.get_member_bookings_grouped(
  p_member_id uuid,
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_exclude_settled boolean default false
)
returns table(local_day date, total integer, items json)
language sql
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'product_id', t.product_id,
      'product_name', p.name,
      'settled_at', t.settled_at
    )
    order by t.created_at desc
  ) as items
from public.transactions t
left join public.products p on p.id = t.product_id
where t.member_id = p_member_id
  and t.created_at >= p_start
  and t.created_at < p_end
  and (not p_exclude_settled or t.settled_at is null)
group by 1
order by 1 desc;
$function$;

create or replace function public.get_members_with_last_booking()
returns table(
  id uuid,
  firstname text,
  lastname text,
  active boolean,
  is_guest boolean,
  settled boolean,
  last_booking_at timestamp with time zone
)
language sql
as $function$
  select
    m.id,
    m.firstname,
    m.lastname,
    m.active,
    m.is_guest,
    m.settled,
    max(t.created_at) as last_booking_at
  from members m
  left join transactions t on t.member_id = m.id
  where m.active = true
  group by m.id
  order by m.lastname, m.firstname;
$function$;

create or replace function public.get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  current_stock integer,
  refilled integer,
  consumed integer
)
language sql
security definer
as $function$
-- Hinweis zu Zeitfenstern:
-- Wir werten mit [p_start, p_end) aus (Ende exklusiv), um Rand-Dubletten zu vermeiden.
with
  -- 1) Nachfuellungen im Zeitraum voraggregieren
  sa as (
    select
      product_id,
      coalesce(sum(quantity), 0)::int as refilled
    from public.stock_adjustments
    where created_at >= p_start
      and created_at <  p_end
    group by product_id
  ),
  -- 2) Verbrauch im Zeitraum voraggregieren
  -- Annahme: jede Transaktion mit amount < 0 und product_id != null entspricht 1 verkauften Einheit
  -- Falls ihr eine quantity-Spalte habt, hier stattdessen sum(quantity) aggregieren.
  tx as (
    select
      product_id,
      count(*)::int as consumed
    from public.transactions
    where product_id is not null
      and amount < 0
      and created_at >= p_start
      and created_at <  p_end
    group by product_id
  )
select
  p.id                         as product_id,
  p.name                       as name,
  p.category                   as category,
  coalesce(so.current_stock,0) as current_stock,
  coalesce(sa.refilled, 0)     as refilled,
  coalesce(tx.consumed, 0)     as consumed
from public.products p
left join sa on sa.product_id = p.id
left join tx on tx.product_id = p.id
left join public.stock_overview so on so.product_id = p.id
where p.inventoried = true
order by p.category, p.name;
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
as $function$
select
    t.id,
    t.amount,
    t.note,
    t.created_at,
    t.product_id,
    p.name as product_name
  from public.transactions t
  left join public.products p on p.id = t.product_id
  where t.member_id = p_member
    and (t.created_at at time zone 'Europe/Berlin')::date = (now() at time zone 'Europe/Berlin')::date
    and t.settled_at is null
  order by t.created_at desc;
$function$;

create or replace function public.get_transactions_by_range_berlin(
  p_member uuid,
  p_start date,
  p_end date
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
as $function$
  select
    t.id,
    t.amount,
    t.note,
    t.created_at,
    t.product_id,
    p.name as product_name
  from public.transactions t
  left join public.products p on p.id = t.product_id
  where t.member_id = p_member
    and (t.created_at at time zone 'Europe/Berlin')::date between p_start and p_end
  order by t.created_at desc;
$function$;

create or replace function public.insert_random_transactions(n integer)
returns void
language plpgsql
as $function$
declare
  m_id uuid;
  p_id uuid;
  p_amount integer;
  i integer;
begin
  for i in 1..n loop
    select id into m_id
    from members
    order by random()
    limit 1;

    select id, price into p_id, p_amount
    from products
    order by random()
    limit 1;

    insert into transactions (
      id,
      member_id,
      product_id,
      amount,
      note,
      created_at,
      client_tx_id,
      settled_at
    )
    values (
      gen_random_uuid(),
      m_id,
      p_id,
      -p_amount,
      null,
      now() - (random() * interval '6 months'),
      null,
      null
    );
  end loop;
end;
$function$;

create or replace function public.perform_monthly_settlement(p_user_id uuid)
returns void
language plpgsql
security definer
as $function$
declare
  r record;
begin
  for r in select id, balance from public.members where balance < 0 loop
    insert into public.settlements (member_id, user_id, amount)
      values (r.id, p_user_id, r.balance);

    update public.members
      set balance = 0,
          last_settled_at = now()
      where id = r.id;
  end loop;
end;
$function$;

create or replace function public.stats_active_members_period(range text)
returns table(active_count integer)
language sql
stable
as $function$
  select count(distinct member_id) as active_count
  from transactions
  where created_at >= case range
    when 'day' then date_trunc('day', now())
    when '30d' then now() - interval '30 days'
    when 'month' then date_trunc('month', now())
    when 'year' then date_trunc('year', now())
    when '12m' then now() - interval '12 months'
    else now() - interval '30 days'
  end;
$function$;

create or replace function public.stats_activity_heatmap_period(range text)
returns table(wochentag integer, stunde integer, anzahl_tx integer)
language sql
stable
as $function$
  select
    extract(dow from created_at)::int as wochentag,
    extract(hour from created_at)::int as stunde,
    count(*) as anzahl_tx
  from transactions
  where created_at >= case range
    when 'day' then date_trunc('day', now())
    when '30d' then now() - interval '30 days'
    when 'month' then date_trunc('month', now())
    when 'year' then date_trunc('year', now())
    when '12m' then now() - interval '12 months'
    else now() - interval '30 days'
  end
  group by 1, 2;
$function$;

create or replace function public.stats_sales_trend(range text)
returns table(tag date, umsatz_eur numeric)
language sql
stable
as $function$
  select
    date_trunc('day', created_at)::date as tag,
    sum(amount) / 100.0 as umsatz_eur
  from transactions
  where created_at >= case range
    when 'day' then date_trunc('day', now())
    when '30d' then now() - interval '30 days'
    when 'month' then date_trunc('month', now())
    when 'year' then date_trunc('year', now())
    when '12m' then now() - interval '12 months'
    else now() - interval '30 days'
  end
  group by 1
  order by 1;
$function$;

create or replace function public.stats_top_members()
returns table(member text, total bigint)
language sql
stable security definer
as $function$
  select
    (m.lastname || ', ' || m.firstname)::text as member,
    sum(-t.amount)::bigint as total
  from public.transactions t
  join public.members m on m.id = t.member_id
  where t.created_at >= now() - interval '30 days'
    and t.amount < 0
  group by m.lastname, m.firstname
  order by total desc
  limit 10;
$function$;

create or replace function public.stats_top_products()
returns table(product text, qty bigint)
language sql
stable
as $function$
  select coalesce(p.name,'frei') as product, count(*) as qty
  from transactions t
  left join products p on p.id = t.product_id
  where t.created_at >= now() - interval '30 days' and t.amount < 0
  group by 1 order by 2 desc limit 10;
$function$;

create or replace function public.stats_top_products_period(range text)
returns table(product text, qty integer)
language sql
stable
as $function$
  select
    coalesce(p.name, 'Unbekannt') as product,
    count(*) as qty
  from transactions t
  join products p on p.id = t.product_id
  where t.created_at >= case range
    when 'day' then date_trunc('day', now())
    when '30d' then now() - interval '30 days'
    when 'month' then date_trunc('month', now())
    when 'year' then date_trunc('year', now())
    when '12m' then now() - interval '12 months'
    else now() - interval '30 days'
  end
  group by 1
  order by qty desc
  limit 10;
$function$;

create or replace function public.trg_update_balance()
returns trigger
language plpgsql
as $function$
begin
  update members set balance = balance + new.amount where id = new.member_id;
  return new;
end;
$function$;

create trigger tg_update_balance
after insert on public.transactions for each row
execute function trg_update_balance();
-- <<< END 20260212000000_init.sql


-- >>> BEGIN 20260213000000_fix_book_transaction_overload.sql
drop function if exists public.book_transaction(uuid, integer, uuid, text, uuid);
drop function if exists public.book_transaction(uuid, uuid, integer, text, uuid);

create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid
)
returns uuid
language plpgsql
security definer
as $function$
declare
  amt integer;
  pid uuid;
  note text;
  txid uuid;
  is_guest boolean;
begin
  select m.is_guest into is_guest
  from public.members m
  where m.id = member_id;

  if product_id is not null then
    select
      case
        when is_guest then p.guest_price
        else p.price
      end
      into amt
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    amt := -abs(amt);
    pid := product_id;
    note := null;
  else
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;
    note := coalesce(p_note, 'frei');
  end if;

  insert into public.transactions(member_id, product_id, amount, note, client_tx_id)
  values (member_id, pid, amt, note, client_tx_id_param)
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null then
    update public.products
    set stored = coalesce(stored, 0) - 1
    where id = pid;
  end if;

  if txid is null and client_tx_id_param is not null then
    select t.id into txid
    from public.transactions t
    where t.client_tx_id = client_tx_id_param;
  end if;

  return txid;
end;
$function$;

grant execute on function public.book_transaction(uuid, uuid, integer, text, uuid) to anon, authenticated;
-- <<< END 20260213000000_fix_book_transaction_overload.sql


-- >>> BEGIN 20260214000000_add_member_pins.sql
create table if not exists public.member_pins (
  member_id uuid not null,
  pin_plain text not null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint member_pins_pkey primary key (member_id),
  constraint member_pins_pin_plain_format_chk check (pin_plain ~ '^[A-Za-z0-9]{4}$'),
  constraint member_pins_member_id_fkey foreign key (member_id) references public.members (id) on delete cascade
) TABLESPACE pg_default;

create or replace function public.trg_set_member_pins_updated_at()
returns trigger
language plpgsql
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

drop trigger if exists tg_member_pins_updated_at on public.member_pins;
create trigger tg_member_pins_updated_at
before update on public.member_pins
for each row
execute function public.trg_set_member_pins_updated_at();
-- <<< END 20260214000000_add_member_pins.sql


-- >>> BEGIN 20260214000001_restrict_cancel_to_unsettled.sql
create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
begin
  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null
    and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null
    and note is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen storniert werden';
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is not null and cancel_transaction.product_id is not null then
    update public.products
    set stored = coalesce(stored, 0) + 1
    where id = cancel_transaction.product_id;
  end if;

  return v_cancel_id;
end;
$function$;

create or replace function public.get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(local_day date, member_id uuid, member_name text, total integer, items jsonb)
language sql
security definer
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  m.id as member_id,
  coalesce(
    m.firstname || ' ' || m.lastname ||
    case when m.is_guest then ' (Gast)' else '' end
  ) as member_name,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'settled_at', t.settled_at,
      'product_id', t.product_id,
      'product_name', p.name
    )
    order by t.created_at desc
  ) as items
from public.transactions t
join public.members m on m.id = t.member_id
left join public.products p on p.id = t.product_id
where t.created_at >= p_start and t.created_at < p_end
group by local_day, m.id, member_name
order by local_day desc, member_name;
$function$;
-- <<< END 20260214000001_restrict_cancel_to_unsettled.sql


-- >>> BEGIN 20260214000002_restrict_cancel_for_inactive_members.sql
drop function if exists public.cancel_transaction;
drop function if exists public.get_all_bookings_grouped;

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
  v_member_active boolean;
begin
  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null
    and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null
    and note is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen storniert werden';
  end if;

  select m.active into v_member_active
  from public.members m
  where m.id = v_tx.member_id;

  if coalesce(v_member_active, false) = false then
    raise exception 'Buchungen von inaktiven Mitgliedern duerfen nicht storniert werden';
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is not null and cancel_transaction.product_id is not null then
    update public.products
    set stored = coalesce(stored, 0) + 1
    where id = cancel_transaction.product_id;
  end if;

  return v_cancel_id;
end;
$function$;

create or replace function public.get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(local_day date, member_id uuid, member_name text, member_active boolean, total integer, items jsonb)
language sql
security definer
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  m.id as member_id,
  coalesce(
    m.firstname || ' ' || m.lastname ||
    case when m.is_guest then ' (Gast)' else '' end
  ) as member_name,
  m.active as member_active,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'settled_at', t.settled_at,
      'product_id', t.product_id,
      'product_name', p.name
    )
    order by t.created_at desc
  ) as items
from public.transactions t
join public.members m on m.id = t.member_id
left join public.products p on p.id = t.product_id
where t.created_at >= p_start and t.created_at < p_end
group by local_day, m.id, member_name, m.active
order by local_day desc, member_name;
$function$;
-- <<< END 20260214000002_restrict_cancel_for_inactive_members.sql


-- >>> BEGIN 20260215000000_add_storno_log_and_fix_cancel_transaction.sql
create table if not exists public.storno_log (
  id uuid not null default gen_random_uuid(),
  original_transaction_id uuid not null,
  member_id uuid null,
  product_id uuid null,
  transaction_created_at timestamp with time zone not null,
  canceled_at timestamp with time zone not null default now(),
  amount integer null,
  note text null,
  constraint storno_log_pkey primary key (id),
  constraint storno_log_member_id_fkey foreign key (member_id) references public.members (id) on delete set null,
  constraint storno_log_product_id_fkey foreign key (product_id) references public.products (id) on delete set null
) TABLESPACE pg_default;

create index if not exists storno_log_canceled_at_idx
  on public.storno_log using btree (canceled_at desc) TABLESPACE pg_default;

create index if not exists storno_log_member_id_idx
  on public.storno_log using btree (member_id) TABLESPACE pg_default;

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
  v_member_active boolean;
  v_canceled_at timestamp with time zone;
begin
  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null
    and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null
    and note is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen storniert werden';
  end if;

  select m.active into v_member_active
  from public.members m
  where m.id = v_tx.member_id;

  if coalesce(v_member_active, false) = false then
    raise exception 'Buchungen von inaktiven Mitgliedern duerfen nicht storniert werden';
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  v_canceled_at := now();

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is null then
    raise exception 'Storno fehlgeschlagen';
  end if;

  insert into public.storno_log (
    original_transaction_id,
    member_id,
    product_id,
    transaction_created_at,
    canceled_at,
    amount,
    note
  ) values (
    v_tx.id,
    v_tx.member_id,
    v_tx.product_id,
    v_tx.created_at,
    v_canceled_at,
    v_tx.amount,
    v_tx.note
  );

  if v_tx.product_id is not null then
    update public.products
    set stored = coalesce(stored, 0) + 1
    where id = v_tx.product_id;
  end if;

  return v_cancel_id;
end;
$function$;
-- <<< END 20260215000000_add_storno_log_and_fix_cancel_transaction.sql


-- >>> BEGIN 20260215010000_inventory_ledger_safe_delete_and_admin_rpcs.sql
-- Inventory ledger (warehouse + fridge), safe hard delete with archives,
-- and admin RPC wrappers to reduce dependency on custom admin edge functions.

-- ------------------------------------------------------------
-- 1) Product stock split
-- ------------------------------------------------------------
alter table public.products
  add column if not exists warehouse_stock integer not null default 0,
  add column if not exists fridge_stock integer not null default 0,
  add column if not exists min_warehouse integer not null default 0,
  add column if not exists min_fridge integer not null default 0;

-- ------------------------------------------------------------
-- 2) Archive tables for hard deletes (history keeps stable names)
-- ------------------------------------------------------------
create table if not exists public.members_archive (
  id uuid primary key,
  firstname text null,
  lastname text null,
  is_guest boolean not null default false,
  active boolean not null default false,
  balance integer not null default 0,
  settled boolean not null default false,
  created_at timestamp with time zone null,
  last_settled_at timestamp with time zone null,
  deleted_at timestamp with time zone not null default now(),
  deleted_by uuid null references auth.users (id)
) tablespace pg_default;

create table if not exists public.products_archive (
  id uuid primary key,
  name text not null,
  price integer not null,
  guest_price integer not null default 0,
  category text not null default 'Sonstiges'::text,
  active boolean not null default false,
  inventoried boolean not null default true,
  created_at timestamp with time zone null,
  deleted_at timestamp with time zone not null default now(),
  deleted_by uuid null references auth.users (id)
) tablespace pg_default;

-- ------------------------------------------------------------
-- 3) Stock locations + movement ledger
-- ------------------------------------------------------------
create table if not exists public.stock_locations (
  id uuid not null default gen_random_uuid(),
  code text not null,
  name text not null,
  constraint stock_locations_pkey primary key (id),
  constraint stock_locations_code_key unique (code)
) tablespace pg_default;

insert into public.stock_locations (code, name)
values
  ('warehouse', 'Lager'),
  ('fridge', 'Kuehlschrank')
on conflict (code) do nothing;

create table if not exists public.inventory_movements (
  id uuid not null default gen_random_uuid(),
  product_id uuid not null,
  quantity integer not null,
  from_location_id uuid null references public.stock_locations (id),
  to_location_id uuid null references public.stock_locations (id),
  reason text not null,
  transaction_id uuid null,
  stock_adjustment_id uuid null,
  device_id uuid null references public.kiosk_devices (id),
  note text null,
  created_at timestamp with time zone not null default now(),
  created_by uuid null references auth.users (id),
  meta jsonb not null default '{}'::jsonb,
  constraint inventory_movements_pkey primary key (id),
  constraint inventory_movements_qty_chk check (quantity > 0),
  constraint inventory_movements_reason_chk check (
    reason in (
      'opening_balance',
      'purchase',
      'transfer',
      'sale',
      'sale_cancel',
      'count_adjustment',
      'shrinkage',
      'waste'
    )
  ),
  constraint inventory_movements_from_to_chk check (
    from_location_id is distinct from to_location_id
  ),
  constraint inventory_movements_any_side_chk check (
    from_location_id is not null or to_location_id is not null
  )
) tablespace pg_default;

create index if not exists inventory_movements_product_id_idx
  on public.inventory_movements using btree (product_id) tablespace pg_default;

create index if not exists inventory_movements_created_at_idx
  on public.inventory_movements using btree (created_at desc) tablespace pg_default;

create index if not exists inventory_movements_reason_idx
  on public.inventory_movements using btree (reason) tablespace pg_default;

create index if not exists inventory_movements_transaction_id_idx
  on public.inventory_movements using btree (transaction_id) tablespace pg_default;

create index if not exists inventory_movements_stock_adjustment_id_idx
  on public.inventory_movements using btree (stock_adjustment_id) tablespace pg_default;

-- Keep snapshots in transactions for resilient reporting after hard deletes.
alter table public.transactions
  add column if not exists member_name_snapshot text null,
  add column if not exists product_name_snapshot text null,
  add column if not exists product_price_snapshot integer null;

-- ------------------------------------------------------------
-- 4) Helpers and sync functions
-- ------------------------------------------------------------
create or replace function public.get_stock_location_id(p_code text)
returns uuid
language sql
stable
as $function$
  select sl.id
  from public.stock_locations sl
  where sl.code = p_code
  limit 1;
$function$;

create or replace function public.get_product_stock(p_product_id uuid)
returns table(warehouse_qty integer, fridge_qty integer, total_qty integer)
language sql
stable
as $function$
with loc as (
  select
    public.get_stock_location_id('warehouse') as wh_id,
    public.get_stock_location_id('fridge') as fr_id
)
select
  coalesce(sum(
    case
      when im.to_location_id = loc.wh_id then im.quantity
      when im.from_location_id = loc.wh_id then -im.quantity
      else 0
    end
  ), 0)::int as warehouse_qty,
  coalesce(sum(
    case
      when im.to_location_id = loc.fr_id then im.quantity
      when im.from_location_id = loc.fr_id then -im.quantity
      else 0
    end
  ), 0)::int as fridge_qty,
  coalesce(sum(
    case
      when im.to_location_id = loc.wh_id then im.quantity
      when im.from_location_id = loc.wh_id then -im.quantity
      else 0
    end
  ), 0)::int
  +
  coalesce(sum(
    case
      when im.to_location_id = loc.fr_id then im.quantity
      when im.from_location_id = loc.fr_id then -im.quantity
      else 0
    end
  ), 0)::int as total_qty
from public.inventory_movements im
cross join loc
where im.product_id = p_product_id;
$function$;

create or replace function public.refresh_product_stock(p_product_id uuid)
returns void
language plpgsql
security definer
as $function$
declare
  v_warehouse integer;
  v_fridge integer;
  v_total integer;
begin
  select warehouse_qty, fridge_qty, total_qty
  into v_warehouse, v_fridge, v_total
  from public.get_product_stock(p_product_id);

  update public.products p
  set
    warehouse_stock = coalesce(v_warehouse, 0),
    fridge_stock = coalesce(v_fridge, 0),
    stored = greatest(least(coalesce(v_total, 0), 32767), -32768)::smallint
  where p.id = p_product_id;
end;
$function$;

create or replace function public.trg_refresh_product_stock_from_movement()
returns trigger
language plpgsql
security definer
as $function$
begin
  perform public.refresh_product_stock(new.product_id);
  return new;
end;
$function$;

drop trigger if exists tg_refresh_product_stock_from_movement on public.inventory_movements;
create trigger tg_refresh_product_stock_from_movement
after insert on public.inventory_movements
for each row
execute function public.trg_refresh_product_stock_from_movement();

-- ------------------------------------------------------------
-- 5) Backfill opening balance from current products.stored once
-- ------------------------------------------------------------
insert into public.inventory_movements (
  product_id,
  quantity,
  from_location_id,
  to_location_id,
  reason,
  note,
  created_at,
  meta
)
select
  p.id as product_id,
  abs(coalesce(p.stored, 0))::int as quantity,
  case
    when coalesce(p.stored, 0) < 0 then public.get_stock_location_id('warehouse')
    else null
  end as from_location_id,
  case
    when coalesce(p.stored, 0) > 0 then public.get_stock_location_id('warehouse')
    else null
  end as to_location_id,
  'opening_balance' as reason,
  'Initialer Bestandsuebertrag aus products.stored' as note,
  coalesce(p.last_restocked_at, now()) as created_at,
  jsonb_build_object('source', 'products.stored')
from public.products p
where coalesce(p.stored, 0) <> 0
  and not exists (
    select 1
    from public.inventory_movements im
    where im.product_id = p.id
  );

do $$
declare
  r record;
begin
  for r in select p.id from public.products p loop
    perform public.refresh_product_stock(r.id);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 6) Stock adjustments now represent transfer warehouse -> fridge
-- ------------------------------------------------------------
create or replace function public.trg_stock_adjustments_to_inventory_movements()
returns trigger
language plpgsql
security definer
as $function$
declare
  v_wh uuid;
  v_fr uuid;
begin
  if coalesce(new.quantity, 0) = 0 then
    return new;
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  v_fr := public.get_stock_location_id('fridge');

  if new.quantity > 0 then
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      stock_adjustment_id,
      device_id,
      note,
      created_at,
      meta
    ) values (
      new.product_id,
      new.quantity,
      v_wh,
      v_fr,
      'transfer',
      new.id,
      new.device_id,
      new.note,
      new.created_at,
      jsonb_build_object('source', 'stock_adjustments')
    );
  else
    -- Negative quantity means moving stock back out of fridge to warehouse.
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      stock_adjustment_id,
      device_id,
      note,
      created_at,
      meta
    ) values (
      new.product_id,
      abs(new.quantity),
      v_fr,
      v_wh,
      'transfer',
      new.id,
      new.device_id,
      coalesce(new.note, 'Rueckraeumung'),
      new.created_at,
      jsonb_build_object('source', 'stock_adjustments')
    );
  end if;

  update public.products p
  set last_restocked_at = greatest(coalesce(p.last_restocked_at, '-infinity'::timestamptz), new.created_at)
  where p.id = new.product_id;

  return new;
end;
$function$;

drop trigger if exists tg_stock_adjustments_to_inventory_movements on public.stock_adjustments;
create trigger tg_stock_adjustments_to_inventory_movements
after insert on public.stock_adjustments
for each row
execute function public.trg_stock_adjustments_to_inventory_movements();

-- Backfill historical stock_adjustments into movements once.
insert into public.inventory_movements (
  product_id,
  quantity,
  from_location_id,
  to_location_id,
  reason,
  stock_adjustment_id,
  device_id,
  note,
  created_at,
  meta
)
select
  sa.product_id,
  abs(sa.quantity)::int,
  case when sa.quantity > 0 then public.get_stock_location_id('warehouse') else public.get_stock_location_id('fridge') end,
  case when sa.quantity > 0 then public.get_stock_location_id('fridge') else public.get_stock_location_id('warehouse') end,
  'transfer',
  sa.id,
  sa.device_id,
  sa.note,
  sa.created_at,
  jsonb_build_object('source', 'stock_adjustments_backfill')
from public.stock_adjustments sa
where not exists (
  select 1
  from public.inventory_movements im
  where im.stock_adjustment_id = sa.id
);

-- ------------------------------------------------------------
-- 7) FK behavior: preserve history when members/products are deleted
-- ------------------------------------------------------------
alter table public.transactions drop constraint if exists transactions_member_id_fkey;
alter table public.transactions drop constraint if exists transactions_product_id_fkey;
alter table public.stock_adjustments drop constraint if exists stock_adjustments_product_id_fkey;
alter table public.settlements drop constraint if exists settlements_member_id_fkey;

-- ------------------------------------------------------------
-- 8) add_storage now writes ledger (purchase / correction), not direct counters
-- ------------------------------------------------------------
create or replace function public.add_storage(product_id uuid, amount integer)
returns void
language plpgsql
security definer
as $function$
declare
  v_wh uuid;
begin
  if coalesce(amount, 0) = 0 then
    return;
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  if v_wh is null then
    raise exception 'Stock location warehouse not configured';
  end if;

  if amount > 0 then
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      meta
    ) values (
      product_id,
      amount,
      null,
      v_wh,
      'purchase',
      'Einlagerung',
      jsonb_build_object('source', 'add_storage')
    );

    update public.products p
    set last_restocked_at = now()
    where p.id = product_id;
  else
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      meta
    ) values (
      product_id,
      abs(amount),
      v_wh,
      null,
      'count_adjustment',
      'Bestandskorrektur Lager',
      jsonb_build_object('source', 'add_storage')
    );
  end if;
end;
$function$;

-- ------------------------------------------------------------
-- 9) Booking / cancellation now writes inventory movements
-- ------------------------------------------------------------
create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid
)
returns uuid
language plpgsql
security definer
as $function$
declare
  amt integer;
  pid uuid;
  note text;
  txid uuid;
  is_guest boolean;
  v_inventoried boolean;
  v_member_name text;
  v_product_name text;
  v_price_snapshot integer;
  v_fr uuid;
begin
  select
    m.is_guest,
    nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), '')
  into is_guest, v_member_name
  from public.members m
  where m.id = member_id;

  if not found then
    raise exception 'MEMBER_NOT_FOUND';
  end if;

  if product_id is not null then
    select
      case when is_guest then p.guest_price else p.price end,
      p.inventoried,
      p.name
    into amt, v_inventoried, v_product_name
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    v_price_snapshot := amt;
    amt := -abs(amt);
    pid := product_id;
    note := null;
  else
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;
    note := coalesce(p_note, 'frei');
    v_inventoried := false;
  end if;

  insert into public.transactions (
    member_id,
    product_id,
    amount,
    note,
    client_tx_id,
    member_name_snapshot,
    product_name_snapshot,
    product_price_snapshot
  )
  values (
    member_id,
    pid,
    amt,
    note,
    client_tx_id_param,
    coalesce(v_member_name, member_id::text),
    v_product_name,
    v_price_snapshot
  )
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null and coalesce(v_inventoried, true) then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      transaction_id,
      note,
      meta
    ) values (
      pid,
      1,
      v_fr,
      null,
      'sale',
      txid,
      'Verkauf',
      jsonb_build_object('source', 'book_transaction')
    );
  end if;

  if txid is null and client_tx_id_param is not null then
    select t.id into txid
    from public.transactions t
    where t.client_tx_id = client_tx_id_param;
  end if;

  return txid;
end;
$function$;

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
  v_member_active boolean;
  v_canceled_at timestamp with time zone;
  v_fr uuid;
begin
  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null and note is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen storniert werden';
  end if;

  select m.active into v_member_active
  from public.members m
  where m.id = v_tx.member_id;

  if coalesce(v_member_active, false) = false then
    raise exception 'Buchungen von inaktiven Mitgliedern duerfen nicht storniert werden';
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  v_canceled_at := now();

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is null then
    raise exception 'Storno fehlgeschlagen';
  end if;

  insert into public.storno_log (
    original_transaction_id,
    member_id,
    product_id,
    transaction_created_at,
    canceled_at,
    amount,
    note
  ) values (
    v_tx.id,
    v_tx.member_id,
    v_tx.product_id,
    v_tx.created_at,
    v_canceled_at,
    v_tx.amount,
    v_tx.note
  );

  if v_tx.product_id is not null then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      meta
    ) values (
      v_tx.product_id,
      1,
      null,
      v_fr,
      'sale_cancel',
      'Storno Rueckbuchung',
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    );
  end if;

  return v_cancel_id;
end;
$function$;

-- ------------------------------------------------------------
-- 10) Views/reports switched to the new stock fields
-- ------------------------------------------------------------
drop function if exists public.get_stock_report_period(timestamp with time zone, timestamp with time zone);
drop view if exists public.stock_overview;

create or replace view public.stock_overview as
select
  p.id as product_id,
  coalesce(p.warehouse_stock, 0) as warehouse_stock,
  coalesce(p.fridge_stock, 0) as fridge_stock,
  (coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0)) as current_stock,
  p.last_restocked_at as last_refill
from public.products p
where p.inventoried = true
  and p.active = true;

create or replace function public.get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  current_stock integer,
  refilled integer,
  consumed integer,
  warehouse_stock integer,
  fridge_stock integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer
)
language sql
security definer
as $function$
with
  loc as (
    select
      public.get_stock_location_id('warehouse') as wh_id,
      public.get_stock_location_id('fridge') as fr_id
  ),
  mv as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.reason = 'purchase' and im.to_location_id = loc.wh_id then im.quantity
          else 0
        end
      ), 0)::int as purchased,
      coalesce(sum(
        case
          when im.reason = 'transfer'
           and im.from_location_id = loc.wh_id
           and im.to_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as transferred_to_fridge,
      coalesce(sum(
        case
          when im.reason = 'sale'
           and im.from_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as consumed_mv,
      coalesce(sum(
        case
          when im.reason in ('shrinkage', 'waste', 'count_adjustment')
          then im.quantity
          else 0
        end
      ), 0)::int as shrinkage
    from public.inventory_movements im
    cross join loc
    where im.created_at >= p_start
      and im.created_at < p_end
    group by im.product_id
  ),
  tx as (
    -- Legacy fallback for older data before movement backfill
    select
      t.product_id,
      count(*)::int as consumed_tx
    from public.transactions t
    where t.product_id is not null
      and t.amount < 0
      and t.created_at >= p_start
      and t.created_at < p_end
    group by t.product_id
  )
select
  p.id as product_id,
  p.name as name,
  p.category as category,
  (coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0))::int as current_stock,
  (coalesce(mv.purchased, 0) + coalesce(mv.transferred_to_fridge, 0))::int as refilled,
  greatest(coalesce(mv.consumed_mv, 0), coalesce(tx.consumed_tx, 0))::int as consumed,
  coalesce(p.warehouse_stock, 0)::int as warehouse_stock,
  coalesce(p.fridge_stock, 0)::int as fridge_stock,
  coalesce(mv.transferred_to_fridge, 0)::int as transferred_to_fridge,
  coalesce(mv.purchased, 0)::int as purchased,
  coalesce(mv.shrinkage, 0)::int as shrinkage
from public.products p
left join mv on mv.product_id = p.id
left join tx on tx.product_id = p.id
where p.inventoried = true
order by p.category, p.name;
$function$;

-- ------------------------------------------------------------
-- 11) Booking/report functions resilient to deleted members/products
-- ------------------------------------------------------------
create or replace function public.get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(local_day date, member_id uuid, member_name text, member_active boolean, total integer, items jsonb)
language sql
security definer
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  t.member_id as member_id,
  (
    coalesce(
      nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
      nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
      t.member_name_snapshot,
      '[Geloeschtes Mitglied]'
    )
    ||
    case when coalesce(m.is_guest, ma.is_guest, false) then ' (Gast)' else '' end
  ) as member_name,
  coalesce(m.active, false) as member_active,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'settled_at', t.settled_at,
      'product_id', t.product_id,
      'product_name', coalesce(p.name, pa.name, t.product_name_snapshot)
    )
    order by t.created_at desc
  ) as items
from public.transactions t
left join public.members m on m.id = t.member_id
left join public.members_archive ma on ma.id = t.member_id
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
where t.created_at >= p_start
  and t.created_at < p_end
group by local_day, t.member_id, member_name, member_active
order by local_day desc, member_name;
$function$;

create or replace function public.get_member_bookings_grouped(
  p_member_id uuid,
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_exclude_settled boolean default false
)
returns table(local_day date, total integer, items json)
language sql
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'product_id', t.product_id,
      'product_name', coalesce(p.name, pa.name, t.product_name_snapshot),
      'settled_at', t.settled_at
    )
    order by t.created_at desc
  ) as items
from public.transactions t
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
where t.member_id = p_member_id
  and t.created_at >= p_start
  and t.created_at < p_end
  and (not p_exclude_settled or t.settled_at is null)
group by 1
order by 1 desc;
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
as $function$
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
where t.member_id = p_member
  and (t.created_at at time zone 'Europe/Berlin')::date = (now() at time zone 'Europe/Berlin')::date
  and t.settled_at is null
order by t.created_at desc;
$function$;

create or replace function public.get_transactions_by_range_berlin(
  p_member uuid,
  p_start date,
  p_end date
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
as $function$
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
where t.member_id = p_member
  and (t.created_at at time zone 'Europe/Berlin')::date between p_start and p_end
order by t.created_at desc;
$function$;

-- ------------------------------------------------------------
-- 12) Admin guard + safe delete + admin RPC wrappers
-- ------------------------------------------------------------
create or replace function public.assert_admin()
returns void
language plpgsql
security definer
as $function$
begin
  if auth.uid() is null then
    -- Edge Functions using service role key have no user uid in SQL context.
    if coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role' then
      return;
    end if;
    raise exception 'Unauthorized';
  end if;

  if not exists (
    select 1
    from public.admins a
    where a.user_id = auth.uid()
  ) then
    raise exception 'Forbidden';
  end if;
end;
$function$;

create or replace function public.delete_member_safely(
  p_member_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
declare
  v_member public.members%rowtype;
  v_open_tx integer;
begin
  perform public.assert_admin();

  select *
  into v_member
  from public.members m
  where m.id = p_member_id;

  if not found then
    raise exception 'Mitglied nicht gefunden';
  end if;

  if not p_force and coalesce(v_member.balance, 0) <> 0 then
    raise exception 'Mitglied hat noch einen Saldo. Fuer hard delete p_force=true setzen.';
  end if;

  if not p_force then
    select count(*)::int
    into v_open_tx
    from public.transactions t
    where t.member_id = p_member_id
      and t.settled_at is null;

    if coalesce(v_open_tx, 0) > 0 then
      raise exception 'Mitglied hat noch offene Buchungen. Fuer hard delete p_force=true setzen.';
    end if;
  end if;

  insert into public.members_archive (
    id, firstname, lastname, is_guest, active, balance, settled, created_at, last_settled_at, deleted_at, deleted_by
  ) values (
    v_member.id, v_member.firstname, v_member.lastname, v_member.is_guest, v_member.active, v_member.balance, v_member.settled, v_member.created_at, v_member.last_settled_at, now(), auth.uid()
  )
  on conflict (id) do update
  set
    firstname = excluded.firstname,
    lastname = excluded.lastname,
    is_guest = excluded.is_guest,
    active = excluded.active,
    balance = excluded.balance,
    settled = excluded.settled,
    created_at = excluded.created_at,
    last_settled_at = excluded.last_settled_at,
    deleted_at = excluded.deleted_at,
    deleted_by = excluded.deleted_by;

  delete from public.members m
  where m.id = p_member_id;
end;
$function$;

create or replace function public.delete_product_safely(
  p_product_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
declare
  v_product public.products%rowtype;
begin
  perform public.assert_admin();

  select *
  into v_product
  from public.products p
  where p.id = p_product_id;

  if not found then
    raise exception 'Produkt nicht gefunden';
  end if;

  if not p_force and (coalesce(v_product.warehouse_stock, 0) <> 0 or coalesce(v_product.fridge_stock, 0) <> 0) then
    raise exception 'Produkt hat noch Bestand. Fuer hard delete p_force=true setzen.';
  end if;

  insert into public.products_archive (
    id, name, price, guest_price, category, active, inventoried, created_at, deleted_at, deleted_by
  ) values (
    v_product.id, v_product.name, v_product.price, v_product.guest_price, v_product.category, v_product.active, v_product.inventoried, v_product.created_at, now(), auth.uid()
  )
  on conflict (id) do update
  set
    name = excluded.name,
    price = excluded.price,
    guest_price = excluded.guest_price,
    category = excluded.category,
    active = excluded.active,
    inventoried = excluded.inventoried,
    created_at = excluded.created_at,
    deleted_at = excluded.deleted_at,
    deleted_by = excluded.deleted_by;

  delete from public.products p
  where p.id = p_product_id;
end;
$function$;

create or replace function public.admin_list_members()
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    m.id,
    m.firstname,
    m.lastname,
    m.balance,
    m.active,
    m.created_at
  from public.members m
  where m.is_guest = false
  order by m.lastname asc, m.firstname asc;
end;
$function$;

create or replace function public.admin_create_member(
  p_firstname text,
  p_lastname text
)
returns public.members
language plpgsql
security definer
as $function$
declare
  v_row public.members;
begin
  perform public.assert_admin();

  insert into public.members (firstname, lastname, active, balance)
  values (p_firstname, p_lastname, true, 0)
  returning * into v_row;

  return v_row;
end;
$function$;

create or replace function public.admin_update_member(
  p_id uuid,
  p_firstname text default null,
  p_lastname text default null,
  p_balance integer default null,
  p_active boolean default null
)
returns public.members
language plpgsql
security definer
as $function$
declare
  v_row public.members;
begin
  perform public.assert_admin();

  update public.members m
  set
    firstname = coalesce(p_firstname, m.firstname),
    lastname = coalesce(p_lastname, m.lastname),
    balance = coalesce(p_balance, m.balance),
    active = coalesce(p_active, m.active)
  where m.id = p_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Mitglied nicht gefunden';
  end if;

  return v_row;
end;
$function$;

create or replace function public.admin_delete_member(
  p_member_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.delete_member_safely(p_member_id, p_force);
end;
$function$;

create or replace function public.admin_list_products()
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  created_at timestamp with time zone,
  stored smallint,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    p.id,
    p.name,
    p.price,
    p.guest_price,
    p.category,
    p.active,
    p.inventoried,
    p.created_at,
    p.stored,
    p.warehouse_stock,
    p.fridge_stock,
    p.last_restocked_at
  from public.products p
  order by p.active desc, p.name asc;
end;
$function$;

create or replace function public.admin_create_product(
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean
)
returns public.products
language plpgsql
security definer
as $function$
declare
  v_row public.products;
begin
  perform public.assert_admin();

  insert into public.products (
    name,
    price,
    guest_price,
    category,
    active,
    inventoried
  ) values (
    coalesce(p_name, 'Neu'),
    coalesce(p_price, 0),
    coalesce(p_guest_price, 0),
    coalesce(p_category, 'Sonstiges'),
    coalesce(p_active, true),
    coalesce(p_inventoried, true)
  )
  returning * into v_row;

  return v_row;
end;
$function$;

create or replace function public.admin_update_product(
  p_id uuid,
  p_name text default null,
  p_price integer default null,
  p_guest_price integer default null,
  p_category text default null,
  p_active boolean default null,
  p_inventoried boolean default null
)
returns public.products
language plpgsql
security definer
as $function$
declare
  v_row public.products;
begin
  perform public.assert_admin();

  update public.products p
  set
    name = coalesce(p_name, p.name),
    price = coalesce(p_price, p.price),
    guest_price = coalesce(p_guest_price, p.guest_price),
    category = coalesce(p_category, p.category),
    active = coalesce(p_active, p.active),
    inventoried = coalesce(p_inventoried, p.inventoried)
  where p.id = p_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Produkt nicht gefunden';
  end if;

  return v_row;
end;
$function$;

create or replace function public.admin_delete_product(
  p_product_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.delete_product_safely(p_product_id, p_force);
end;
$function$;

create or replace function public.admin_get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  current_stock integer,
  refilled integer,
  consumed integer,
  warehouse_stock integer,
  fridge_stock integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_stock_report_period(p_start, p_end);
end;
$function$;

create or replace function public.admin_get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  local_day date,
  member_id uuid,
  member_name text,
  member_active boolean,
  total integer,
  items jsonb
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_all_bookings_grouped(p_start, p_end);
end;
$function$;

create or replace function public.admin_perform_monthly_settlement()
returns void
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  perform public.perform_monthly_settlement(auth.uid());
end;
$function$;

-- Restrict admin helper/functions to authenticated users.
revoke all on function public.assert_admin() from public;
grant execute on function public.assert_admin() to authenticated;

revoke all on function public.delete_member_safely(uuid, boolean) from public;
grant execute on function public.delete_member_safely(uuid, boolean) to authenticated;

revoke all on function public.delete_product_safely(uuid, boolean) from public;
grant execute on function public.delete_product_safely(uuid, boolean) to authenticated;

revoke all on function public.admin_list_members() from public;
grant execute on function public.admin_list_members() to authenticated;

revoke all on function public.admin_create_member(text, text) from public;
grant execute on function public.admin_create_member(text, text) to authenticated;

revoke all on function public.admin_update_member(uuid, text, text, integer, boolean) from public;
grant execute on function public.admin_update_member(uuid, text, text, integer, boolean) to authenticated;

revoke all on function public.admin_delete_member(uuid, boolean) from public;
grant execute on function public.admin_delete_member(uuid, boolean) to authenticated;

revoke all on function public.admin_list_products() from public;
grant execute on function public.admin_list_products() to authenticated;

revoke all on function public.admin_create_product(text, integer, integer, text, boolean, boolean) from public;
grant execute on function public.admin_create_product(text, integer, integer, text, boolean, boolean) to authenticated;

revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean) from public;
grant execute on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean) to authenticated;

revoke all on function public.admin_delete_product(uuid, boolean) from public;
grant execute on function public.admin_delete_product(uuid, boolean) to authenticated;

revoke all on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) to authenticated;

revoke all on function public.admin_get_all_bookings_grouped(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_all_bookings_grouped(timestamp with time zone, timestamp with time zone) to authenticated;

revoke all on function public.admin_perform_monthly_settlement() from public;
grant execute on function public.admin_perform_monthly_settlement() to authenticated;
-- <<< END 20260215010000_inventory_ledger_safe_delete_and_admin_rpcs.sql


-- >>> BEGIN 20260215011000_fix_assert_admin_service_role.sql
create or replace function public.assert_admin()
returns void
language plpgsql
security definer
as $function$
begin
  if auth.uid() is null then
    -- Allow trusted backend calls that run with service role key.
    if coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role' then
      return;
    end if;
    raise exception 'Unauthorized';
  end if;

  if not exists (
    select 1
    from public.admins a
    where a.user_id = auth.uid()
  ) then
    raise exception 'Forbidden';
  end if;
end;
$function$;

revoke all on function public.assert_admin() from public;
grant execute on function public.assert_admin() to authenticated;
-- <<< END 20260215011000_fix_assert_admin_service_role.sql


-- >>> BEGIN 20260215012000_fix_stock_adjustments_product_relation.sql
-- Restore PostgREST relationship stock_adjustments -> products while still allowing hard delete.
-- Strategy:
-- - product_id becomes nullable
-- - FK uses ON DELETE SET NULL
-- - keep product snapshots on stock_adjustments for reporting after delete

alter table public.stock_adjustments
  add column if not exists product_name_snapshot text null,
  add column if not exists product_category_snapshot text null;

-- Backfill snapshots from current product rows.
update public.stock_adjustments sa
set
  product_name_snapshot = p.name,
  product_category_snapshot = p.category
from public.products p
where sa.product_id = p.id
  and (
    sa.product_name_snapshot is null
    or sa.product_category_snapshot is null
  );

alter table public.stock_adjustments
  alter column product_id drop not null;

alter table public.stock_adjustments
  drop constraint if exists stock_adjustments_product_id_fkey;

alter table public.stock_adjustments
  add constraint stock_adjustments_product_id_fkey
  foreign key (product_id)
  references public.products (id)
  on delete set null;

create or replace function public.trg_set_stock_adjustment_product_snapshot()
returns trigger
language plpgsql
as $function$
begin
  if new.product_id is null then
    return new;
  end if;

  if new.product_name_snapshot is null or new.product_category_snapshot is null then
    select p.name, p.category
    into new.product_name_snapshot, new.product_category_snapshot
    from public.products p
    where p.id = new.product_id;
  end if;

  return new;
end;
$function$;

drop trigger if exists tg_set_stock_adjustment_product_snapshot on public.stock_adjustments;
create trigger tg_set_stock_adjustment_product_snapshot
before insert on public.stock_adjustments
for each row
execute function public.trg_set_stock_adjustment_product_snapshot();

notify pgrst, 'reload schema';
-- <<< END 20260215012000_fix_stock_adjustments_product_relation.sql


-- >>> BEGIN 20260215013000_drop_legacy_stored_column.sql
-- Remove legacy products.stored after frontend moved to warehouse/fridge stock.

create or replace function public.refresh_product_stock(p_product_id uuid)
returns void
language plpgsql
security definer
as $function$
declare
  v_warehouse integer;
  v_fridge integer;
begin
  select warehouse_qty, fridge_qty
  into v_warehouse, v_fridge
  from public.get_product_stock(p_product_id);

  update public.products p
  set
    warehouse_stock = coalesce(v_warehouse, 0),
    fridge_stock = coalesce(v_fridge, 0)
  where p.id = p_product_id;
end;
$function$;

DROP FUNCTION admin_list_products();

create or replace function public.admin_list_products()
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    p.id,
    p.name,
    p.price,
    p.guest_price,
    p.category,
    p.active,
    p.inventoried,
    p.created_at,
    p.warehouse_stock,
    p.fridge_stock,
    p.last_restocked_at
  from public.products p
  order by p.active desc, p.name asc;
end;
$function$;

alter table public.products
  drop column if exists stored;
-- <<< END 20260215013000_drop_legacy_stored_column.sql


-- >>> BEGIN 20260215014000_adjust_inventory_report_columns.sql
-- Inventory report: inactive products last + explicit calculated target stocks.

drop function if exists public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone);
drop function if exists public.get_stock_report_period(timestamp with time zone, timestamp with time zone);

create or replace function public.get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  current_stock integer,
  refilled integer,
  consumed integer,
  warehouse_stock integer,
  fridge_stock integer,
  soll_warehouse_stock integer,
  soll_fridge_stock integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer
)
language sql
security definer
as $function$
with
  loc as (
    select
      public.get_stock_location_id('warehouse') as wh_id,
      public.get_stock_location_id('fridge') as fr_id
  ),
  mv_period as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.reason = 'purchase' and im.to_location_id = loc.wh_id then im.quantity
          else 0
        end
      ), 0)::int as purchased,
      coalesce(sum(
        case
          when im.reason = 'transfer'
           and im.from_location_id = loc.wh_id
           and im.to_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as transferred_to_fridge,
      coalesce(sum(
        case
          when im.reason = 'sale'
           and im.from_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as consumed_mv,
      coalesce(sum(
        case
          when im.reason in ('shrinkage', 'waste', 'count_adjustment')
          then im.quantity
          else 0
        end
      ), 0)::int as shrinkage
    from public.inventory_movements im
    cross join loc
    where im.created_at >= p_start
      and im.created_at < p_end
    group by im.product_id
  ),
  mv_total as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.to_location_id = loc.wh_id then im.quantity
          when im.from_location_id = loc.wh_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_warehouse_stock,
      coalesce(sum(
        case
          when im.to_location_id = loc.fr_id then im.quantity
          when im.from_location_id = loc.fr_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_fridge_stock
    from public.inventory_movements im
    cross join loc
    group by im.product_id
  ),
  tx as (
    -- Legacy fallback for older data before movement backfill
    select
      t.product_id,
      count(*)::int as consumed_tx
    from public.transactions t
    where t.product_id is not null
      and t.amount < 0
      and t.created_at >= p_start
      and t.created_at < p_end
    group by t.product_id
  )
select
  p.id as product_id,
  p.name as name,
  p.category as category,
  p.active as active,
  (coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0))::int as current_stock,
  (coalesce(mv_period.purchased, 0) + coalesce(mv_period.transferred_to_fridge, 0))::int as refilled,
  greatest(coalesce(mv_period.consumed_mv, 0), coalesce(tx.consumed_tx, 0))::int as consumed,
  coalesce(p.warehouse_stock, 0)::int as warehouse_stock,
  coalesce(p.fridge_stock, 0)::int as fridge_stock,
  coalesce(mv_total.soll_warehouse_stock, 0)::int as soll_warehouse_stock,
  coalesce(mv_total.soll_fridge_stock, 0)::int as soll_fridge_stock,
  coalesce(mv_period.transferred_to_fridge, 0)::int as transferred_to_fridge,
  coalesce(mv_period.purchased, 0)::int as purchased,
  coalesce(mv_period.shrinkage, 0)::int as shrinkage
from public.products p
left join mv_period on mv_period.product_id = p.id
left join mv_total on mv_total.product_id = p.id
left join tx on tx.product_id = p.id
where p.inventoried = true
order by p.active desc, p.category, p.name;
$function$;

create or replace function public.admin_get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  current_stock integer,
  refilled integer,
  consumed integer,
  warehouse_stock integer,
  fridge_stock integer,
  soll_warehouse_stock integer,
  soll_fridge_stock integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_stock_report_period(p_start, p_end);
end;
$function$;

revoke all on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) to authenticated;
-- <<< END 20260215014000_adjust_inventory_report_columns.sql


-- >>> BEGIN 20260215015000_refine_inventory_report_structure.sql
-- Refine inventory report structure: explicit status, target deltas and clearer flow fields.

drop function if exists public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone);
drop function if exists public.get_stock_report_period(timestamp with time zone, timestamp with time zone);

create or replace function public.get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  warehouse_stock integer,
  soll_warehouse_stock integer,
  delta_warehouse integer,
  fridge_stock integer,
  soll_fridge_stock integer,
  delta_fridge integer,
  current_stock integer,
  consumed integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer
)
language sql
security definer
as $function$
with
  loc as (
    select
      public.get_stock_location_id('warehouse') as wh_id,
      public.get_stock_location_id('fridge') as fr_id
  ),
  mv_period as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.reason = 'purchase' and im.to_location_id = loc.wh_id then im.quantity
          else 0
        end
      ), 0)::int as purchased,
      coalesce(sum(
        case
          when im.reason = 'transfer'
           and im.from_location_id = loc.wh_id
           and im.to_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as transferred_to_fridge,
      coalesce(sum(
        case
          when im.reason = 'sale'
           and im.from_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as consumed_mv,
      coalesce(sum(
        case
          when im.reason in ('shrinkage', 'waste', 'count_adjustment')
          then im.quantity
          else 0
        end
      ), 0)::int as shrinkage
    from public.inventory_movements im
    cross join loc
    where im.created_at >= p_start
      and im.created_at < p_end
    group by im.product_id
  ),
  mv_total as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.to_location_id = loc.wh_id then im.quantity
          when im.from_location_id = loc.wh_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_warehouse_stock,
      coalesce(sum(
        case
          when im.to_location_id = loc.fr_id then im.quantity
          when im.from_location_id = loc.fr_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_fridge_stock
    from public.inventory_movements im
    cross join loc
    group by im.product_id
  ),
  tx as (
    -- Legacy fallback for older data before movement backfill
    select
      t.product_id,
      count(*)::int as consumed_tx
    from public.transactions t
    where t.product_id is not null
      and t.amount < 0
      and t.created_at >= p_start
      and t.created_at < p_end
    group by t.product_id
  )
select
  p.id as product_id,
  p.name as name,
  p.category as category,
  p.active as active,
  coalesce(p.warehouse_stock, 0)::int as warehouse_stock,
  coalesce(mv_total.soll_warehouse_stock, 0)::int as soll_warehouse_stock,
  (coalesce(p.warehouse_stock, 0) - coalesce(mv_total.soll_warehouse_stock, 0))::int as delta_warehouse,
  coalesce(p.fridge_stock, 0)::int as fridge_stock,
  coalesce(mv_total.soll_fridge_stock, 0)::int as soll_fridge_stock,
  (coalesce(p.fridge_stock, 0) - coalesce(mv_total.soll_fridge_stock, 0))::int as delta_fridge,
  (coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0))::int as current_stock,
  greatest(coalesce(mv_period.consumed_mv, 0), coalesce(tx.consumed_tx, 0))::int as consumed,
  coalesce(mv_period.transferred_to_fridge, 0)::int as transferred_to_fridge,
  coalesce(mv_period.purchased, 0)::int as purchased,
  coalesce(mv_period.shrinkage, 0)::int as shrinkage
from public.products p
left join mv_period on mv_period.product_id = p.id
left join mv_total on mv_total.product_id = p.id
left join tx on tx.product_id = p.id
where p.inventoried = true
order by p.active desc, p.category, p.name;
$function$;

create or replace function public.admin_get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  warehouse_stock integer,
  soll_warehouse_stock integer,
  delta_warehouse integer,
  fridge_stock integer,
  soll_fridge_stock integer,
  delta_fridge integer,
  current_stock integer,
  consumed integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_stock_report_period(p_start, p_end);
end;
$function$;

revoke all on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) to authenticated;
-- <<< END 20260215015000_refine_inventory_report_structure.sql


-- >>> BEGIN 20260215016000_inventory_count_and_adjustments_reports.sql
-- Inventory count workflow:
-- 1) Snapshot without period (booked target/Soll by location)
-- 2) Apply counted Ist values as count_adjustment movements
-- 3) Period report for shortages/overstocks and adjustments

create or replace function public.admin_apply_inventory_count(
  p_items jsonb,
  p_note text default null
)
returns table(
  product_id uuid,
  name text,
  soll_warehouse_stock integer,
  ist_warehouse_stock integer,
  delta_warehouse integer,
  soll_fridge_stock integer,
  ist_fridge_stock integer,
  delta_fridge integer
)
language plpgsql
security definer
as $function$
declare
  v_wh uuid;
  v_fr uuid;
  v_item record;
  v_product record;
  v_stock record;
  v_ist_wh integer;
  v_ist_fr integer;
  v_delta_wh integer;
  v_delta_fr integer;
begin
  perform public.assert_admin();

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  v_fr := public.get_stock_location_id('fridge');
  if v_wh is null or v_fr is null then
    raise exception 'Stock locations are not configured';
  end if;

  for v_item in
    select *
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      ist_warehouse_stock integer,
      ist_fridge_stock integer
    )
  loop
    if v_item.product_id is null then
      raise exception 'product_id is required';
    end if;
    if v_item.ist_warehouse_stock is null or v_item.ist_fridge_stock is null then
      raise exception 'ist_warehouse_stock and ist_fridge_stock are required';
    end if;
    if v_item.ist_warehouse_stock < 0 or v_item.ist_fridge_stock < 0 then
      raise exception 'Ist stock cannot be negative';
    end if;

    select p.id, p.name
    into v_product
    from public.products p
    where p.id = v_item.product_id
      and p.inventoried = true
    limit 1;

    if v_product.id is null then
      raise exception 'Inventoried product not found: %', v_item.product_id;
    end if;

    select warehouse_qty, fridge_qty
    into v_stock
    from public.get_product_stock(v_item.product_id);

    v_ist_wh := v_item.ist_warehouse_stock;
    v_ist_fr := v_item.ist_fridge_stock;
    v_delta_wh := v_ist_wh - coalesce(v_stock.warehouse_qty, 0);
    v_delta_fr := v_ist_fr - coalesce(v_stock.fridge_qty, 0);

    if v_delta_wh <> 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_wh),
        case when v_delta_wh < 0 then v_wh else null end,
        case when v_delta_wh > 0 then v_wh else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Lager'),
        auth.uid(),
        jsonb_build_object(
          'source', 'inventory_count',
          'location', 'warehouse',
          'expected', coalesce(v_stock.warehouse_qty, 0),
          'counted', v_ist_wh,
          'delta', v_delta_wh
        )
      );
    end if;

    if v_delta_fr <> 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_fr),
        case when v_delta_fr < 0 then v_fr else null end,
        case when v_delta_fr > 0 then v_fr else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Kuehlschrank'),
        auth.uid(),
        jsonb_build_object(
          'source', 'inventory_count',
          'location', 'fridge',
          'expected', coalesce(v_stock.fridge_qty, 0),
          'counted', v_ist_fr,
          'delta', v_delta_fr
        )
      );
    end if;

    product_id := v_item.product_id;
    name := v_product.name;
    soll_warehouse_stock := coalesce(v_stock.warehouse_qty, 0);
    ist_warehouse_stock := v_ist_wh;
    delta_warehouse := v_delta_wh;
    soll_fridge_stock := coalesce(v_stock.fridge_qty, 0);
    ist_fridge_stock := v_ist_fr;
    delta_fridge := v_delta_fr;
    return next;
  end loop;

  return;
end;
$function$;

create or replace function public.get_inventory_adjustments_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language sql
security definer
as $function$
with
  loc as (
    select
      public.get_stock_location_id('warehouse') as wh_id,
      public.get_stock_location_id('fridge') as fr_id
  )
select
  im.created_at,
  (im.created_at at time zone 'Europe/Berlin')::date as local_day,
  im.product_id,
  coalesce(p.name, '[Geloeschtes Produkt]') as product_name,
  coalesce(p.category, 'Unbekannt') as product_category,
  coalesce(p.active, false) as active,
  case
    when im.to_location_id = loc.wh_id or im.from_location_id = loc.wh_id then 'warehouse'
    when im.to_location_id = loc.fr_id or im.from_location_id = loc.fr_id then 'fridge'
    else 'unknown'
  end as location,
  (
    case
      when im.to_location_id is not null then im.quantity
      else 0
    end
    -
    case
      when im.from_location_id is not null then im.quantity
      else 0
    end
  )::int as delta,
  case
    when (
      case
        when im.to_location_id is not null then im.quantity
        else 0
      end
      -
      case
        when im.from_location_id is not null then im.quantity
        else 0
      end
    ) < 0 then 'fehlbestand'
    when (
      case
        when im.to_location_id is not null then im.quantity
        else 0
      end
      -
      case
        when im.from_location_id is not null then im.quantity
        else 0
      end
    ) > 0 then 'ueberbestand'
    else 'neutral'
  end as adjustment_kind,
  im.reason,
  im.note,
  coalesce(im.meta->>'source', 'unknown') as source
from public.inventory_movements im
cross join loc
left join public.products p on p.id = im.product_id
where im.created_at >= p_start
  and im.created_at < p_end
  and im.reason in ('count_adjustment', 'shrinkage', 'waste')
order by im.created_at desc;
$function$;

create or replace function public.admin_get_inventory_adjustments_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_inventory_adjustments_period(p_start, p_end);
end;
$function$;

drop function if exists public.admin_get_inventory_snapshot();

create or replace function public.get_inventory_snapshot()
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  soll_warehouse_stock integer,
  soll_fridge_stock integer,
  soll_total_stock integer
)
language sql
security definer
as $function$
with
  loc as (
    select
      public.get_stock_location_id('warehouse') as wh_id,
      public.get_stock_location_id('fridge') as fr_id
  ),
  mv_total as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.to_location_id = loc.wh_id then im.quantity
          when im.from_location_id = loc.wh_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_warehouse_stock,
      coalesce(sum(
        case
          when im.to_location_id = loc.fr_id then im.quantity
          when im.from_location_id = loc.fr_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_fridge_stock
    from public.inventory_movements im
    cross join loc
    group by im.product_id
  )
select
  p.id as product_id,
  p.name as name,
  p.category as category,
  p.active as active,
  coalesce(mv_total.soll_warehouse_stock, 0)::int as soll_warehouse_stock,
  coalesce(mv_total.soll_fridge_stock, 0)::int as soll_fridge_stock,
  (coalesce(mv_total.soll_warehouse_stock, 0) + coalesce(mv_total.soll_fridge_stock, 0))::int as soll_total_stock
from public.products p
left join mv_total on mv_total.product_id = p.id
where p.inventoried = true
order by p.active desc, p.category, p.name;
$function$;

create or replace function public.admin_get_inventory_snapshot()
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  soll_warehouse_stock integer,
  soll_fridge_stock integer,
  soll_total_stock integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_inventory_snapshot();
end;
$function$;

revoke all on function public.get_inventory_snapshot() from public;

revoke all on function public.admin_get_inventory_snapshot() from public;
grant execute on function public.admin_get_inventory_snapshot() to authenticated;

revoke all on function public.admin_apply_inventory_count(jsonb, text) from public;
grant execute on function public.admin_apply_inventory_count(jsonb, text) to authenticated;

revoke all on function public.get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) from public;

revoke all on function public.admin_get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) to authenticated;
-- <<< END 20260215016000_inventory_count_and_adjustments_reports.sql


-- >>> BEGIN 20260215017000_add_member_id_to_stock_adjustments.sql
-- Track who performed a refill on stock_adjustments.
alter table public.stock_adjustments
  add column if not exists member_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'stock_adjustments_member_id_fkey'
      and conrelid = 'public.stock_adjustments'::regclass
  ) then
    alter table public.stock_adjustments
      add constraint stock_adjustments_member_id_fkey
      foreign key (member_id) references public.members(id);
  end if;
end
$$;

create index if not exists stock_adjustments_member_id_idx
  on public.stock_adjustments(member_id);
-- <<< END 20260215017000_add_member_id_to_stock_adjustments.sql


-- >>> BEGIN 20260215018000_member_safe_refill_history_and_report.sql
-- Make stock_adjustments resilient to member deletion and expose refiller info in stock report.

alter table public.stock_adjustments
  add column if not exists member_name_snapshot text null;

-- Backfill member snapshot name where possible.
update public.stock_adjustments sa
set member_name_snapshot = nullif(trim(concat_ws(' ', m.firstname, m.lastname)), '')
from public.members m
where sa.member_id = m.id
  and sa.member_name_snapshot is null;

update public.stock_adjustments sa
set member_name_snapshot = nullif(trim(concat_ws(' ', ma.firstname, ma.lastname)), '')
from public.members_archive ma
where sa.member_id = ma.id
  and sa.member_name_snapshot is null;

alter table public.stock_adjustments
  alter column member_id drop not null;

alter table public.stock_adjustments
  drop constraint if exists stock_adjustments_member_id_fkey;

alter table public.stock_adjustments
  add constraint stock_adjustments_member_id_fkey
  foreign key (member_id)
  references public.members (id)
  on delete set null;

create or replace function public.trg_set_stock_adjustment_member_snapshot()
returns trigger
language plpgsql
as $function$
begin
  if new.member_id is null then
    return new;
  end if;

  if new.member_name_snapshot is null then
    select nullif(trim(concat_ws(' ', m.firstname, m.lastname)), '')
    into new.member_name_snapshot
    from public.members m
    where m.id = new.member_id;
  end if;

  return new;
end;
$function$;

drop trigger if exists tg_set_stock_adjustment_member_snapshot on public.stock_adjustments;
create trigger tg_set_stock_adjustment_member_snapshot
before insert on public.stock_adjustments
for each row
execute function public.trg_set_stock_adjustment_member_snapshot();

drop function if exists public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone);
drop function if exists public.get_stock_report_period(timestamp with time zone, timestamp with time zone);

create or replace function public.get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  warehouse_stock integer,
  soll_warehouse_stock integer,
  delta_warehouse integer,
  fridge_stock integer,
  soll_fridge_stock integer,
  delta_fridge integer,
  current_stock integer,
  consumed integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer,
  refilled_by text
)
language sql
security definer
as $function$
with
  loc as (
    select
      public.get_stock_location_id('warehouse') as wh_id,
      public.get_stock_location_id('fridge') as fr_id
  ),
  mv_period as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.reason = 'purchase' and im.to_location_id = loc.wh_id then im.quantity
          else 0
        end
      ), 0)::int as purchased,
      coalesce(sum(
        case
          when im.reason = 'transfer'
           and im.from_location_id = loc.wh_id
           and im.to_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as transferred_to_fridge,
      coalesce(sum(
        case
          when im.reason = 'sale'
           and im.from_location_id = loc.fr_id
          then im.quantity
          else 0
        end
      ), 0)::int as consumed_mv,
      coalesce(sum(
        case
          when im.reason in ('shrinkage', 'waste', 'count_adjustment')
          then im.quantity
          else 0
        end
      ), 0)::int as shrinkage
    from public.inventory_movements im
    cross join loc
    where im.created_at >= p_start
      and im.created_at < p_end
    group by im.product_id
  ),
  mv_total as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.to_location_id = loc.wh_id then im.quantity
          when im.from_location_id = loc.wh_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_warehouse_stock,
      coalesce(sum(
        case
          when im.to_location_id = loc.fr_id then im.quantity
          when im.from_location_id = loc.fr_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_fridge_stock
    from public.inventory_movements im
    cross join loc
    group by im.product_id
  ),
  tx as (
    -- Legacy fallback for older data before movement backfill
    select
      t.product_id,
      count(*)::int as consumed_tx
    from public.transactions t
    where t.product_id is not null
      and t.amount < 0
      and t.created_at >= p_start
      and t.created_at < p_end
    group by t.product_id
  ),
  sa_period as (
    select
      sa.product_id,
      string_agg(
        distinct coalesce(
          nullif(sa.member_name_snapshot, ''),
          nullif(trim(concat_ws(' ', m.firstname, m.lastname)), ''),
          nullif(trim(concat_ws(' ', ma.firstname, ma.lastname)), ''),
          'Unbekannt'
        ),
        ', '
      ) as refilled_by
    from public.stock_adjustments sa
    left join public.members m
      on m.id = sa.member_id
    left join public.members_archive ma
      on ma.id = sa.member_id
    where sa.created_at >= p_start
      and sa.created_at < p_end
      and sa.quantity > 0
      and sa.product_id is not null
    group by sa.product_id
  )
select
  p.id as product_id,
  p.name as name,
  p.category as category,
  p.active as active,
  coalesce(p.warehouse_stock, 0)::int as warehouse_stock,
  coalesce(mv_total.soll_warehouse_stock, 0)::int as soll_warehouse_stock,
  (coalesce(p.warehouse_stock, 0) - coalesce(mv_total.soll_warehouse_stock, 0))::int as delta_warehouse,
  coalesce(p.fridge_stock, 0)::int as fridge_stock,
  coalesce(mv_total.soll_fridge_stock, 0)::int as soll_fridge_stock,
  (coalesce(p.fridge_stock, 0) - coalesce(mv_total.soll_fridge_stock, 0))::int as delta_fridge,
  (coalesce(p.warehouse_stock, 0) + coalesce(p.fridge_stock, 0))::int as current_stock,
  greatest(coalesce(mv_period.consumed_mv, 0), coalesce(tx.consumed_tx, 0))::int as consumed,
  coalesce(mv_period.transferred_to_fridge, 0)::int as transferred_to_fridge,
  coalesce(mv_period.purchased, 0)::int as purchased,
  coalesce(mv_period.shrinkage, 0)::int as shrinkage,
  coalesce(sa_period.refilled_by, '-') as refilled_by
from public.products p
left join mv_period on mv_period.product_id = p.id
left join mv_total on mv_total.product_id = p.id
left join tx on tx.product_id = p.id
left join sa_period on sa_period.product_id = p.id
where p.inventoried = true
order by p.active desc, p.category, p.name;
$function$;

create or replace function public.admin_get_stock_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  warehouse_stock integer,
  soll_warehouse_stock integer,
  delta_warehouse integer,
  fridge_stock integer,
  soll_fridge_stock integer,
  delta_fridge integer,
  current_stock integer,
  consumed integer,
  transferred_to_fridge integer,
  purchased integer,
  shrinkage integer,
  refilled_by text
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_stock_report_period(p_start, p_end);
end;
$function$;

revoke all on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_stock_report_period(timestamp with time zone, timestamp with time zone) to authenticated;

notify pgrst, 'reload schema';
-- <<< END 20260215018000_member_safe_refill_history_and_report.sql


-- >>> BEGIN 20260215019000_add_admin_fridge_refills_report.sql
-- Admin report for fridge refills (positive stock adjustments).

drop function if exists public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone);
drop function if exists public.get_fridge_refills_period(timestamp with time zone, timestamp with time zone);

create or replace function public.get_fridge_refills_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  stock_adjustment_id uuid,
  product_id uuid,
  product_name text,
  product_category text,
  quantity integer,
  member_id uuid,
  member_name text,
  device_id uuid,
  device_name text,
  note text
)
language sql
security definer
as $function$
select
  sa.created_at,
  (sa.created_at at time zone 'Europe/Berlin')::date as local_day,
  sa.id as stock_adjustment_id,
  sa.product_id,
  coalesce(p.name, sa.product_name_snapshot, 'Unbekanntes Produkt') as product_name,
  coalesce(p.category, sa.product_category_snapshot, '-') as product_category,
  sa.quantity::int as quantity,
  sa.member_id,
  coalesce(
    nullif(sa.member_name_snapshot, ''),
    nullif(trim(concat_ws(' ', m.firstname, m.lastname)), ''),
    nullif(trim(concat_ws(' ', ma.firstname, ma.lastname)), ''),
    'Unbekannt'
  ) as member_name,
  sa.device_id,
  kd.name as device_name,
  sa.note
from public.stock_adjustments sa
left join public.products p
  on p.id = sa.product_id
left join public.members m
  on m.id = sa.member_id
left join public.members_archive ma
  on ma.id = sa.member_id
left join public.kiosk_devices kd
  on kd.id = sa.device_id
where sa.created_at >= p_start
  and sa.created_at < p_end
  and sa.quantity > 0
order by sa.created_at desc;
$function$;

create or replace function public.admin_get_fridge_refills_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  stock_adjustment_id uuid,
  product_id uuid,
  product_name text,
  product_category text,
  quantity integer,
  member_id uuid,
  member_name text,
  device_id uuid,
  device_name text,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_fridge_refills_period(p_start, p_end);
end;
$function$;

revoke all on function public.get_fridge_refills_period(timestamp with time zone, timestamp with time zone) from public;
revoke all on function public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone) to authenticated;
-- <<< END 20260215019000_add_admin_fridge_refills_report.sql


-- >>> BEGIN 20260215020000_harden_rls_and_migrate_to_app_auth.sql
-- Hard migration: remove Supabase-auth coupling and move to app-managed auth/session context.
-- No fallback path is kept.

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 1) App-managed auth tables
-- ------------------------------------------------------------
create table if not exists public.app_users (
  id uuid not null default gen_random_uuid(),
  username text not null,
  password_hash text not null,
  role text not null,
  active boolean not null default true,
  created_at timestamp with time zone not null default now(),
  last_login_at timestamp with time zone null,
  constraint app_users_pkey primary key (id),
  constraint app_users_username_key unique (username),
  constraint app_users_role_chk check (role in ('admin', 'operator', 'device', 'service'))
);

create table if not exists public.app_sessions (
  id uuid not null default gen_random_uuid(),
  token_hash text not null,
  actor_type text not null,
  actor_id uuid not null,
  role text not null,
  expires_at timestamp with time zone not null,
  revoked_at timestamp with time zone null,
  created_at timestamp with time zone not null default now(),
  last_seen_at timestamp with time zone null,
  user_agent text null,
  ip inet null,
  constraint app_sessions_pkey primary key (id),
  constraint app_sessions_token_hash_key unique (token_hash),
  constraint app_sessions_actor_type_chk check (actor_type in ('user', 'device')),
  constraint app_sessions_role_chk check (role in ('admin', 'operator', 'device', 'service'))
);

create index if not exists app_sessions_actor_idx on public.app_sessions(actor_type, actor_id);
create index if not exists app_sessions_expires_idx on public.app_sessions(expires_at);

-- ------------------------------------------------------------
-- 2) Device credential migration (drop legacy plaintext secret)
-- ------------------------------------------------------------
alter table public.kiosk_devices
  add column if not exists secret_hash text;

update public.kiosk_devices
set secret_hash = crypt(device_secret, gen_salt('bf'))
where secret_hash is null
  and device_secret is not null;

alter table public.kiosk_devices
  alter column secret_hash set not null;

alter table public.kiosk_devices
  drop column if exists device_secret;

-- ------------------------------------------------------------
-- 3) Backfill app_users from existing actor UUIDs
-- ------------------------------------------------------------
with actor_ids as (
  select user_id as id from public.admins
  union
  select user_id as id from public.settlements
  union
  select deleted_by as id from public.members_archive where deleted_by is not null
  union
  select deleted_by as id from public.products_archive where deleted_by is not null
  union
  select created_by as id from public.inventory_movements where created_by is not null
)
insert into public.app_users (id, username, password_hash, role, active)
select
  a.id,
  'legacy-' || substr(a.id::text, 1, 8) as username,
  crypt(encode(gen_random_bytes(24), 'hex'), gen_salt('bf')) as password_hash,
  case when exists (select 1 from public.admins ad where ad.user_id = a.id) then 'admin' else 'operator' end as role,
  true as active
from actor_ids a
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- 4) Remove auth.users coupling (FKs -> app_users)
-- ------------------------------------------------------------
alter table public.members_archive
  drop constraint if exists members_archive_deleted_by_fkey;
alter table public.products_archive
  drop constraint if exists products_archive_deleted_by_fkey;
alter table public.inventory_movements
  drop constraint if exists inventory_movements_created_by_fkey;
alter table public.settlements
  drop constraint if exists settlements_user_id_fkey;

alter table public.members_archive
  add constraint members_archive_deleted_by_fkey
  foreign key (deleted_by) references public.app_users(id);

alter table public.products_archive
  add constraint products_archive_deleted_by_fkey
  foreign key (deleted_by) references public.app_users(id);

alter table public.inventory_movements
  add constraint inventory_movements_created_by_fkey
  foreign key (created_by) references public.app_users(id);

alter table public.settlements
  add constraint settlements_user_id_fkey
  foreign key (user_id) references public.app_users(id);

alter table public.admins
  drop constraint if exists admins_user_id_fkey;
alter table public.admins
  add constraint admins_user_id_fkey
  foreign key (user_id) references public.app_users(id) on delete cascade;

-- ------------------------------------------------------------
-- 5) Session context helpers (app.*)
-- ------------------------------------------------------------
create or replace function public.app_current_role()
returns text
language sql
stable
as $function$
select nullif(current_setting('app.role', true), '');
$function$;

create or replace function public.app_current_user_id()
returns uuid
language plpgsql
stable
as $function$
declare
  v text;
begin
  v := nullif(current_setting('app.user_id', true), '');
  if v is null then
    return null;
  end if;
  return v::uuid;
exception when others then
  return null;
end;
$function$;

create or replace function public.app_current_device_id()
returns uuid
language plpgsql
stable
as $function$
declare
  v text;
begin
  v := nullif(current_setting('app.device_id', true), '');
  if v is null then
    return null;
  end if;
  return v::uuid;
exception when others then
  return null;
end;
$function$;

create or replace function public.app_apply_session(p_token text)
returns table(actor_type text, actor_id uuid, role text)
language plpgsql
security definer
as $function$
declare
  v_hash text;
  v_sess record;
begin
  if nullif(trim(coalesce(p_token, '')), '') is null then
    raise exception 'Unauthorized';
  end if;

  v_hash := encode(digest(p_token, 'sha256'), 'hex');

  select s.*
  into v_sess
  from public.app_sessions s
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > now()
  limit 1;

  if v_sess.id is null then
    raise exception 'Unauthorized';
  end if;

  update public.app_sessions
  set last_seen_at = now()
  where id = v_sess.id;

  perform set_config('app.role', v_sess.role, true);
  if v_sess.actor_type = 'user' then
    perform set_config('app.user_id', v_sess.actor_id::text, true);
    perform set_config('app.device_id', '', true);
  else
    perform set_config('app.user_id', '', true);
    perform set_config('app.device_id', v_sess.actor_id::text, true);
  end if;

  actor_type := v_sess.actor_type;
  actor_id := v_sess.actor_id;
  role := v_sess.role;
  return next;
end;
$function$;

create or replace function public.app_login_user(
  p_username text,
  p_password text,
  p_ttl_hours integer default 8
)
returns text
language plpgsql
security definer
as $function$
declare
  v_user public.app_users%rowtype;
  v_token text;
begin
  select *
  into v_user
  from public.app_users u
  where lower(u.username) = lower(trim(coalesce(p_username, '')))
    and u.active = true
  limit 1;

  if v_user.id is null or v_user.password_hash <> crypt(coalesce(p_password, ''), v_user.password_hash) then
    raise exception 'Unauthorized';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');

  insert into public.app_sessions (
    token_hash,
    actor_type,
    actor_id,
    role,
    expires_at
  ) values (
    encode(digest(v_token, 'sha256'), 'hex'),
    'user',
    v_user.id,
    v_user.role,
    now() + make_interval(hours => greatest(coalesce(p_ttl_hours, 8), 1))
  );

  update public.app_users
  set last_login_at = now()
  where id = v_user.id;

  return v_token;
end;
$function$;

create or replace function public.app_login_device(
  p_device_name text,
  p_device_secret text,
  p_ttl_days integer default 30
)
returns text
language plpgsql
security definer
as $function$
declare
  v_device public.kiosk_devices%rowtype;
  v_token text;
begin
  select *
  into v_device
  from public.kiosk_devices kd
  where lower(kd.name) = lower(trim(coalesce(p_device_name, '')))
    and kd.active = true
  limit 1;

  if v_device.id is null or v_device.secret_hash <> crypt(coalesce(p_device_secret, ''), v_device.secret_hash) then
    raise exception 'Unauthorized';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');

  insert into public.app_sessions (
    token_hash,
    actor_type,
    actor_id,
    role,
    expires_at
  ) values (
    encode(digest(v_token, 'sha256'), 'hex'),
    'device',
    v_device.id,
    'device',
    now() + make_interval(days => greatest(coalesce(p_ttl_days, 30), 1))
  );

  update public.kiosk_devices
  set last_seen_at = now()
  where id = v_device.id;

  return v_token;
end;
$function$;

create or replace function public.app_logout(p_token text)
returns void
language plpgsql
security definer
as $function$
begin
  if nullif(trim(coalesce(p_token, '')), '') is null then
    return;
  end if;

  update public.app_sessions
  set revoked_at = now()
  where token_hash = encode(digest(p_token, 'sha256'), 'hex')
    and revoked_at is null;
end;
$function$;

-- ------------------------------------------------------------
-- 6) Guards migrated to app.* context
-- ------------------------------------------------------------
create or replace function public.assert_admin()
returns void
language plpgsql
security definer
as $function$
declare
  v_user_id uuid;
begin
  v_user_id := public.app_current_user_id();

  if public.app_current_role() is null or v_user_id is null then
    raise exception 'Unauthorized';
  end if;

  if public.app_current_role() <> 'admin' then
    raise exception 'Forbidden';
  end if;

  if not exists (
    select 1
    from public.admins a
    where a.user_id = v_user_id
  ) then
    raise exception 'Forbidden';
  end if;
end;
$function$;

create or replace function public.assert_device()
returns void
language plpgsql
security definer
as $function$
declare
  v_device_id uuid;
begin
  v_device_id := public.app_current_device_id();

  if public.app_current_role() is null or v_device_id is null then
    raise exception 'Unauthorized';
  end if;

  if public.app_current_role() <> 'device' then
    raise exception 'Forbidden';
  end if;

  if not exists (
    select 1
    from public.kiosk_devices kd
    where kd.id = v_device_id
      and kd.active = true
  ) then
    raise exception 'Forbidden';
  end if;
end;
$function$;

-- ------------------------------------------------------------
-- 7) Rebind auth-sensitive functions
-- ------------------------------------------------------------
create or replace function public.delete_member_safely(
  p_member_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
declare
  v_member public.members%rowtype;
  v_open_tx integer;
begin
  perform public.assert_admin();

  select *
  into v_member
  from public.members m
  where m.id = p_member_id;

  if not found then
    raise exception 'Mitglied nicht gefunden';
  end if;

  if not p_force and coalesce(v_member.balance, 0) <> 0 then
    raise exception 'Mitglied hat noch einen Saldo. Fuer hard delete p_force=true setzen.';
  end if;

  if not p_force then
    select count(*)::int
    into v_open_tx
    from public.transactions t
    where t.member_id = p_member_id
      and t.settled_at is null;

    if coalesce(v_open_tx, 0) > 0 then
      raise exception 'Mitglied hat noch offene Buchungen. Fuer hard delete p_force=true setzen.';
    end if;
  end if;

  insert into public.members_archive (
    id, firstname, lastname, is_guest, active, balance, settled, created_at, last_settled_at, deleted_at, deleted_by
  ) values (
    v_member.id, v_member.firstname, v_member.lastname, v_member.is_guest, v_member.active, v_member.balance, v_member.settled, v_member.created_at, v_member.last_settled_at, now(), public.app_current_user_id()
  )
  on conflict (id) do update
  set
    firstname = excluded.firstname,
    lastname = excluded.lastname,
    is_guest = excluded.is_guest,
    active = excluded.active,
    balance = excluded.balance,
    settled = excluded.settled,
    created_at = excluded.created_at,
    last_settled_at = excluded.last_settled_at,
    deleted_at = excluded.deleted_at,
    deleted_by = excluded.deleted_by;

  delete from public.members m
  where m.id = p_member_id;
end;
$function$;

create or replace function public.delete_product_safely(
  p_product_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
declare
  v_product public.products%rowtype;
begin
  perform public.assert_admin();

  select *
  into v_product
  from public.products p
  where p.id = p_product_id;

  if not found then
    raise exception 'Produkt nicht gefunden';
  end if;

  if not p_force and (coalesce(v_product.warehouse_stock, 0) <> 0 or coalesce(v_product.fridge_stock, 0) <> 0) then
    raise exception 'Produkt hat noch Bestand. Fuer hard delete p_force=true setzen.';
  end if;

  insert into public.products_archive (
    id, name, price, guest_price, category, active, inventoried, created_at, deleted_at, deleted_by
  ) values (
    v_product.id, v_product.name, v_product.price, v_product.guest_price, v_product.category, v_product.active, v_product.inventoried, v_product.created_at, now(), public.app_current_user_id()
  )
  on conflict (id) do update
  set
    name = excluded.name,
    price = excluded.price,
    guest_price = excluded.guest_price,
    category = excluded.category,
    active = excluded.active,
    inventoried = excluded.inventoried,
    created_at = excluded.created_at,
    deleted_at = excluded.deleted_at,
    deleted_by = excluded.deleted_by;

  delete from public.products p
  where p.id = p_product_id;
end;
$function$;

create or replace function public.admin_perform_monthly_settlement()
returns void
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  perform public.perform_monthly_settlement(public.app_current_user_id());
end;
$function$;

create or replace function public.admin_apply_inventory_count(
  p_items jsonb,
  p_note text default null
)
returns table(
  product_id uuid,
  name text,
  soll_warehouse_stock integer,
  ist_warehouse_stock integer,
  delta_warehouse integer,
  soll_fridge_stock integer,
  ist_fridge_stock integer,
  delta_fridge integer
)
language plpgsql
security definer
as $function$
declare
  v_wh uuid;
  v_fr uuid;
  v_item record;
  v_product record;
  v_stock record;
  v_ist_wh integer;
  v_ist_fr integer;
  v_delta_wh integer;
  v_delta_fr integer;
begin
  perform public.assert_admin();

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  v_fr := public.get_stock_location_id('fridge');
  if v_wh is null or v_fr is null then
    raise exception 'Stock locations are not configured';
  end if;

  for v_item in
    select *
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      ist_warehouse_stock integer,
      ist_fridge_stock integer
    )
  loop
    if v_item.product_id is null then
      raise exception 'product_id is required';
    end if;
    if v_item.ist_warehouse_stock is null or v_item.ist_fridge_stock is null then
      raise exception 'ist_warehouse_stock and ist_fridge_stock are required';
    end if;
    if v_item.ist_warehouse_stock < 0 or v_item.ist_fridge_stock < 0 then
      raise exception 'Ist stock cannot be negative';
    end if;

    select p.id, p.name
    into v_product
    from public.products p
    where p.id = v_item.product_id
      and p.inventoried = true
    limit 1;

    if v_product.id is null then
      raise exception 'Inventoried product not found: %', v_item.product_id;
    end if;

    select warehouse_qty, fridge_qty
    into v_stock
    from public.get_product_stock(v_item.product_id);

    v_ist_wh := v_item.ist_warehouse_stock;
    v_ist_fr := v_item.ist_fridge_stock;
    v_delta_wh := v_ist_wh - coalesce(v_stock.warehouse_qty, 0);
    v_delta_fr := v_ist_fr - coalesce(v_stock.fridge_qty, 0);

    if v_delta_wh <> 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_wh),
        case when v_delta_wh < 0 then v_wh else null end,
        case when v_delta_wh > 0 then v_wh else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Lager'),
        public.app_current_user_id(),
        jsonb_build_object(
          'source', 'inventory_count',
          'location', 'warehouse',
          'expected', coalesce(v_stock.warehouse_qty, 0),
          'counted', v_ist_wh,
          'delta', v_delta_wh
        )
      );
    end if;

    if v_delta_fr <> 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_fr),
        case when v_delta_fr < 0 then v_fr else null end,
        case when v_delta_fr > 0 then v_fr else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Kuehlschrank'),
        public.app_current_user_id(),
        jsonb_build_object(
          'source', 'inventory_count',
          'location', 'fridge',
          'expected', coalesce(v_stock.fridge_qty, 0),
          'counted', v_ist_fr,
          'delta', v_delta_fr
        )
      );
    end if;

    product_id := v_item.product_id;
    name := v_product.name;
    soll_warehouse_stock := coalesce(v_stock.warehouse_qty, 0);
    ist_warehouse_stock := v_ist_wh;
    delta_warehouse := v_delta_wh;
    soll_fridge_stock := coalesce(v_stock.fridge_qty, 0);
    ist_fridge_stock := v_ist_fr;
    delta_fridge := v_delta_fr;
    return next;
  end loop;

  return;
end;
$function$;

-- ------------------------------------------------------------
-- 8) RLS hardening (deny direct table access)
-- ------------------------------------------------------------
drop policy if exists read_own_admin_row on public.admins;
drop policy if exists no_direct_insert_stock_adjustments on public.stock_adjustments;
drop policy if exists read_stock_adjustments_admins on public.stock_adjustments;

alter table public.admins enable row level security;
alter table public.kiosk_devices enable row level security;
alter table public.products enable row level security;
alter table public.members enable row level security;
alter table public.stock_adjustments enable row level security;
alter table public.settlements enable row level security;
alter table public.transactions enable row level security;
alter table public.members_archive enable row level security;
alter table public.products_archive enable row level security;
alter table public.stock_locations enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.app_users enable row level security;
alter table public.app_sessions enable row level security;

revoke all on table public.admins from public;
revoke all on table public.kiosk_devices from public;
revoke all on table public.products from public;
revoke all on table public.members from public;
revoke all on table public.stock_adjustments from public;
revoke all on table public.settlements from public;
revoke all on table public.transactions from public;
revoke all on table public.members_archive from public;
revoke all on table public.products_archive from public;
revoke all on table public.stock_locations from public;
revoke all on table public.inventory_movements from public;
revoke all on table public.app_users from public;
revoke all on table public.app_sessions from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.admins from anon';
    execute 'revoke all on table public.kiosk_devices from anon';
    execute 'revoke all on table public.products from anon';
    execute 'revoke all on table public.members from anon';
    execute 'revoke all on table public.stock_adjustments from anon';
    execute 'revoke all on table public.settlements from anon';
    execute 'revoke all on table public.transactions from anon';
    execute 'revoke all on table public.members_archive from anon';
    execute 'revoke all on table public.products_archive from anon';
    execute 'revoke all on table public.stock_locations from anon';
    execute 'revoke all on table public.inventory_movements from anon';
    execute 'revoke all on table public.app_users from anon';
    execute 'revoke all on table public.app_sessions from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.admins from authenticated';
    execute 'revoke all on table public.kiosk_devices from authenticated';
    execute 'revoke all on table public.products from authenticated';
    execute 'revoke all on table public.members from authenticated';
    execute 'revoke all on table public.stock_adjustments from authenticated';
    execute 'revoke all on table public.settlements from authenticated';
    execute 'revoke all on table public.transactions from authenticated';
    execute 'revoke all on table public.members_archive from authenticated';
    execute 'revoke all on table public.products_archive from authenticated';
    execute 'revoke all on table public.stock_locations from authenticated';
    execute 'revoke all on table public.inventory_movements from authenticated';
    execute 'revoke all on table public.app_users from authenticated';
    execute 'revoke all on table public.app_sessions from authenticated';
  end if;
end
$$;

-- Supabase role grants removed; function execution is now meant for backend DB role only.
revoke all on function public.assert_admin() from public;
revoke all on function public.assert_device() from public;
revoke all on function public.app_login_user(text, text, integer) from public;
revoke all on function public.app_login_device(text, text, integer) from public;
revoke all on function public.app_apply_session(text) from public;
revoke all on function public.app_logout(text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.assert_admin() from anon';
    execute 'revoke all on function public.assert_device() from anon';
    execute 'revoke all on function public.app_login_user(text, text, integer) from anon';
    execute 'revoke all on function public.app_login_device(text, text, integer) from anon';
    execute 'revoke all on function public.app_apply_session(text) from anon';
    execute 'revoke all on function public.app_logout(text) from anon';
    execute 'revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid) from anon';
    execute 'revoke all on function public.cancel_transaction(uuid, uuid, uuid, text) from anon';
    execute 'revoke all on function public.admin_list_members() from anon';
    execute 'revoke all on function public.admin_create_member(text, text) from anon';
    execute 'revoke all on function public.admin_update_member(uuid, text, text, integer, boolean) from anon';
    execute 'revoke all on function public.admin_delete_member(uuid, boolean) from anon';
    execute 'revoke all on function public.admin_list_products() from anon';
    execute 'revoke all on function public.admin_create_product(text, integer, integer, text, boolean, boolean) from anon';
    execute 'revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean) from anon';
    execute 'revoke all on function public.admin_delete_product(uuid, boolean) from anon';
    execute 'revoke all on function public.admin_get_all_bookings_grouped(timestamp with time zone, timestamp with time zone) from anon';
    execute 'revoke all on function public.admin_perform_monthly_settlement() from anon';
    execute 'revoke all on function public.admin_get_inventory_snapshot() from anon';
    execute 'revoke all on function public.admin_apply_inventory_count(jsonb, text) from anon';
    execute 'revoke all on function public.admin_get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) from anon';
    execute 'revoke all on function public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone) from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.assert_admin() from authenticated';
    execute 'revoke all on function public.assert_device() from authenticated';
    execute 'revoke all on function public.app_login_user(text, text, integer) from authenticated';
    execute 'revoke all on function public.app_login_device(text, text, integer) from authenticated';
    execute 'revoke all on function public.app_apply_session(text) from authenticated';
    execute 'revoke all on function public.app_logout(text) from authenticated';
    execute 'revoke all on function public.book_transaction(uuid, uuid, integer, text, uuid) from authenticated';
    execute 'revoke all on function public.cancel_transaction(uuid, uuid, uuid, text) from authenticated';
    execute 'revoke all on function public.admin_list_members() from authenticated';
    execute 'revoke all on function public.admin_create_member(text, text) from authenticated';
    execute 'revoke all on function public.admin_update_member(uuid, text, text, integer, boolean) from authenticated';
    execute 'revoke all on function public.admin_delete_member(uuid, boolean) from authenticated';
    execute 'revoke all on function public.admin_list_products() from authenticated';
    execute 'revoke all on function public.admin_create_product(text, integer, integer, text, boolean, boolean) from authenticated';
    execute 'revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean) from authenticated';
    execute 'revoke all on function public.admin_delete_product(uuid, boolean) from authenticated';
    execute 'revoke all on function public.admin_get_all_bookings_grouped(timestamp with time zone, timestamp with time zone) from authenticated';
    execute 'revoke all on function public.admin_perform_monthly_settlement() from authenticated';
    execute 'revoke all on function public.admin_get_inventory_snapshot() from authenticated';
    execute 'revoke all on function public.admin_apply_inventory_count(jsonb, text) from authenticated';
    execute 'revoke all on function public.admin_get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) from authenticated';
    execute 'revoke all on function public.admin_get_fridge_refills_period(timestamp with time zone, timestamp with time zone) from authenticated';
  end if;
end
$$;
-- <<< END 20260215020000_harden_rls_and_migrate_to_app_auth.sql


-- >>> BEGIN 20260215021000_add_admin_token_rpc_wrappers.sql
-- Token-based RPC wrappers for admin API endpoints.
-- These wrappers apply app session context and then call existing admin RPCs.

create or replace function public.api_admin_list_products(p_token text)
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_products();
end;
$function$;

create or replace function public.api_admin_create_product(
  p_token text,
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean
)
returns public.products
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_create_product(
    p_name,
    p_price,
    p_guest_price,
    p_category,
    p_active,
    p_inventoried
  );
end;
$function$;

create or replace function public.api_admin_update_product(
  p_token text,
  p_id uuid,
  p_name text default null,
  p_price integer default null,
  p_guest_price integer default null,
  p_category text default null,
  p_active boolean default null,
  p_inventoried boolean default null
)
returns public.products
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_update_product(
    p_id,
    p_name,
    p_price,
    p_guest_price,
    p_category,
    p_active,
    p_inventoried
  );
end;
$function$;

create or replace function public.api_admin_delete_product(
  p_token text,
  p_product_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.admin_delete_product(p_product_id, p_force);
end;
$function$;

create or replace function public.api_admin_list_members()
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  raise exception 'Use api_admin_list_members_token(p_token)';
end;
$function$;

drop function if exists public.api_admin_list_members();

create or replace function public.api_admin_list_members_token(p_token text)
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_members();
end;
$function$;

create or replace function public.api_admin_create_member(
  p_token text,
  p_firstname text,
  p_lastname text
)
returns public.members
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_create_member(p_firstname, p_lastname);
end;
$function$;

create or replace function public.api_admin_update_member(
  p_token text,
  p_id uuid,
  p_firstname text default null,
  p_lastname text default null,
  p_balance integer default null,
  p_active boolean default null
)
returns public.members
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_update_member(
    p_id,
    p_firstname,
    p_lastname,
    p_balance,
    p_active
  );
end;
$function$;

create or replace function public.api_admin_delete_member(
  p_token text,
  p_member_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.admin_delete_member(p_member_id, p_force);
end;
$function$;

create or replace function public.api_admin_add_storage(
  p_token text,
  p_product_id uuid,
  p_amount integer
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  perform public.add_storage(p_product_id, p_amount);
end;
$function$;

revoke all on function public.api_admin_list_products(text) from public;
revoke all on function public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean) from public;
revoke all on function public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean) from public;
revoke all on function public.api_admin_delete_product(text, uuid, boolean) from public;
revoke all on function public.api_admin_list_members_token(text) from public;
revoke all on function public.api_admin_create_member(text, text, text) from public;
revoke all on function public.api_admin_update_member(text, uuid, text, text, integer, boolean) from public;
revoke all on function public.api_admin_delete_member(text, uuid, boolean) from public;
revoke all on function public.api_admin_add_storage(text, uuid, integer) from public;

create or replace function public.api_admin_get_inventory_snapshot(p_token text)
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  soll_warehouse_stock integer,
  soll_fridge_stock integer,
  soll_total_stock integer
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_inventory_snapshot();
end;
$function$;

create or replace function public.api_admin_apply_inventory_count(
  p_token text,
  p_items jsonb,
  p_note text default null
)
returns table(
  product_id uuid,
  name text,
  soll_warehouse_stock integer,
  ist_warehouse_stock integer,
  delta_warehouse integer,
  soll_fridge_stock integer,
  ist_fridge_stock integer,
  delta_fridge integer
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_apply_inventory_count(p_items, p_note);
end;
$function$;

create or replace function public.api_admin_get_inventory_adjustments_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_inventory_adjustments_period(p_start, p_end);
end;
$function$;

create or replace function public.api_admin_get_fridge_refills_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  stock_adjustment_id uuid,
  product_id uuid,
  product_name text,
  product_category text,
  quantity integer,
  member_id uuid,
  member_name text,
  device_id uuid,
  device_name text,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_fridge_refills_period(p_start, p_end);
end;
$function$;

create or replace function public.api_admin_get_all_bookings_grouped(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  local_day date,
  member_id uuid,
  member_name text,
  member_active boolean,
  total integer,
  items jsonb
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_all_bookings_grouped(p_start, p_end);
end;
$function$;

create or replace function public.api_admin_cancel_transaction(
  p_token text,
  p_cancel_tx_id uuid default null,
  p_member_id uuid default null,
  p_product_id uuid default null,
  p_note text default null
)
returns uuid
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return public.cancel_transaction(p_cancel_tx_id, p_member_id, p_product_id, p_note);
end;
$function$;

create or replace function public.api_admin_book_free_amount(
  p_token text,
  p_member_id uuid,
  p_amount_cents integer,
  p_note text default null
)
returns uuid
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return public.book_transaction(
    p_member_id,
    null,
    p_amount_cents,
    p_note,
    null
  );
end;
$function$;

create or replace function public.api_admin_perform_monthly_settlement(p_token text)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.admin_perform_monthly_settlement();
end;
$function$;

create or replace function public.api_admin_list_members_balances(p_token text)
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  last_settled_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select
    m.id,
    m.firstname,
    m.lastname,
    m.balance,
    m.last_settled_at
  from public.members m
  where m.balance <> 0
    and m.is_guest = false
  order by m.lastname asc, m.firstname asc;
end;
$function$;

create or replace function public.api_admin_list_member_pins(p_token text)
returns table(
  member_id uuid,
  pin_plain text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select mp.member_id, mp.pin_plain
  from public.member_pins mp;
end;
$function$;

create or replace function public.api_admin_upsert_member_pin(
  p_token text,
  p_member_id uuid,
  p_pin_plain text
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  insert into public.member_pins(member_id, pin_plain)
  values (p_member_id, p_pin_plain)
  on conflict (member_id) do update
  set pin_plain = excluded.pin_plain;
end;
$function$;

create or replace function public.api_admin_delete_member_pin(
  p_token text,
  p_member_id uuid
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  delete from public.member_pins
  where member_id = p_member_id;
end;
$function$;

revoke all on function public.api_admin_get_inventory_snapshot(text) from public;
revoke all on function public.api_admin_apply_inventory_count(text, jsonb, text) from public;
revoke all on function public.api_admin_get_inventory_adjustments_period(text, timestamp with time zone, timestamp with time zone) from public;
revoke all on function public.api_admin_get_fridge_refills_period(text, timestamp with time zone, timestamp with time zone) from public;
revoke all on function public.api_admin_get_all_bookings_grouped(text, timestamp with time zone, timestamp with time zone) from public;
revoke all on function public.api_admin_cancel_transaction(text, uuid, uuid, uuid, text) from public;
revoke all on function public.api_admin_book_free_amount(text, uuid, integer, text) from public;
revoke all on function public.api_admin_perform_monthly_settlement(text) from public;
revoke all on function public.api_admin_list_members_balances(text) from public;
revoke all on function public.api_admin_list_member_pins(text) from public;
revoke all on function public.api_admin_upsert_member_pin(text, uuid, text) from public;
revoke all on function public.api_admin_delete_member_pin(text, uuid) from public;

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

revoke all on function public.api_admin_stats_sales_trend(text, text) from public;
revoke all on function public.api_admin_stats_top_products_period(text, text) from public;
revoke all on function public.api_admin_stats_activity_heatmap_period(text, text) from public;
revoke all on function public.api_admin_stats_active_members_period(text, text) from public;
-- <<< END 20260215021000_add_admin_token_rpc_wrappers.sql


-- >>> BEGIN 20260215022000_harden_member_pins_storno_log_and_stock_overview.sql
-- Harden remaining unrestricted objects:
-- - member_pins (table)
-- - storno_log (table)
-- - stock_overview (view)
--
-- Strategy: deny direct client access (no table/view privileges for public/anon/authenticated).
-- Access should happen via controlled RPC/API only.

-- ------------------------------------------------------------
-- 1) member_pins
-- ------------------------------------------------------------
alter table if exists public.member_pins enable row level security;

drop policy if exists member_pins_select_all on public.member_pins;
drop policy if exists member_pins_insert_all on public.member_pins;
drop policy if exists member_pins_update_all on public.member_pins;
drop policy if exists member_pins_delete_all on public.member_pins;

revoke all on table public.member_pins from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.member_pins from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.member_pins from authenticated';
  end if;
end
$$;

-- ------------------------------------------------------------
-- 2) storno_log
-- ------------------------------------------------------------
alter table if exists public.storno_log enable row level security;

drop policy if exists storno_log_select_all on public.storno_log;
drop policy if exists storno_log_insert_all on public.storno_log;
drop policy if exists storno_log_update_all on public.storno_log;
drop policy if exists storno_log_delete_all on public.storno_log;

revoke all on table public.storno_log from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.storno_log from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.storno_log from authenticated';
  end if;
end
$$;

-- ------------------------------------------------------------
-- 3) stock_overview view
-- ------------------------------------------------------------
revoke all on table public.stock_overview from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.stock_overview from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.stock_overview from authenticated';
  end if;
end
$$;
-- <<< END 20260215022000_harden_member_pins_storno_log_and_stock_overview.sql


-- >>> BEGIN 20260215023000_fix_admin_stats_wrapper_return_types.sql
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
-- <<< END 20260215023000_fix_admin_stats_wrapper_return_types.sql


-- >>> BEGIN 20260215024000_add_device_key_login_for_app_sessions.sql
-- Support legacy "single device key" login against kiosk_devices.secret_hash
-- while issuing app_sessions tokens (no JWT verification required).

create or replace function public.app_login_device_key(
  p_device_key text,
  p_ttl_days integer default 30
)
returns table(
  token text,
  device_id uuid,
  device_name text
)
language plpgsql
security definer
as $function$
declare
  v_device public.kiosk_devices%rowtype;
  v_token text;
begin
  if nullif(trim(coalesce(p_device_key, '')), '') is null then
    raise exception 'Missing key';
  end if;

  select kd.*
  into v_device
  from public.kiosk_devices kd
  where kd.active = true
    and kd.secret_hash = crypt(p_device_key, kd.secret_hash)
  limit 1;

  if v_device.id is null then
    raise exception 'Unauthorized';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');

  insert into public.app_sessions (
    token_hash,
    actor_type,
    actor_id,
    role,
    expires_at
  ) values (
    encode(digest(v_token, 'sha256'), 'hex'),
    'device',
    v_device.id,
    'device',
    now() + make_interval(days => greatest(coalesce(p_ttl_days, 30), 1))
  );

  update public.kiosk_devices
  set last_seen_at = now()
  where id = v_device.id;

  token := v_token;
  device_id := v_device.id;
  device_name := v_device.name;
  return next;
end;
$function$;

revoke all on function public.app_login_device_key(text, integer) from public;
-- <<< END 20260215024000_add_device_key_login_for_app_sessions.sql


-- >>> BEGIN 20260215025000_db_performance_indexes.sql
-- DB performance quick wins:
-- - add indexes for frequent filters/lookups
-- - remove redundant unique index on transactions.client_tx_id

-- Fast path for open transactions per member (API + admin checks).
create index if not exists tx_member_open_created_idx
  on public.transactions (member_id, created_at desc)
  where settled_at is null;

-- Speed up inventory adjustment report filters by reason + time range.
create index if not exists im_reason_created_idx
  on public.inventory_movements (reason, created_at desc);

-- Speed up fridge refill report (positive adjustments in time range).
create index if not exists sa_created_positive_idx
  on public.stock_adjustments (created_at desc)
  where quantity > 0;

-- Case-insensitive login/device lookups use lower(...).
create index if not exists app_users_username_lower_idx
  on public.app_users (lower(username));

create index if not exists kiosk_devices_name_lower_idx
  on public.kiosk_devices (lower(name));

-- Keep only one uniqueness structure for client_tx_id.
drop index if exists public.ux_tx_client;

notify pgrst, 'reload schema';
-- <<< END 20260215025000_db_performance_indexes.sql


-- >>> BEGIN 20260216000000_add_admin_cancellations_report.sql
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
-- <<< END 20260216000000_add_admin_cancellations_report.sql


-- >>> BEGIN 20260216010000_add_admin_revenue_report.sql
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
-- <<< END 20260216010000_add_admin_revenue_report.sql


-- >>> BEGIN 20260217000000_add_transaction_type_and_exclude_cash_withdrawal_from_revenue.sql
alter table public.transactions
  add column if not exists transaction_type text;

update public.transactions t
set transaction_type = case
  when coalesce(t.amount, 0) > 0 then 'credit_adjustment'
  when t.product_id is null then 'sale_free_amount'
  else 'sale_product'
end
where t.transaction_type is null;

alter table public.transactions
  alter column transaction_type set default 'sale_product';

alter table public.transactions
  alter column transaction_type set not null;

alter table public.transactions
  drop constraint if exists transactions_transaction_type_chk;

alter table public.transactions
  add constraint transactions_transaction_type_chk
  check (transaction_type in ('sale_product', 'sale_free_amount', 'cash_withdrawal', 'credit_adjustment'));

alter table public.storno_log
  add column if not exists transaction_type text;

update public.storno_log s
set transaction_type = case
  when coalesce(s.amount, 0) > 0 then 'credit_adjustment'
  when s.product_id is null then 'sale_free_amount'
  else 'sale_product'
end
where s.transaction_type is null;

alter table public.storno_log
  alter column transaction_type set default 'sale_product';

alter table public.storno_log
  alter column transaction_type set not null;

alter table public.storno_log
  drop constraint if exists storno_log_transaction_type_chk;

alter table public.storno_log
  add constraint storno_log_transaction_type_chk
  check (transaction_type in ('sale_product', 'sale_free_amount', 'cash_withdrawal', 'credit_adjustment'));

drop function if exists public.book_transaction(uuid, uuid, integer, text, uuid);

create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid,
  p_transaction_type text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  amt integer;
  pid uuid;
  note text;
  txid uuid;
  is_guest boolean;
  v_inventoried boolean;
  v_member_name text;
  v_product_name text;
  v_price_snapshot integer;
  v_fr uuid;
  v_tx_type text;
begin
  select
    m.is_guest,
    nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), '')
  into is_guest, v_member_name
  from public.members m
  where m.id = member_id;

  if not found then
    raise exception 'MEMBER_NOT_FOUND';
  end if;

  if product_id is not null then
    select
      case when is_guest then p.guest_price else p.price end,
      p.inventoried,
      p.name
    into amt, v_inventoried, v_product_name
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    v_price_snapshot := amt;
    amt := -abs(amt);
    pid := product_id;
    note := null;
    v_tx_type := 'sale_product';
  else
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;

    v_tx_type := coalesce(nullif(trim(p_transaction_type), ''), 'sale_free_amount');
    if v_tx_type not in ('sale_free_amount', 'cash_withdrawal', 'credit_adjustment') then
      raise exception 'Ungueltiger transaction_type fuer freien Betrag';
    end if;

    note := coalesce(
      nullif(trim(p_note), ''),
      case
        when v_tx_type = 'cash_withdrawal' then 'Bar-Entnahme'
        when v_tx_type = 'credit_adjustment' then 'Guthabenbuchung'
        else 'frei'
      end
    );
    v_inventoried := false;
  end if;

  insert into public.transactions (
    member_id,
    product_id,
    amount,
    note,
    client_tx_id,
    member_name_snapshot,
    product_name_snapshot,
    product_price_snapshot,
    transaction_type
  )
  values (
    member_id,
    pid,
    amt,
    note,
    client_tx_id_param,
    coalesce(v_member_name, member_id::text),
    v_product_name,
    v_price_snapshot,
    v_tx_type
  )
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null and coalesce(v_inventoried, true) then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      transaction_id,
      note,
      meta
    ) values (
      pid,
      1,
      v_fr,
      null,
      'sale',
      txid,
      'Verkauf',
      jsonb_build_object('source', 'book_transaction')
    );
  end if;

  if txid is null and client_tx_id_param is not null then
    select t.id into txid
    from public.transactions t
    where t.client_tx_id = client_tx_id_param;
  end if;

  return txid;
end;
$function$;

grant execute on function public.book_transaction(uuid, uuid, integer, text, uuid, text) to anon, authenticated;

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
  v_member_active boolean;
  v_canceled_at timestamp with time zone;
  v_fr uuid;
begin
  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null and note is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen storniert werden';
  end if;

  select m.active into v_member_active
  from public.members m
  where m.id = v_tx.member_id;

  if coalesce(v_member_active, false) = false then
    raise exception 'Buchungen von inaktiven Mitgliedern duerfen nicht storniert werden';
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  v_canceled_at := now();

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is null then
    raise exception 'Storno fehlgeschlagen';
  end if;

  insert into public.storno_log (
    original_transaction_id,
    member_id,
    product_id,
    transaction_created_at,
    canceled_at,
    amount,
    note,
    transaction_type
  ) values (
    v_tx.id,
    v_tx.member_id,
    v_tx.product_id,
    v_tx.created_at,
    v_canceled_at,
    v_tx.amount,
    v_tx.note,
    coalesce(v_tx.transaction_type, case when v_tx.product_id is null then 'sale_free_amount' else 'sale_product' end)
  );

  if v_tx.product_id is not null then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      meta
    ) values (
      v_tx.product_id,
      1,
      null,
      v_fr,
      'sale_cancel',
      'Storno Rueckbuchung',
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    );
  end if;

  return v_cancel_id;
end;
$function$;

drop function if exists public.api_admin_get_revenue_report_period(text, timestamp with time zone, timestamp with time zone);
drop function if exists public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone);

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
  transaction_type text,
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
      coalesce(t.transaction_type, case when t.product_id is null then 'sale_free_amount' else 'sale_product' end) as transaction_type,
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
      and t.amount <> 0
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
      coalesce(s.transaction_type, case when s.product_id is null then 'sale_free_amount' else 'sale_product' end) as transaction_type,
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
      and s.amount <> 0
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
  transaction_type text,
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

create or replace function public.api_admin_book_free_amount(
  p_token text,
  p_member_id uuid,
  p_amount_cents integer,
  p_note text default null
)
returns uuid
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return public.book_transaction(
    p_member_id,
    null,
    p_amount_cents,
    p_note,
    null,
    'credit_adjustment'
  );
end;
$function$;

-- Safety net for partially applied environments:
-- Ensure all positive amounts are always treated as non-revenue credit adjustments.
update public.transactions t
set transaction_type = 'credit_adjustment'
where coalesce(t.amount, 0) > 0
  and t.transaction_type <> 'credit_adjustment';

update public.storno_log s
set transaction_type = 'credit_adjustment'
where coalesce(s.amount, 0) > 0
  and s.transaction_type <> 'credit_adjustment';
-- <<< END 20260217000000_add_transaction_type_and_exclude_cash_withdrawal_from_revenue.sql


-- >>> BEGIN 20260217010000_add_transaction_type_to_bookings_report.sql
create or replace function public.get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(local_day date, member_id uuid, member_name text, member_active boolean, total integer, items jsonb)
language sql
security definer
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  t.member_id as member_id,
  (
    coalesce(
      nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
      nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
      t.member_name_snapshot,
      '[Geloeschtes Mitglied]'
    )
    ||
    case when coalesce(m.is_guest, ma.is_guest, false) then ' (Gast)' else '' end
  ) as member_name,
  coalesce(m.active, false) as member_active,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'settled_at', t.settled_at,
      'product_id', t.product_id,
      'product_name', coalesce(p.name, pa.name, t.product_name_snapshot),
      'transaction_type', coalesce(
        t.transaction_type,
        case
          when coalesce(t.amount, 0) > 0 then 'credit_adjustment'
          when t.product_id is null then 'sale_free_amount'
          else 'sale_product'
        end
      )
    )
    order by t.created_at desc
  ) as items
from public.transactions t
left join public.members m on m.id = t.member_id
left join public.members_archive ma on ma.id = t.member_id
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
where t.created_at >= p_start
  and t.created_at < p_end
group by local_day, t.member_id, member_name, member_active
order by local_day desc, member_name;
$function$;

create or replace function public.admin_get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  local_day date,
  member_id uuid,
  member_name text,
  member_active boolean,
  total integer,
  items jsonb
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_all_bookings_grouped(p_start, p_end);
end;
$function$;
-- <<< END 20260217010000_add_transaction_type_to_bookings_report.sql


-- >>> BEGIN 20260222010000_terminal_perf_today_snapshot.sql
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
-- <<< END 20260222010000_terminal_perf_today_snapshot.sql

-- >>> BEGIN 20260223010000_book_transaction_member_guard.sql
-- No-op in bootstrap: content already included via later book_transaction replacements.
-- <<< END 20260223010000_book_transaction_member_guard.sql

-- >>> BEGIN 20260223011000_restore_transactions_member_fk.sql
update public.transactions t
set member_id = null
where t.member_id is not null
  and not exists (
    select 1
    from public.members m
    where m.id = t.member_id
  );

alter table public.transactions
  alter column member_id drop not null;

alter table public.transactions
  drop constraint if exists transactions_member_id_fkey;

alter table public.transactions
  add constraint transactions_member_id_fkey
  foreign key (member_id)
  references public.members (id)
  on delete set null;
-- <<< END 20260223011000_restore_transactions_member_fk.sql

-- >>> BEGIN 20260223020000_add_device_to_transactions_and_booking_trace.sql
alter table public.transactions
  add column if not exists device_id uuid null;

create index if not exists transactions_device_id_idx
  on public.transactions (device_id);

alter table public.transactions
  drop constraint if exists transactions_device_id_fkey;

alter table public.transactions
  add constraint transactions_device_id_fkey
  foreign key (device_id)
  references public.kiosk_devices (id)
  on delete set null;

create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid,
  p_transaction_type text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  amt integer;
  pid uuid;
  note text;
  txid uuid;
  is_guest boolean;
  v_inventoried boolean;
  v_member_name text;
  v_product_name text;
  v_price_snapshot integer;
  v_fr uuid;
  v_tx_type text;
  v_device_id uuid;
begin
  v_device_id := public.app_current_device_id();

  select
    m.is_guest,
    nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), '')
  into is_guest, v_member_name
  from public.members m
  where m.id = member_id;

  if not found then
    raise exception 'MEMBER_NOT_FOUND';
  end if;

  if product_id is not null then
    select
      case when is_guest then p.guest_price else p.price end,
      p.inventoried,
      p.name
    into amt, v_inventoried, v_product_name
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    v_price_snapshot := amt;
    amt := -abs(amt);
    pid := product_id;
    note := null;
    v_tx_type := 'sale_product';
  else
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;

    v_tx_type := coalesce(nullif(trim(p_transaction_type), ''), 'sale_free_amount');
    if v_tx_type not in ('sale_free_amount', 'cash_withdrawal', 'credit_adjustment') then
      raise exception 'Ungueltiger transaction_type fuer freien Betrag';
    end if;

    note := coalesce(
      nullif(trim(p_note), ''),
      case
        when v_tx_type = 'cash_withdrawal' then 'Bar-Entnahme'
        when v_tx_type = 'credit_adjustment' then 'Guthabenbuchung'
        else 'frei'
      end
    );
    v_inventoried := false;
  end if;

  insert into public.transactions (
    member_id,
    product_id,
    amount,
    note,
    client_tx_id,
    member_name_snapshot,
    product_name_snapshot,
    product_price_snapshot,
    transaction_type,
    device_id
  )
  values (
    member_id,
    pid,
    amt,
    note,
    client_tx_id_param,
    coalesce(v_member_name, member_id::text),
    v_product_name,
    v_price_snapshot,
    v_tx_type,
    v_device_id
  )
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null and coalesce(v_inventoried, true) then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      transaction_id,
      note,
      device_id,
      meta
    ) values (
      pid,
      1,
      v_fr,
      null,
      'sale',
      txid,
      'Verkauf',
      v_device_id,
      jsonb_build_object('source', 'book_transaction')
    );
  end if;

  if txid is null and client_tx_id_param is not null then
    select t.id into txid
    from public.transactions t
    where t.client_tx_id = client_tx_id_param;
  end if;

  return txid;
end;
$function$;

grant execute on function public.book_transaction(uuid, uuid, integer, text, uuid, text) to anon, authenticated;
-- <<< END 20260223020000_add_device_to_transactions_and_booking_trace.sql

-- >>> BEGIN 20260223030000_add_device_snapshot_to_bookings_report.sql
alter table public.transactions
  add column if not exists device_id_snapshot uuid null;

update public.transactions t
set device_id_snapshot = t.device_id
where t.device_id_snapshot is null
  and t.device_id is not null;

create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid,
  p_transaction_type text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  amt integer;
  pid uuid;
  note text;
  txid uuid;
  is_guest boolean;
  v_inventoried boolean;
  v_member_name text;
  v_product_name text;
  v_price_snapshot integer;
  v_fr uuid;
  v_tx_type text;
  v_device_id uuid;
begin
  v_device_id := public.app_current_device_id();

  select
    m.is_guest,
    nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), '')
  into is_guest, v_member_name
  from public.members m
  where m.id = member_id;

  if not found then
    raise exception 'MEMBER_NOT_FOUND';
  end if;

  if product_id is not null then
    select
      case when is_guest then p.guest_price else p.price end,
      p.inventoried,
      p.name
    into amt, v_inventoried, v_product_name
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    v_price_snapshot := amt;
    amt := -abs(amt);
    pid := product_id;
    note := null;
    v_tx_type := 'sale_product';
  else
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;

    v_tx_type := coalesce(nullif(trim(p_transaction_type), ''), 'sale_free_amount');
    if v_tx_type not in ('sale_free_amount', 'cash_withdrawal', 'credit_adjustment') then
      raise exception 'Ungueltiger transaction_type fuer freien Betrag';
    end if;

    note := coalesce(
      nullif(trim(p_note), ''),
      case
        when v_tx_type = 'cash_withdrawal' then 'Bar-Entnahme'
        when v_tx_type = 'credit_adjustment' then 'Guthabenbuchung'
        else 'frei'
      end
    );
    v_inventoried := false;
  end if;

  insert into public.transactions (
    member_id,
    product_id,
    amount,
    note,
    client_tx_id,
    member_name_snapshot,
    product_name_snapshot,
    product_price_snapshot,
    transaction_type,
    device_id,
    device_id_snapshot
  )
  values (
    member_id,
    pid,
    amt,
    note,
    client_tx_id_param,
    coalesce(v_member_name, member_id::text),
    v_product_name,
    v_price_snapshot,
    v_tx_type,
    v_device_id,
    v_device_id
  )
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null and coalesce(v_inventoried, true) then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      transaction_id,
      note,
      device_id,
      meta
    ) values (
      pid,
      1,
      v_fr,
      null,
      'sale',
      txid,
      'Verkauf',
      v_device_id,
      jsonb_build_object('source', 'book_transaction')
    );
  end if;

  if txid is null and client_tx_id_param is not null then
    select t.id into txid
    from public.transactions t
    where t.client_tx_id = client_tx_id_param;
  end if;

  return txid;
end;
$function$;

create or replace function public.get_all_bookings_grouped(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(local_day date, member_id uuid, member_name text, member_active boolean, total integer, items jsonb)
language sql
security definer
as $function$
select
  (t.created_at at time zone 'Europe/Berlin')::date as local_day,
  t.member_id as member_id,
  (
    coalesce(
      nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), ''),
      nullif(trim(coalesce(ma.firstname, '') || ' ' || coalesce(ma.lastname, '')), ''),
      t.member_name_snapshot,
      '[Geloeschtes Mitglied]'
    )
    ||
    case when coalesce(m.is_guest, ma.is_guest, false) then ' (Gast)' else '' end
  ) as member_name,
  coalesce(m.active, false) as member_active,
  sum(t.amount)::int as total,
  json_agg(
    json_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'created_at', t.created_at,
      'settled_at', t.settled_at,
      'product_id', t.product_id,
      'product_name', coalesce(p.name, pa.name, t.product_name_snapshot),
      'device_name', coalesce(kd.name, t.device_id_snapshot::text, t.device_id::text, '-'),
      'transaction_type', coalesce(
        t.transaction_type,
        case
          when coalesce(t.amount, 0) > 0 then 'credit_adjustment'
          when t.product_id is null then 'sale_free_amount'
          else 'sale_product'
        end
      )
    )
    order by t.created_at desc
  ) as items
from public.transactions t
left join public.members m on m.id = t.member_id
left join public.members_archive ma on ma.id = t.member_id
left join public.products p on p.id = t.product_id
left join public.products_archive pa on pa.id = t.product_id
left join public.kiosk_devices kd on kd.id = t.device_id
where t.created_at >= p_start
  and t.created_at < p_end
group by local_day, t.member_id, member_name, member_active
order by local_day desc, member_name;
$function$;
-- <<< END 20260223030000_add_device_snapshot_to_bookings_report.sql

-- >>> BEGIN 20260223040000_cancel_transaction_device_trace.sql
drop function if exists public.cancel_transaction(uuid, uuid, uuid, text);
drop function if exists public.cancel_transaction(uuid, uuid, uuid, text, uuid);

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text,
  p_device_id uuid default null::uuid
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
  v_member_active boolean;
  v_canceled_at timestamp with time zone;
  v_fr uuid;
  v_device_id uuid;
begin
  v_device_id := coalesce(p_device_id, public.app_current_device_id());

  if public.app_current_role() = 'device' and v_device_id is null then
    raise exception 'DEVICE_ID_REQUIRED';
  end if;

  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null and note is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen storniert werden';
  end if;

  select m.active into v_member_active
  from public.members m
  where m.id = v_tx.member_id;

  if coalesce(v_member_active, false) = false then
    raise exception 'Buchungen von inaktiven Mitgliedern duerfen nicht storniert werden';
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  v_canceled_at := now();

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is null then
    raise exception 'Storno fehlgeschlagen';
  end if;

  insert into public.storno_log (
    original_transaction_id,
    member_id,
    product_id,
    transaction_created_at,
    canceled_at,
    amount,
    note,
    transaction_type
  ) values (
    v_tx.id,
    v_tx.member_id,
    v_tx.product_id,
    v_tx.created_at,
    v_canceled_at,
    v_tx.amount,
    v_tx.note,
    coalesce(v_tx.transaction_type, case when v_tx.product_id is null then 'sale_free_amount' else 'sale_product' end)
  );

  if v_tx.product_id is not null then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      device_id,
      meta
    ) values (
      v_tx.product_id,
      1,
      null,
      v_fr,
      'sale_cancel',
      'Storno Rueckbuchung',
      v_device_id,
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    );
  end if;

  return v_cancel_id;
end;
$function$;

grant execute on function public.cancel_transaction(uuid, uuid, uuid, text, uuid) to anon, authenticated;
-- <<< END 20260223040000_cancel_transaction_device_trace.sql

-- >>> BEGIN 20260223050000_cancellation_device_snapshots_and_report.sql
alter table public.storno_log
  add column if not exists device_id uuid null,
  add column if not exists device_id_snapshot uuid null;

create index if not exists storno_log_device_id_idx
  on public.storno_log (device_id);

alter table public.storno_log
  drop constraint if exists storno_log_device_id_fkey;

alter table public.storno_log
  add constraint storno_log_device_id_fkey
  foreign key (device_id)
  references public.kiosk_devices (id)
  on delete set null;

alter table public.inventory_movements
  add column if not exists device_id_snapshot uuid null;

with matched as (
  select
    s.id as storno_id,
    im.device_id
  from public.storno_log s
  left join lateral (
    select i.device_id
    from public.inventory_movements i
    where i.reason = 'sale_cancel'
      and (i.meta ->> 'canceled_tx_id') ~* '^[0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12}$'
      and (i.meta ->> 'canceled_tx_id')::uuid = s.original_transaction_id
    order by i.created_at desc
    limit 1
  ) im on true
  where s.device_id is null
    and s.original_transaction_id is not null
)
update public.storno_log s
set
  device_id = coalesce(s.device_id, m.device_id),
  device_id_snapshot = coalesce(s.device_id_snapshot, s.device_id, m.device_id)
from matched m
where s.id = m.storno_id;

update public.storno_log s
set device_id_snapshot = coalesce(s.device_id_snapshot, s.device_id)
where s.device_id is not null;

update public.inventory_movements im
set device_id_snapshot = im.device_id
where im.device_id_snapshot is null
  and im.device_id is not null;

drop function if exists public.cancel_transaction(uuid, uuid, uuid, text);
drop function if exists public.cancel_transaction(uuid, uuid, uuid, text, uuid);

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text,
  p_device_id uuid default null::uuid
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
  v_member_active boolean;
  v_canceled_at timestamp with time zone;
  v_fr uuid;
  v_device_id uuid;
begin
  v_device_id := coalesce(p_device_id, public.app_current_device_id());

  if public.app_current_role() = 'device' and v_device_id is null then
    raise exception 'DEVICE_ID_REQUIRED';
  end if;

  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null and note is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen storniert werden';
  end if;

  select m.active into v_member_active
  from public.members m
  where m.id = v_tx.member_id;

  if coalesce(v_member_active, false) = false then
    raise exception 'Buchungen von inaktiven Mitgliedern duerfen nicht storniert werden';
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  v_canceled_at := now();

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is null then
    raise exception 'Storno fehlgeschlagen';
  end if;

  insert into public.storno_log (
    original_transaction_id,
    member_id,
    product_id,
    transaction_created_at,
    canceled_at,
    amount,
    note,
    transaction_type,
    device_id,
    device_id_snapshot
  ) values (
    v_tx.id,
    v_tx.member_id,
    v_tx.product_id,
    v_tx.created_at,
    v_canceled_at,
    v_tx.amount,
    v_tx.note,
    coalesce(v_tx.transaction_type, case when v_tx.product_id is null then 'sale_free_amount' else 'sale_product' end),
    v_device_id,
    v_device_id
  );

  if v_tx.product_id is not null then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      note,
      device_id,
      device_id_snapshot,
      meta
    ) values (
      v_tx.product_id,
      1,
      null,
      v_fr,
      'sale_cancel',
      'Storno Rueckbuchung',
      v_device_id,
      v_device_id,
      jsonb_build_object('source', 'cancel_transaction', 'canceled_tx_id', v_tx.id)
    );
  end if;

  return v_cancel_id;
end;
$function$;

grant execute on function public.cancel_transaction(uuid, uuid, uuid, text, uuid) to anon, authenticated;

drop function if exists public.admin_get_cancellations_report_period(timestamp with time zone, timestamp with time zone);
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
  device_name text,
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
    coalesce(kd.name, sl.device_id_snapshot::text, sl.device_id::text, '-') as device_name,
    sl.amount,
    sl.note
  from public.storno_log sl
  left join public.members m on m.id = sl.member_id
  left join public.products p on p.id = sl.product_id
  left join public.kiosk_devices kd on kd.id = sl.device_id
  where sl.canceled_at >= p_start
    and sl.canceled_at < p_end
  order by sl.canceled_at desc;
end;
$function$;

drop function if exists public.api_admin_get_cancellations_report_period(text, timestamp with time zone, timestamp with time zone);
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
  device_name text,
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
-- <<< END 20260223050000_cancellation_device_snapshots_and_report.sql

-- >>> BEGIN 20260223060000_sale_movement_device_snapshot.sql
update public.inventory_movements im
set device_id_snapshot = im.device_id
where im.reason = 'sale'
  and im.device_id is not null
  and im.device_id_snapshot is null;

create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid,
  p_transaction_type text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  amt integer;
  pid uuid;
  note text;
  txid uuid;
  is_guest boolean;
  v_inventoried boolean;
  v_member_name text;
  v_product_name text;
  v_price_snapshot integer;
  v_fr uuid;
  v_tx_type text;
  v_device_id uuid;
begin
  v_device_id := public.app_current_device_id();

  select
    m.is_guest,
    nullif(trim(coalesce(m.firstname, '') || ' ' || coalesce(m.lastname, '')), '')
  into is_guest, v_member_name
  from public.members m
  where m.id = member_id;

  if not found then
    raise exception 'MEMBER_NOT_FOUND';
  end if;

  if product_id is not null then
    select
      case when is_guest then p.guest_price else p.price end,
      p.inventoried,
      p.name
    into amt, v_inventoried, v_product_name
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    v_price_snapshot := amt;
    amt := -abs(amt);
    pid := product_id;
    note := null;
    v_tx_type := 'sale_product';
  else
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;

    v_tx_type := coalesce(nullif(trim(p_transaction_type), ''), 'sale_free_amount');
    if v_tx_type not in ('sale_free_amount', 'cash_withdrawal', 'credit_adjustment') then
      raise exception 'Ungueltiger transaction_type fuer freien Betrag';
    end if;

    note := coalesce(
      nullif(trim(p_note), ''),
      case
        when v_tx_type = 'cash_withdrawal' then 'Bar-Entnahme'
        when v_tx_type = 'credit_adjustment' then 'Guthabenbuchung'
        else 'frei'
      end
    );
    v_inventoried := false;
  end if;

  insert into public.transactions (
    member_id,
    product_id,
    amount,
    note,
    client_tx_id,
    member_name_snapshot,
    product_name_snapshot,
    product_price_snapshot,
    transaction_type,
    device_id,
    device_id_snapshot
  )
  values (
    member_id,
    pid,
    amt,
    note,
    client_tx_id_param,
    coalesce(v_member_name, member_id::text),
    v_product_name,
    v_price_snapshot,
    v_tx_type,
    v_device_id,
    v_device_id
  )
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null and coalesce(v_inventoried, true) then
    v_fr := public.get_stock_location_id('fridge');
    insert into public.inventory_movements (
      product_id,
      quantity,
      from_location_id,
      to_location_id,
      reason,
      transaction_id,
      note,
      device_id,
      device_id_snapshot,
      meta
    ) values (
      pid,
      1,
      v_fr,
      null,
      'sale',
      txid,
      'Verkauf',
      v_device_id,
      v_device_id,
      jsonb_build_object('source', 'book_transaction')
    );
  end if;

  if txid is null and client_tx_id_param is not null then
    select t.id into txid
    from public.transactions t
    where t.client_tx_id = client_tx_id_param;
  end if;

  return txid;
end;
$function$;
-- <<< END 20260223060000_sale_movement_device_snapshot.sql

-- Ensure backend RPC access with SUPABASE_SERVICE_ROLE_KEY.
-- Some migrations revoke execute from public/anon/authenticated; explicit service_role grants are required.
do $$
declare
  fn record;
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
  end if;
end
$$;

-- Ensure backend table/view access with SUPABASE_SERVICE_ROLE_KEY for direct selects in API routes.
do $$
declare
  rel record;
  seq record;
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
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

-- >>> BEGIN 20260225010000_revenue_report_pagination.sql
-- Add pagination parameters for revenue report RPC to avoid 1000-row truncation.
drop function if exists public.api_admin_get_revenue_report_period(text, timestamp with time zone, timestamp with time zone);
drop function if exists public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone);

create or replace function public.admin_get_revenue_report_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_limit integer default null,
  p_offset integer default 0
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
  transaction_type text,
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
      coalesce(t.transaction_type, case when t.product_id is null then 'sale_free_amount' else 'sale_product' end) as transaction_type,
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
      and t.amount <> 0
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
      coalesce(s.transaction_type, case when s.product_id is null then 'sale_free_amount' else 'sale_product' end) as transaction_type,
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
      and s.amount <> 0
  )
  select * from (
    select * from tx
    union all
    select * from sl
  ) u
  order by u.event_at desc, u.event_type asc
  limit coalesce(p_limit, 2147483647)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$function$;

revoke all on function public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone, integer, integer) from public;
grant execute on function public.admin_get_revenue_report_period(timestamp with time zone, timestamp with time zone, integer, integer) to authenticated;

create or replace function public.api_admin_get_revenue_report_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone,
  p_limit integer default null,
  p_offset integer default 0
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
  transaction_type text,
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
  select * from public.admin_get_revenue_report_period(p_start, p_end, p_limit, p_offset);
end;
$function$;

revoke all on function public.api_admin_get_revenue_report_period(text, timestamp with time zone, timestamp with time zone, integer, integer) from public;
-- <<< END 20260225010000_revenue_report_pagination.sql

-- >>> BEGIN 20260225020000_admin_branding_settings.sql
-- Admin-editable branding (title + logo URL) for Terminal/Admin header.
create table if not exists public.app_branding_settings (
  singleton boolean primary key default true check (singleton),
  app_title text not null default 'ClubCashBuddy',
  logo_url text null,
  updated_at timestamp with time zone not null default now(),
  updated_by uuid null references public.app_users(id) on delete set null
);

insert into public.app_branding_settings (singleton, app_title, logo_url)
values (true, 'ClubCashBuddy', null)
on conflict (singleton) do nothing;

create or replace function public.public_get_branding_settings()
returns table(
  app_title text,
  logo_url text
)
language sql
security definer
as $function$
  select
    s.app_title,
    s.logo_url
  from public.app_branding_settings s
  where s.singleton = true;
$function$;

revoke all on function public.public_get_branding_settings() from public;
grant execute on function public.public_get_branding_settings() to anon, authenticated;

create or replace function public.admin_get_branding_settings()
returns table(
  app_title text,
  logo_url text,
  updated_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select
    s.app_title,
    s.logo_url,
    s.updated_at
  from public.app_branding_settings s
  where s.singleton = true;
end;
$function$;

revoke all on function public.admin_get_branding_settings() from public;
grant execute on function public.admin_get_branding_settings() to authenticated;

create or replace function public.admin_upsert_branding_settings(
  p_app_title text default null::text,
  p_logo_url text default null::text
)
returns table(
  app_title text,
  logo_url text,
  updated_at timestamp with time zone
)
language plpgsql
security definer
as $function$
declare
  v_current_title text;
  v_current_logo text;
  v_title text;
  v_logo text;
begin
  perform public.assert_admin();

  select s.app_title, s.logo_url
  into v_current_title, v_current_logo
  from public.app_branding_settings s
  where s.singleton = true;

  v_title := coalesce(nullif(trim(coalesce(p_app_title, '')), ''), v_current_title, 'ClubCashBuddy');
  v_logo := case
    when p_logo_url is null then v_current_logo
    else nullif(trim(p_logo_url), '')
  end;

  insert into public.app_branding_settings (singleton, app_title, logo_url, updated_at, updated_by)
  values (true, v_title, v_logo, now(), public.app_current_user_id())
  on conflict (singleton) do update
    set app_title = excluded.app_title,
        logo_url = excluded.logo_url,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by;

  return query
  select
    s.app_title,
    s.logo_url,
    s.updated_at
  from public.app_branding_settings s
  where s.singleton = true;
end;
$function$;

revoke all on function public.admin_upsert_branding_settings(text, text) from public;
grant execute on function public.admin_upsert_branding_settings(text, text) to authenticated;

create or replace function public.api_admin_get_branding_settings(
  p_token text
)
returns table(
  app_title text,
  logo_url text,
  updated_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_branding_settings();
end;
$function$;

revoke all on function public.api_admin_get_branding_settings(text) from public;

create or replace function public.api_admin_upsert_branding_settings(
  p_token text,
  p_app_title text default null::text,
  p_logo_url text default null::text
)
returns table(
  app_title text,
  logo_url text,
  updated_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_upsert_branding_settings(p_app_title, p_logo_url);
end;
$function$;

revoke all on function public.api_admin_upsert_branding_settings(text, text, text) from public;
-- <<< END 20260225020000_admin_branding_settings.sql

-- >>> BEGIN 20260225030000_admin_user_management.sql
-- Admin user management RPCs (list/create/update) with safety guards.

create or replace function public.admin_list_app_users()
returns table(
  id uuid,
  username text,
  role text,
  is_admin boolean,
  active boolean,
  created_at timestamp with time zone,
  last_login_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    u.id,
    u.username,
    u.role,
    (u.role = 'admin') as is_admin,
    u.active,
    u.created_at,
    u.last_login_at
  from public.app_users u
  where u.role in ('admin', 'operator')
  order by lower(u.username), u.created_at desc;
end;
$function$;

revoke all on function public.admin_list_app_users() from public;
grant execute on function public.admin_list_app_users() to authenticated;

create or replace function public.admin_create_app_user(
  p_username text,
  p_password text,
  p_is_admin boolean default true,
  p_active boolean default true
)
returns table(
  id uuid,
  username text,
  role text,
  is_admin boolean,
  active boolean,
  created_at timestamp with time zone,
  last_login_at timestamp with time zone
)
language plpgsql
security definer
as $function$
declare
  v_user_id uuid;
  v_username text;
  v_password text;
  v_is_admin boolean;
  v_active boolean;
begin
  perform public.assert_admin();

  v_username := trim(coalesce(p_username, ''));
  v_password := coalesce(p_password, '');
  v_is_admin := coalesce(p_is_admin, true);
  v_active := coalesce(p_active, true);

  if v_username = '' then
    raise exception 'USERNAME_REQUIRED';
  end if;
  if length(v_password) < 4 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

  insert into public.app_users (username, password_hash, role, active)
  values (
    v_username,
    crypt(v_password, gen_salt('bf')),
    case when v_is_admin then 'admin' else 'operator' end,
    v_active
  )
  returning app_users.id into v_user_id;

  return query
  select
    u.id,
    u.username,
    u.role,
    (u.role = 'admin') as is_admin,
    u.active,
    u.created_at,
    u.last_login_at
  from public.app_users u
  where u.id = v_user_id;
end;
$function$;

revoke all on function public.admin_create_app_user(text, text, boolean, boolean) from public;
grant execute on function public.admin_create_app_user(text, text, boolean, boolean) to authenticated;

create or replace function public.admin_update_app_user(
  p_user_id uuid,
  p_username text default null::text,
  p_password text default null::text,
  p_is_admin boolean default null::boolean,
  p_active boolean default null::boolean
)
returns table(
  id uuid,
  username text,
  role text,
  is_admin boolean,
  active boolean,
  created_at timestamp with time zone,
  last_login_at timestamp with time zone
)
language plpgsql
security definer
as $function$
declare
  v_user public.app_users%rowtype;
  v_is_admin_current boolean;
  v_is_admin_next boolean;
  v_active_next boolean;
  v_username_next text;
  v_current_user_id uuid;
  v_other_active_admins integer;
begin
  perform public.assert_admin();

  select u.*
  into v_user
  from public.app_users u
  where u.id = p_user_id
  limit 1;

  if v_user.id is null then
    raise exception 'USER_NOT_FOUND';
  end if;

  if v_user.role not in ('admin', 'operator') then
    raise exception 'USER_ROLE_NOT_MANAGEABLE';
  end if;

  v_is_admin_current := (v_user.role = 'admin');
  v_is_admin_next := coalesce(p_is_admin, v_is_admin_current);
  v_active_next := coalesce(p_active, v_user.active);
  v_username_next := coalesce(nullif(trim(coalesce(p_username, '')), ''), v_user.username);
  v_current_user_id := public.app_current_user_id();

  if p_password is not null and length(trim(p_password)) > 0 and length(trim(p_password)) < 4 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

  if v_user.id = v_current_user_id and (v_is_admin_next = false or v_active_next = false) then
    raise exception 'SELF_ADMIN_LOCKOUT_FORBIDDEN';
  end if;

  if v_is_admin_current and (v_is_admin_next = false or v_active_next = false) then
    select count(*)::int
    into v_other_active_admins
    from public.app_users u
    where u.id <> v_user.id
      and u.role = 'admin'
      and u.active = true;

    if coalesce(v_other_active_admins, 0) = 0 then
      raise exception 'LAST_ACTIVE_ADMIN_REQUIRED';
    end if;
  end if;

  update public.app_users u
  set
    username = v_username_next,
    role = case when v_is_admin_next then 'admin' else 'operator' end,
    active = v_active_next,
    password_hash = case
      when p_password is null or length(trim(p_password)) = 0 then u.password_hash
      else crypt(trim(p_password), gen_salt('bf'))
    end
  where u.id = v_user.id;

  return query
  select
    u.id,
    u.username,
    u.role,
    (u.role = 'admin') as is_admin,
    u.active,
    u.created_at,
    u.last_login_at
  from public.app_users u
  where u.id = v_user.id;
end;
$function$;

revoke all on function public.admin_update_app_user(uuid, text, text, boolean, boolean) from public;
grant execute on function public.admin_update_app_user(uuid, text, text, boolean, boolean) to authenticated;

create or replace function public.api_admin_list_app_users(
  p_token text
)
returns table(
  id uuid,
  username text,
  role text,
  is_admin boolean,
  active boolean,
  created_at timestamp with time zone,
  last_login_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_app_users();
end;
$function$;

revoke all on function public.api_admin_list_app_users(text) from public;

create or replace function public.api_admin_create_app_user(
  p_token text,
  p_username text,
  p_password text,
  p_is_admin boolean default true,
  p_active boolean default true
)
returns table(
  id uuid,
  username text,
  role text,
  is_admin boolean,
  active boolean,
  created_at timestamp with time zone,
  last_login_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_create_app_user(p_username, p_password, p_is_admin, p_active);
end;
$function$;

revoke all on function public.api_admin_create_app_user(text, text, text, boolean, boolean) from public;

create or replace function public.api_admin_update_app_user(
  p_token text,
  p_user_id uuid,
  p_username text default null::text,
  p_password text default null::text,
  p_is_admin boolean default null::boolean,
  p_active boolean default null::boolean
)
returns table(
  id uuid,
  username text,
  role text,
  is_admin boolean,
  active boolean,
  created_at timestamp with time zone,
  last_login_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_update_app_user(p_user_id, p_username, p_password, p_is_admin, p_active);
end;
$function$;

revoke all on function public.api_admin_update_app_user(text, uuid, text, text, boolean, boolean) from public;
-- <<< END 20260225030000_admin_user_management.sql

-- >>> BEGIN 20260225040000_device_session_sliding_and_inactivity.sql
-- No-op in bootstrap: app_apply_session/app_login_device_key already present in current bootstrap state.
-- <<< END 20260225040000_device_session_sliding_and_inactivity.sql

-- >>> BEGIN 20260225050000_device_pairing_codes.sql
-- One-time device pairing codes for secure terminal onboarding.

create table if not exists public.device_pairing_codes (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.kiosk_devices(id) on delete cascade,
  code_hash text not null,
  created_by uuid null references public.app_users(id) on delete set null,
  created_at timestamp with time zone not null default now(),
  expires_at timestamp with time zone not null,
  used_at timestamp with time zone null
);

create index if not exists device_pairing_codes_device_idx
  on public.device_pairing_codes(device_id, created_at desc);

create index if not exists device_pairing_codes_hash_idx
  on public.device_pairing_codes(code_hash);

create index if not exists device_pairing_codes_open_idx
  on public.device_pairing_codes(expires_at, used_at)
  where used_at is null;

create or replace function public.admin_list_kiosk_devices()
returns table(
  id uuid,
  name text,
  active boolean,
  last_seen_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select
    d.id,
    d.name,
    d.active,
    d.last_seen_at
  from public.kiosk_devices d
  order by lower(d.name), d.created_at;
end;
$function$;

revoke all on function public.admin_list_kiosk_devices() from public;
grant execute on function public.admin_list_kiosk_devices() to authenticated;

create or replace function public.admin_create_device_pairing_code(
  p_device_id uuid,
  p_ttl_minutes integer default 5
)
returns table(
  pairing_code text,
  expires_at timestamp with time zone,
  device_id uuid,
  device_name text
)
language plpgsql
security definer
as $function$
declare
  v_code text;
  v_hash text;
  v_ttl integer;
  v_device public.kiosk_devices%rowtype;
  v_try integer;
begin
  perform public.assert_admin();

  if p_device_id is null then
    raise exception 'DEVICE_ID_REQUIRED';
  end if;

  select *
  into v_device
  from public.kiosk_devices d
  where d.id = p_device_id
  limit 1;

  if v_device.id is null then
    raise exception 'DEVICE_NOT_FOUND';
  end if;

  if coalesce(v_device.active, false) = false then
    raise exception 'DEVICE_INACTIVE';
  end if;

  v_ttl := greatest(coalesce(p_ttl_minutes, 5), 1);

  for v_try in 1..10 loop
    v_code := lpad((floor(random() * 1000000))::integer::text, 6, '0');
    v_hash := encode(digest(v_code, 'sha256'), 'hex');
    exit when not exists (
      select 1
      from public.device_pairing_codes c
      where c.code_hash = v_hash
        and c.used_at is null
        and c.expires_at > now()
    );
  end loop;

  if v_code is null then
    raise exception 'PAIRING_CODE_GENERATION_FAILED';
  end if;

  insert into public.device_pairing_codes (
    device_id,
    code_hash,
    created_by,
    expires_at
  ) values (
    v_device.id,
    v_hash,
    public.app_current_user_id(),
    now() + make_interval(mins => v_ttl)
  );

  pairing_code := v_code;
  expires_at := now() + make_interval(mins => v_ttl);
  device_id := v_device.id;
  device_name := v_device.name;
  return next;
end;
$function$;

revoke all on function public.admin_create_device_pairing_code(uuid, integer) from public;
grant execute on function public.admin_create_device_pairing_code(uuid, integer) to authenticated;

create or replace function public.app_login_device_pair_code(
  p_pair_code text,
  p_ttl_days integer default 180
)
returns table(
  token text,
  device_id uuid,
  device_name text
)
language plpgsql
security definer
as $function$
declare
  v_hash text;
  v_device_id uuid;
  v_device_name text;
  v_token text;
begin
  if nullif(trim(coalesce(p_pair_code, '')), '') is null then
    raise exception 'PAIR_CODE_REQUIRED';
  end if;

  v_hash := encode(digest(trim(p_pair_code), 'sha256'), 'hex');

  with candidate as (
    select
      c.id,
      c.device_id,
      d.name as device_name
    from public.device_pairing_codes c
    join public.kiosk_devices d on d.id = c.device_id
    where c.code_hash = v_hash
      and c.used_at is null
      and c.expires_at > now()
      and d.active = true
    order by c.created_at desc
    limit 1
    for update of c skip locked
  ),
  marked as (
    update public.device_pairing_codes c
    set used_at = now()
    from candidate x
    where c.id = x.id
      and c.used_at is null
    returning x.device_id, x.device_name
  )
  select m.device_id, m.device_name
  into v_device_id, v_device_name
  from marked m
  limit 1;

  if v_device_id is null then
    raise exception 'PAIR_CODE_INVALID_OR_EXPIRED';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');

  insert into public.app_sessions (
    token_hash,
    actor_type,
    actor_id,
    role,
    expires_at
  ) values (
    encode(digest(v_token, 'sha256'), 'hex'),
    'device',
    v_device_id,
    'device',
    now() + make_interval(days => greatest(coalesce(p_ttl_days, 180), 1))
  );

  update public.kiosk_devices
  set last_seen_at = now()
  where id = v_device_id;

  token := v_token;
  device_id := v_device_id;
  device_name := v_device_name;
  return next;
end;
$function$;

revoke all on function public.app_login_device_pair_code(text, integer) from public;

create or replace function public.api_admin_list_kiosk_devices(
  p_token text
)
returns table(
  id uuid,
  name text,
  active boolean,
  last_seen_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_kiosk_devices();
end;
$function$;

revoke all on function public.api_admin_list_kiosk_devices(text) from public;

create or replace function public.api_admin_create_device_pairing_code(
  p_token text,
  p_device_id uuid,
  p_ttl_minutes integer default 5
)
returns table(
  pairing_code text,
  expires_at timestamp with time zone,
  device_id uuid,
  device_name text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_create_device_pairing_code(p_device_id, p_ttl_minutes);
end;
$function$;

revoke all on function public.api_admin_create_device_pairing_code(text, uuid, integer) from public;
-- <<< END 20260225050000_device_pairing_codes.sql

-- >>> BEGIN 20260225060000_lockdown_branding_and_pairing_tables.sql
-- Lock down new internal tables: direct access forbidden, function-only access.

alter table public.app_branding_settings enable row level security;
alter table public.device_pairing_codes enable row level security;

revoke all on table public.app_branding_settings from public;
revoke all on table public.device_pairing_codes from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.app_branding_settings from anon';
    execute 'revoke all on table public.device_pairing_codes from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.app_branding_settings from authenticated';
    execute 'revoke all on table public.device_pairing_codes from authenticated';
  end if;
end
$$;
-- <<< END 20260225060000_lockdown_branding_and_pairing_tables.sql

-- >>> BEGIN 20260225070000_fix_session_function_grants.sql
-- Fix execute grants for session/login functions used by backend service role.

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.app_apply_session(text) to service_role';
    execute 'grant execute on function public.app_login_user(text, text, integer) to service_role';
    execute 'grant execute on function public.app_login_device_key(text, integer) to service_role';
    execute 'grant execute on function public.app_login_device_pair_code(text, integer) to service_role';
    execute 'grant execute on function public.app_logout(text) to service_role';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.app_apply_session(text) to authenticated';
  end if;
end
$$;
-- <<< END 20260225070000_fix_session_function_grants.sql

-- >>> BEGIN 20260225080000_remove_admins_dependency.sql
-- Remove runtime dependency on legacy public.admins table.
-- Admin authorization is based on app_users.role = 'admin' only.

create or replace function public.assert_admin()
returns void
language plpgsql
security definer
as $function$
declare
  v_user_id uuid;
begin
  v_user_id := public.app_current_user_id();

  if public.app_current_role() is null or v_user_id is null then
    raise exception 'Unauthorized';
  end if;

  if public.app_current_role() <> 'admin' then
    raise exception 'Forbidden';
  end if;

  if not exists (
    select 1
    from public.app_users u
    where u.id = v_user_id
      and u.role = 'admin'
      and u.active = true
  ) then
    raise exception 'Forbidden';
  end if;
end;
$function$;

revoke all on function public.assert_admin() from public;
grant execute on function public.assert_admin() to authenticated;

-- >>> BEGIN 20260225090000_drop_legacy_admins_table.sql
-- Hard cleanup: remove legacy admins table and dependencies.

do $$
declare
  r record;
begin
  for r in
    select
      quote_ident(p.polname) as policy_name,
      quote_ident(n.nspname) || '.' || quote_ident(c.relname) as table_name
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where coalesce(pg_get_expr(p.polqual, p.polrelid), '') ilike '%admins%'
       or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') ilike '%admins%'
  loop
    execute format('drop policy if exists %s on %s', r.policy_name, r.table_name);
  end loop;

  if to_regclass('public.admins') is not null then
    drop table public.admins;
  end if;
end
$$;
-- <<< END 20260225090000_drop_legacy_admins_table.sql

-- >>> BEGIN 20260225100000_admin_create_kiosk_device.sql
-- Allow admins to create kiosk devices directly from admin UI.

create or replace function public.admin_create_kiosk_device(
  p_name text,
  p_device_key text,
  p_active boolean default true
)
returns table(
  id uuid,
  name text,
  active boolean,
  last_seen_at timestamp with time zone,
  created_at timestamp with time zone
)
language plpgsql
security definer
as $function$
declare
  v_name text;
  v_key text;
begin
  perform public.assert_admin();

  v_name := nullif(trim(coalesce(p_name, '')), '');
  v_key := nullif(trim(coalesce(p_device_key, '')), '');

  if v_name is null then
    raise exception 'DEVICE_NAME_REQUIRED';
  end if;

  if v_key is null then
    raise exception 'DEVICE_KEY_REQUIRED';
  end if;

  if length(v_key) < 4 then
    raise exception 'DEVICE_KEY_TOO_SHORT';
  end if;

  insert into public.kiosk_devices (
    name,
    secret_hash,
    active
  ) values (
    v_name,
    crypt(v_key, gen_salt('bf')),
    coalesce(p_active, true)
  )
  returning
    kiosk_devices.id,
    kiosk_devices.name,
    kiosk_devices.active,
    kiosk_devices.last_seen_at,
    kiosk_devices.created_at
  into id, name, active, last_seen_at, created_at;

  return next;
end;
$function$;

revoke all on function public.admin_create_kiosk_device(text, text, boolean) from public;
grant execute on function public.admin_create_kiosk_device(text, text, boolean) to authenticated;

create or replace function public.api_admin_create_kiosk_device(
  p_token text,
  p_name text,
  p_device_key text,
  p_active boolean default true
)
returns table(
  id uuid,
  name text,
  active boolean,
  last_seen_at timestamp with time zone,
  created_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_create_kiosk_device(p_name, p_device_key, p_active);
end;
$function$;

revoke all on function public.api_admin_create_kiosk_device(text, text, text, boolean) from public;
-- <<< END 20260225100000_admin_create_kiosk_device.sql

-- >>> BEGIN 20260225110000_settlements_report.sql
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
-- <<< END 20260225110000_settlements_report.sql

-- >>> BEGIN 20260225130000_store_product_images_in_db.sql
-- Store product images directly in DB (data URL) to avoid storage dependency.

alter table public.products
  add column if not exists product_image_data_url text null;

notify pgrst, 'reload schema';
-- <<< END 20260225130000_store_product_images_in_db.sql

commit;




