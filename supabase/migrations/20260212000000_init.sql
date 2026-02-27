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
drop trigger if exists tg_update_balance on public.transactions;
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
