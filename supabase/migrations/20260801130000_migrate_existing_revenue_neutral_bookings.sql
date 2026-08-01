create or replace function public.migrate_existing_product_bookings_to_non_revenue()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  if old.revenue_neutral is distinct from true
     and new.revenue_neutral = true
  then
    update public.transactions t
    set transaction_type = 'non_revenue_product'
    where t.product_id = new.id
      and (
        t.transaction_type is null
        or t.transaction_type = 'sale_product'
      );

    update public.storno_log s
    set transaction_type = 'non_revenue_product'
    where s.product_id = new.id
      and (
        s.transaction_type is null
        or s.transaction_type = 'sale_product'
      );
  end if;

  return new;
end;
$function$;

drop trigger if exists products_migrate_existing_bookings_to_non_revenue
  on public.products;

create trigger products_migrate_existing_bookings_to_non_revenue
after update of revenue_neutral on public.products
for each row
execute function public.migrate_existing_product_bookings_to_non_revenue();

-- Backfill products that were already marked as revenue neutral before this
-- migration was installed.
update public.transactions t
set transaction_type = 'non_revenue_product'
from public.products p
where p.id = t.product_id
  and p.revenue_neutral = true
  and (
    t.transaction_type is null
    or t.transaction_type = 'sale_product'
  );

update public.storno_log s
set transaction_type = 'non_revenue_product'
from public.products p
where p.id = s.product_id
  and p.revenue_neutral = true
  and (
    s.transaction_type is null
    or s.transaction_type = 'sale_product'
  );

comment on function public.migrate_existing_product_bookings_to_non_revenue() is
  'Migrates existing regular bookings and cancellations when a product becomes revenue neutral.';

revoke all on function public.migrate_existing_product_bookings_to_non_revenue()
  from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.migrate_existing_product_bookings_to_non_revenue() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.migrate_existing_product_bookings_to_non_revenue() from authenticated';
  end if;
end
$$;

notify pgrst, 'reload schema';
