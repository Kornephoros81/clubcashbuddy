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
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
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
    p.last_restocked_at,
    p.last_purchase_price_cents,
    p.inventory_value_cents
  from public.products p
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
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
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

revoke all on function public.api_admin_list_products(text) from public;

notify pgrst, 'reload schema';
