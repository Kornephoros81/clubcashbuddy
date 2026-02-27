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
