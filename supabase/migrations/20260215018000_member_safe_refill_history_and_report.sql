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
