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
