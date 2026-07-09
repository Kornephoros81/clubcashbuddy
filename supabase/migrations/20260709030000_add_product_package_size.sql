alter table public.products
  add column if not exists package_size integer null;

alter table public.products
  drop constraint if exists products_package_size_positive;

alter table public.products
  add constraint products_package_size_positive
  check (package_size is null or package_size > 0);

drop function if exists public.api_admin_list_products(text);
drop function if exists public.admin_list_products();

create or replace function public.admin_list_products()
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  mhd_sale_enabled boolean,
  package_size integer,
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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
    coalesce(p.mhd_sale_enabled, false) as mhd_sale_enabled,
    p.package_size,
    p.created_at,
    case when p.inventoried then coalesce(s.warehouse_qty, 0) else coalesce(p.warehouse_stock, 0) end::integer as warehouse_stock,
    0::integer as fridge_stock,
    p.last_restocked_at,
    p.last_purchase_price_cents,
    case when p.inventoried then coalesce(v.inventory_value_cents, 0) else coalesce(p.inventory_value_cents, 0) end::integer as inventory_value_cents
  from public.products p
  left join lateral public.get_product_stock(p.id) s on true
  left join lateral (
    select coalesce(sum(l.remaining_quantity * l.unit_cost_cents), 0)::integer as inventory_value_cents
    from public.product_purchase_lots l
    where l.product_id = p.id
      and l.source_reason <> 'sale_fallback'
      and l.remaining_quantity > 0
  ) v on true
  order by p.active desc, p.name asc;
end;
$function$;

create or replace function public.api_admin_list_products(p_token text)
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  mhd_sale_enabled boolean,
  package_size integer,
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_products();
end;
$function$;

drop function if exists public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean, integer, boolean);
drop function if exists public.admin_create_product(text, integer, integer, text, boolean, boolean, integer, boolean);

create or replace function public.admin_create_product(
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean,
  p_last_purchase_price_cents integer default 0,
  p_mhd_sale_enabled boolean default false,
  p_package_size integer default null
)
returns public.products
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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
    inventoried,
    last_purchase_price_cents,
    mhd_sale_enabled,
    package_size
  ) values (
    coalesce(p_name, 'Neu'),
    coalesce(p_price, 0),
    coalesce(p_guest_price, 0),
    coalesce(p_category, 'Sonstiges'),
    coalesce(p_active, true),
    coalesce(p_inventoried, true),
    greatest(0, coalesce(p_last_purchase_price_cents, 0)),
    coalesce(p_mhd_sale_enabled, false),
    case when coalesce(p_package_size, 0) > 0 then p_package_size else null end
  )
  returning * into v_row;

  return v_row;
end;
$function$;

drop function if exists public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean, integer, boolean);
drop function if exists public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean, integer, boolean);

create or replace function public.admin_update_product(
  p_id uuid,
  p_name text default null,
  p_price integer default null,
  p_guest_price integer default null,
  p_category text default null,
  p_active boolean default null,
  p_inventoried boolean default null,
  p_last_purchase_price_cents integer default null,
  p_mhd_sale_enabled boolean default null,
  p_package_size integer default null
)
returns public.products
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_current public.products;
  v_row public.products;
  v_stock record;
  v_lot record;
  v_next_inventoried boolean;
begin
  perform public.assert_admin();

  select *
  into v_current
  from public.products p
  where p.id = p_id
  for update;

  if not found then
    raise exception 'Produkt nicht gefunden';
  end if;

  v_next_inventoried := coalesce(p_inventoried, v_current.inventoried);

  if v_current.inventoried = true and v_next_inventoried = false then
    select *
    into v_stock
    from public.get_product_stock(p_id);

    if coalesce(v_stock.total_qty, 0) <> 0 then
      raise exception 'Artikel kann nur auf nicht inventarisiert umgestellt werden, wenn der Bestand 0 ist.';
    end if;
  end if;

  update public.products p
  set
    name = coalesce(p_name, p.name),
    price = coalesce(p_price, p.price),
    guest_price = coalesce(p_guest_price, p.guest_price),
    category = coalesce(p_category, p.category),
    active = coalesce(p_active, p.active),
    inventoried = v_next_inventoried,
    last_purchase_price_cents = coalesce(greatest(0, p_last_purchase_price_cents), p.last_purchase_price_cents),
    mhd_sale_enabled = coalesce(p_mhd_sale_enabled, p.mhd_sale_enabled),
    package_size = case
      when p_package_size is null then p.package_size
      when p_package_size > 0 then p_package_size
      else null
    end
  where p.id = p_id
  returning * into v_row;

  if p_last_purchase_price_cents is not null and greatest(0, p_last_purchase_price_cents) > 0 then
    if v_next_inventoried = true then
      for v_lot in
        select l.id, l.note
        from public.product_purchase_lots l
        where l.product_id = p_id
          and (
            coalesce(l.unit_cost_cents, 0) = 0
            or coalesce(l.cost_pending, false) = true
          )
        order by l.created_at asc, l.id asc
      loop
        perform public.admin_update_purchase_lot_cost(
          v_lot.id,
          greatest(0, p_last_purchase_price_cents),
          v_lot.note
        );
      end loop;
    end if;

    update public.transactions t
    set
      product_cost_snapshot_cents = greatest(0, p_last_purchase_price_cents),
      product_inventoried_snapshot = coalesce(t.product_inventoried_snapshot, false)
    where t.product_id = p_id
      and t.amount < 0
      and coalesce(t.product_cost_snapshot_cents, 0) = 0
      and (v_next_inventoried = false or t.product_inventoried_snapshot = false)
      and not exists (
        select 1
        from public.product_lot_allocations a
        where a.source_transaction_id = t.id
      );
  end if;

  return v_row;
end;
$function$;

create or replace function public.api_admin_create_product(
  p_token text,
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean,
  p_last_purchase_price_cents integer default 0,
  p_mhd_sale_enabled boolean default false,
  p_package_size integer default null
)
returns public.products
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_create_product(
    p_name,
    p_price,
    p_guest_price,
    p_category,
    p_active,
    p_inventoried,
    p_last_purchase_price_cents,
    p_mhd_sale_enabled,
    p_package_size
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
  p_inventoried boolean default null,
  p_last_purchase_price_cents integer default null,
  p_mhd_sale_enabled boolean default null,
  p_package_size integer default null
)
returns public.products
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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
    p_inventoried,
    p_last_purchase_price_cents,
    p_mhd_sale_enabled,
    p_package_size
  );
end;
$function$;

revoke all on function public.admin_list_products() from public;
revoke all on function public.api_admin_list_products(text) from public;
revoke all on function public.admin_create_product(text, integer, integer, text, boolean, boolean, integer, boolean, integer) from public;
revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean, integer, boolean, integer) from public;
revoke all on function public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean, integer, boolean, integer) from public;
revoke all on function public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean, integer, boolean, integer) from public;

notify pgrst, 'reload schema';
