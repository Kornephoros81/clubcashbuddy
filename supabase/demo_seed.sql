-- Demo seed for ClubCashBuddy
-- Creates:
-- - demoadmin user (password: 1234)
-- - one active demo device (key: 1234)
-- - 50 members
-- - 20 products in 2 categories (Getraenke + Essen)
-- - 1000 bookings over the last 30 days
-- - additional data for settlements, cancellations, pins, sessions, stock flows

begin;

create extension if not exists pgcrypto;

-- Ensure stock locations exist (usually created by migrations already).
insert into public.stock_locations (code, name)
values
  ('warehouse', 'Lager'),
  ('fridge', 'Kuehlschrank')
on conflict (code) do nothing;

do $$
declare
  v_admin_id uuid;
  v_operator_id uuid;
  v_device_id uuid;
  v_pin_member_id uuid;
begin
  -- 1) Users + admin role
  insert into public.app_users (username, password_hash, role, active)
  values ('demoadmin', crypt('1234', gen_salt('bf')), 'admin', true)
  on conflict (username) do update
    set password_hash = excluded.password_hash,
        role = 'admin',
        active = true
  returning id into v_admin_id;

  insert into public.app_users (username, password_hash, role, active)
  values ('demooperator', crypt('1234', gen_salt('bf')), 'operator', true)
  on conflict (username) do update
    set password_hash = excluded.password_hash,
        role = 'operator',
        active = true
  returning id into v_operator_id;

  -- Branding demo values for header/settings screens.
  insert into public.app_branding_settings (singleton, app_title, logo_url, updated_at, updated_by)
  values (
    true,
    'ClubCashBuddy Demo',
    'https://picsum.photos/seed/vereinskasse/256/256',
    now(),
    v_admin_id
  )
  on conflict (singleton) do update
    set app_title = excluded.app_title,
        logo_url = excluded.logo_url,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by;

  -- 2) Devices
  insert into public.kiosk_devices (name, secret_hash, active)
  values ('Demo Terminal', crypt('1234', gen_salt('bf')), true)
  on conflict (name) do update
    set secret_hash = excluded.secret_hash,
        active = true,
        last_seen_at = now()
  returning id into v_device_id;

  insert into public.kiosk_devices (name, secret_hash, active)
  values ('Demo Terminal Alt', crypt('1234', gen_salt('bf')), false)
  on conflict (name) do update
    set secret_hash = excluded.secret_hash,
        active = false;

  -- 3) Members (50) with realistic names
  create temporary table tmp_demo_members_source (
    id uuid primary key,
    is_guest boolean not null,
    member_name text null
  ) on commit drop;

  with
    first_names(firstname, rn) as (
      select *
      from unnest(array[
        'Lukas','Mia','Paul','Emma','Leon','Hannah','Finn','Sofia','Noah','Lina',
        'Jonas','Lea','Ben','Marie','Tim','Anna','Nico','Laura','Felix','Nina',
        'David','Julia','Tom','Sarah','Max','Lisa','Jan','Clara','Simon','Johanna',
        'Erik','Katharina','Philipp','Alina','Moritz','Vanessa','Sebastian','Melina','Robin','Carla',
        'Daniel','Franziska','Marvin','Teresa','Kevin','Pia','Fabian','Jasmin','Patrick','Elena'
      ]::text[]) with ordinality as t(firstname, rn)
    ),
    last_names(lastname, rn) as (
      select *
      from unnest(array[
        'Mueller','Schmidt','Schneider','Fischer','Weber','Meyer','Wagner','Becker','Schulz','Hoffmann',
        'Schaefer','Koch','Bauer','Richter','Klein','Wolf','Schroeder','Neumann','Schwarz','Zimmermann',
        'Braun','Krueger','Hofmann','Hartmann','Lange','Schmitt','Werner','Krause','Meier','Lehmann',
        'Schmid','Schulze','Maier','Koenig','Mayer','Huber','Kaiser','Fuchs','Peters','Lang',
        'Scholz','Moeller','Weiss','Jung','Hahn','Vogel','Winter','Keller','Franke','Berger'
      ]::text[]) with ordinality as t(lastname, rn)
    ),
    src as (
      select
        f.firstname,
        l.lastname,
        f.rn
      from first_names f
      join last_names l on l.rn = f.rn
    ),
    ins as (
      insert into public.members (firstname, lastname, active, is_guest, settled, created_at)
      select
        s.firstname,
        s.lastname,
        true as active,
        (s.rn between 46 and 50) as is_guest,
        false as settled,
        now() - (random() * interval '300 days') as created_at
      from src s
      returning
        id,
        is_guest,
        nullif(trim(coalesce(firstname, '') || ' ' || coalesce(lastname, '')), '') as member_name
    )
  insert into tmp_demo_members_source (id, is_guest, member_name)
  select id, is_guest, member_name
  from ins;

  -- No PINs for demo members.
  delete from public.member_pins mp
  using tmp_demo_members_source d
  where mp.member_id = d.id;

  -- Dedicated PIN member for terminal PIN use-case.
  select m.id
  into v_pin_member_id
  from public.members m
  where m.firstname = 'Test'
    and m.lastname = 'Pin'
  order by m.created_at asc
  limit 1;

  if v_pin_member_id is null then
    insert into public.members (firstname, lastname, active, is_guest, settled, created_at)
    values ('Test', 'Pin', true, false, false, now())
    returning id into v_pin_member_id;
  end if;

  insert into public.member_pins (member_id, pin_plain)
  values (v_pin_member_id, '1234')
  on conflict (member_id) do update
    set pin_plain = excluded.pin_plain;

  -- 4) Products (20 in 2 categories: Getraenke + Essen)
  insert into public.product_categories (name, active, sort_order)
  values
    ('Getraenke', true, 10),
    ('Essen', true, 20),
    ('Sonstiges', true, 999)
  on conflict (name) do nothing;

  with seed(name, category, price, guest_price, inventoried) as (
    values
      ('Cola 0.33', 'Getraenke', 180, 220, true),
      ('Cola Zero 0.33', 'Getraenke', 180, 220, true),
      ('Wasser still 0.50', 'Getraenke', 120, 150, true),
      ('Wasser sprudel 0.50', 'Getraenke', 120, 150, true),
      ('Apfelschorle 0.50', 'Getraenke', 170, 210, true),
      ('Spezi 0.33', 'Getraenke', 190, 230, true),
      ('Eistee Pfirsich 0.50', 'Getraenke', 180, 220, true),
      ('Eistee Zitrone 0.50', 'Getraenke', 180, 220, true),
      ('Johannisbeer-Schorle 0.50', 'Getraenke', 180, 220, true),
      ('Iso Drink 0.50', 'Getraenke', 220, 260, true),

      ('Kaesebrot', 'Essen', 250, 290, true),
      ('Schinkenbrot', 'Essen', 280, 320, true),
      ('Breze', 'Essen', 170, 210, true),
      ('Laugenstange Kaese', 'Essen', 220, 260, true),
      ('Hotdog', 'Essen', 300, 350, true),
      ('Bockwurst', 'Essen', 280, 330, true),
      ('Frikadellenbroetchen', 'Essen', 330, 380, true),
      ('Kartoffelsalat Becher', 'Essen', 260, 310, true),
      ('Obstbecher', 'Essen', 240, 280, true),
      ('Muffin', 'Essen', 200, 240, true)
  )
  insert into public.products (
    name, category, price, guest_price, active, inventoried, created_at
  )
  select
    s.name,
    s.category,
    s.price,
    s.guest_price,
    true,
    s.inventoried,
    now() - (random() * interval '300 days')
  from seed s
  on conflict do nothing;

  -- Prepare temporary pools for random generation.
  create temporary table tmp_demo_members on commit drop as
  select
    d.id,
    d.is_guest,
    d.member_name
  from tmp_demo_members_source d;

  create temporary table tmp_demo_products on commit drop as
  select
    p.id,
    p.name,
    p.category,
    p.price,
    p.guest_price,
    p.inventoried,
    p.active
  from public.products p
  where p.name in (
    'Cola 0.33','Cola Zero 0.33','Wasser still 0.50','Wasser sprudel 0.50','Apfelschorle 0.50',
    'Spezi 0.33','Eistee Pfirsich 0.50','Eistee Zitrone 0.50','Johannisbeer-Schorle 0.50','Iso Drink 0.50',
    'Kaesebrot','Schinkenbrot','Breze','Laugenstange Kaese','Hotdog',
    'Bockwurst','Frikadellenbroetchen','Kartoffelsalat Becher','Obstbecher','Muffin'
  );

  -- 4b) Product demo images stored directly in DB (no storage bucket needed).
  update public.products p
  set product_image_data_url =
    'data:image/svg+xml;base64,' ||
    encode(
      convert_to(
        format(
          '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0%%" stop-color="%s"/><stop offset="100%%" stop-color="%s"/></linearGradient></defs><rect width="512" height="512" fill="url(#g)"/><rect x="24" y="350" width="464" height="138" rx="16" fill="#000" opacity="0.30"/><text x="36" y="410" fill="#fff" font-family="Arial,sans-serif" font-size="34" font-weight="700">%s</text><text x="36" y="448" fill="#fff" font-family="Arial,sans-serif" font-size="20" opacity="0.9">%s</text></svg>',
          case when tp.category = 'Getraenke' then '#0b1f3a' else '#3b1208' end,
          case when tp.category = 'Getraenke' then '#1e66d0' else '#c9471e' end,
          tp.name,
          tp.category
        ),
        'UTF8'
      ),
      'base64'
    )
  from tmp_demo_products tp
  where p.id = tp.id;

  -- 5) Stock baseline + refills/transfers
  insert into public.inventory_movements (
    product_id, quantity, from_location_id, to_location_id, reason, note, created_by, created_at, meta
  )
  select
    p.id,
    (120 + floor(random() * 280))::int,
    null,
    public.get_stock_location_id('warehouse'),
    'purchase',
    '[demo-seed] Anfangsbestand Lager',
    v_admin_id,
    now() - (random() * interval '120 days'),
    jsonb_build_object('source', 'demo_seed')
  from tmp_demo_products p
  where p.inventoried = true;

  insert into public.stock_adjustments (
    product_id, quantity, device_id, member_id, member_name_snapshot, note, created_at
  )
  select
    p.id,
    (20 + floor(random() * 80))::int,
    v_device_id,
    m.id,
    m.member_name,
    '[demo-seed] Auffuellen Kuehlschrank',
    now() - (random() * interval '180 days')
  from tmp_demo_products p
  join lateral (
    select id, member_name
    from tmp_demo_members
    where is_guest = false
    order by random()
    limit 1
  ) m on true
  where p.inventoried = true;

  insert into public.stock_adjustments (
    product_id, quantity, device_id, member_id, member_name_snapshot, note, created_at
  )
  select
    p.id,
    -1 * (5 + floor(random() * 20))::int,
    v_device_id,
    m.id,
    m.member_name,
    '[demo-seed] Rueckraeumung',
    now() - (random() * interval '90 days')
  from (
    select *
    from tmp_demo_products
    where inventoried = true
    order by random()
    limit 8
  ) p
  join lateral (
    select id, member_name
    from tmp_demo_members
    where is_guest = false
    order by random()
    limit 1
  ) m on true;

  -- 6) Exactly 1000 bookings over last 30 days, distributed across all demo members.
  with member_slots as (
    select
      m.id as member_id,
      m.is_guest,
      m.member_name,
      gs as slot
    from tmp_demo_members m
    cross join generate_series(1, 20) gs
  ),
  generated as (
    select
      row_number() over (order by ms.member_id, ms.slot) as gs,
      ms.member_id,
      ms.is_guest,
      ms.member_name,
      p.id as product_id,
      p.name as product_name,
      p.price,
      p.guest_price,
      p.inventoried,
      case
        -- Guarantee bookings on the current day.
        when ms.slot = 1 then
          now() - (random() * (now() - date_trunc('day', now())))
        -- Remaining bookings spread across the previous 29 full days.
        else
          (date_trunc('day', now()) - interval '29 days') + (random() * interval '29 days')
      end as created_at,
      (random() < 0.90) as has_device,
      random() as r
    from member_slots ms
    join lateral (
      select *
      from tmp_demo_products
      where active = true
      order by random()
      limit 1
    ) p on true
  ),
  ins as (
    insert into public.transactions (
      id,
      member_id,
      product_id,
      amount,
      note,
      created_at,
      client_tx_id,
      settled_at,
      member_name_snapshot,
      product_name_snapshot,
      product_price_snapshot,
      transaction_type,
      device_id,
      device_id_snapshot
    )
    select
      gen_random_uuid(),
      g.member_id,
      case when g.r < 0.84 then g.product_id else null end,
      case
        when g.r < 0.84 then -abs(case when g.is_guest then g.guest_price else g.price end)
        when g.r < 0.93 then -1 * (100 + floor(random() * 900))::int
        when g.r < 0.97 then -1 * (200 + floor(random() * 1500))::int
        else (200 + floor(random() * 2500))::int
      end as amount,
      case
        when g.r < 0.84 then null
        when g.r < 0.93 then '[demo-seed] Freier Betrag'
        when g.r < 0.97 then '[demo-seed] Bar-Entnahme'
        else '[demo-seed] Guthabenbuchung'
      end as note,
      g.created_at,
      gen_random_uuid(),
      case
        when g.created_at < now() - interval '25 days' and random() < 0.35
          then g.created_at + (random() * interval '20 days')
        else null
      end as settled_at,
      coalesce(g.member_name, g.member_id::text),
      case when g.r < 0.84 then g.product_name else null end,
      case when g.r < 0.84 then (case when g.is_guest then g.guest_price else g.price end) else null end,
      case
        when g.r < 0.84 then 'sale_product'
        when g.r < 0.93 then 'sale_free_amount'
        when g.r < 0.97 then 'cash_withdrawal'
        else 'credit_adjustment'
      end as transaction_type,
      case when g.has_device then v_device_id else null end as device_id,
      case when g.has_device then v_device_id else null end as device_id_snapshot
    from generated g
    returning id, product_id, created_at
  )
  insert into public.inventory_movements (
    product_id, quantity, from_location_id, to_location_id, reason, transaction_id, note, created_by, device_id, device_id_snapshot, created_at, meta
  )
  select
    i.product_id,
    1,
    public.get_stock_location_id('fridge'),
    null,
    'sale',
    i.id,
    '[demo-seed] Verkauf',
    v_operator_id,
    v_device_id,
    v_device_id,
    i.created_at,
    jsonb_build_object('source', 'demo_seed')
  from ins i
  join public.products p on p.id = i.product_id
  where i.product_id is not null
    and p.inventoried = true;

  -- 7) Additional cancellation use-case data (storno_log + stock return movements)
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
  )
  select
    t.id,
    t.member_id,
    t.product_id,
    t.created_at,
    greatest(t.created_at + (random() * interval '10 days'), t.created_at + interval '1 hour'),
    t.amount,
    coalesce(t.note, '[demo-seed] Storno'),
    t.transaction_type,
    coalesce(t.device_id, v_device_id),
    coalesce(t.device_id_snapshot, t.device_id, v_device_id)
  from public.transactions t
  join tmp_demo_members_source d on d.id = t.member_id
  where true
    and t.amount <> 0
  order by random()
  limit 120;

  insert into public.inventory_movements (
    product_id, quantity, from_location_id, to_location_id, reason, note, created_by, device_id, device_id_snapshot, created_at, meta
  )
  select
    s.product_id,
    1,
    null,
    public.get_stock_location_id('fridge'),
    'sale_cancel',
    '[demo-seed] Storno Rueckbuchung',
    v_admin_id,
    coalesce(s.device_id, v_device_id),
    coalesce(s.device_id_snapshot, s.device_id, v_device_id),
    s.canceled_at,
    jsonb_build_object('source', 'demo_seed', 'original_transaction_id', s.original_transaction_id)
  from public.storno_log s
  where s.product_id is not null
  order by s.canceled_at desc
  limit 80;

  -- 8) Recompute demo member balances from transactions
  update public.members m
  set balance = coalesce(x.total, 0),
      settled = false
  from (
    select t.member_id, sum(t.amount)::int as total
    from public.transactions t
    join tmp_demo_members_source d on d.id = t.member_id
    where true
    group by t.member_id
  ) x
  where m.id = x.member_id;

  -- 9) Settlements use-case for a subset of members
  create temporary table tmp_demo_settle on commit drop as
  select
    m.id as member_id,
    now() - (random() * interval '45 days') as settled_at
  from public.members m
  join tmp_demo_members_source d on d.id = m.id
  where true
    and m.is_guest = false
    and m.balance < 0
  order by random()
  limit 8;

  insert into public.settlements (member_id, user_id, settled_at, amount)
  select
    s.member_id,
    v_admin_id,
    s.settled_at,
    m.balance
  from tmp_demo_settle s
  join public.members m on m.id = s.member_id
  on conflict (member_id, settled_at) do nothing;

  update public.transactions t
  set settled_at = coalesce(t.settled_at, s.settled_at)
  from tmp_demo_settle s
  where t.member_id = s.member_id
    and t.created_at < s.settled_at;

  update public.members m
  set balance = 0,
      last_settled_at = s.settled_at,
      settled = true
  from tmp_demo_settle s
  where m.id = s.member_id;

  -- 9b) Device pairing demo data (open, used, expired).
  -- Open demo code for "Demo Terminal": 1234 (valid for 50 years).
  insert into public.device_pairing_codes (
    device_id, code_hash, created_by, created_at, expires_at, used_at
  ) values
    (
      v_device_id,
      encode(digest('1234', 'sha256'), 'hex'),
      v_admin_id,
      now() - interval '30 seconds',
      now() + interval '50 years',
      null
    ),
    (
      v_device_id,
      encode(digest('222222', 'sha256'), 'hex'),
      v_admin_id,
      now() - interval '25 minutes',
      now() + interval '5 minutes',
      now() - interval '20 minutes'
    ),
    (
      v_device_id,
      encode(digest('333333', 'sha256'), 'hex'),
      v_admin_id,
      now() - interval '2 days',
      now() - interval '1 day',
      null
    )
  on conflict do nothing;

  -- 10) Inventory correction use-cases
  insert into public.inventory_movements (
    product_id, quantity, from_location_id, to_location_id, reason, note, created_by, created_at, meta
  )
  select
    p.id,
    (1 + floor(random() * 3))::int,
    case when random() < 0.5 then public.get_stock_location_id('warehouse') else public.get_stock_location_id('fridge') end,
    null,
    case
      when random() < 0.34 then 'shrinkage'
      when random() < 0.67 then 'waste'
      else 'count_adjustment'
    end,
    '[demo-seed] Inventur/Korrektur',
    v_admin_id,
    now() - (random() * interval '180 days'),
    jsonb_build_object('source', 'demo_seed')
  from (
    select *
    from tmp_demo_products
    where inventoried = true
    order by random()
    limit 30
  ) p;

  -- 11) Session use-cases (active + revoked)
  insert into public.app_sessions (
    token_hash, actor_type, actor_id, role, expires_at, revoked_at, user_agent, created_at, last_seen_at
  ) values
    (
      encode(digest('demo-admin-token', 'sha256'), 'hex'),
      'user',
      v_admin_id,
      'admin',
      now() + interval '30 days',
      null,
      'demo-seed/admin',
      now() - interval '2 days',
      now() - interval '1 hour'
    ),
    (
      encode(digest('demo-device-token', 'sha256'), 'hex'),
      'device',
      v_device_id,
      'device',
      now() + interval '30 days',
      null,
      'demo-seed/device',
      now() - interval '1 day',
      now() - interval '10 minutes'
    ),
    (
      encode(digest('demo-old-revoked-token', 'sha256'), 'hex'),
      'user',
      v_operator_id,
      'operator',
      now() + interval '1 day',
      now() - interval '2 hours',
      'demo-seed/revoked',
      now() - interval '5 days',
      now() - interval '2 days'
    ),
    (
      encode(digest('demo-stale-device-token', 'sha256'), 'hex'),
      'device',
      v_device_id,
      'device',
      now() + interval '90 days',
      null,
      'demo-seed/device-stale',
      now() - interval '45 days',
      now() - interval '45 days'
    )
  on conflict (token_hash) do update
    set revoked_at = excluded.revoked_at,
        expires_at = excluded.expires_at,
        last_seen_at = excluded.last_seen_at;
end
$$;

commit;


