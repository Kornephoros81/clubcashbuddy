-- When an admin maintains a product EK, use it to fill historical direct-cost
-- product transactions that still have no EK snapshot and are not lot/FIFO
-- backed. Existing non-zero snapshots and lot allocations remain untouched.

create or replace function public.admin_update_product(
  p_id uuid,
  p_name text default null,
  p_price integer default null,
  p_guest_price integer default null,
  p_category text default null,
  p_active boolean default null,
  p_inventoried boolean default null,
  p_last_purchase_price_cents integer default null
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
    last_purchase_price_cents = coalesce(greatest(0, p_last_purchase_price_cents), p.last_purchase_price_cents)
  where p.id = p_id
  returning * into v_row;

  if p_last_purchase_price_cents is not null and greatest(0, p_last_purchase_price_cents) > 0 then
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

revoke all on function public.admin_update_product(uuid, text, integer, integer, text, boolean, boolean, integer) from public;

notify pgrst, 'reload schema';
