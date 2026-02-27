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
