alter table public.products
  add column if not exists revenue_neutral boolean not null default false;

comment on column public.products.revenue_neutral is
  'True when product bookings must be excluded from revenue and margin reporting.';

alter table public.transactions
  drop constraint if exists transactions_transaction_type_chk;

alter table public.transactions
  add constraint transactions_transaction_type_chk
  check (
    transaction_type in (
      'sale_product',
      'sale_free_amount',
      'non_revenue_product',
      'cash_withdrawal',
      'credit_adjustment',
      'complimentary_product'
    )
  );

alter table public.storno_log
  drop constraint if exists storno_log_transaction_type_chk;

alter table public.storno_log
  add constraint storno_log_transaction_type_chk
  check (
    transaction_type in (
      'sale_product',
      'sale_free_amount',
      'non_revenue_product',
      'cash_withdrawal',
      'credit_adjustment',
      'complimentary_product'
    )
  );

create or replace function public.apply_product_revenue_type()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  if new.product_id is not null
     and new.transaction_type = 'sale_product'
     and exists (
       select 1
       from public.products p
       where p.id = new.product_id
         and p.revenue_neutral = true
     )
  then
    new.transaction_type := 'non_revenue_product';
  end if;

  return new;
end;
$function$;

drop trigger if exists transactions_apply_product_revenue_type on public.transactions;

create trigger transactions_apply_product_revenue_type
before insert on public.transactions
for each row
execute function public.apply_product_revenue_type();

create or replace function public.api_admin_create_product(
  p_token text,
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean,
  p_last_purchase_price_cents integer,
  p_mhd_sale_enabled boolean,
  p_package_size integer,
  p_revenue_neutral boolean
)
returns public.products
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_row public.products;
begin
  perform public.app_apply_session(p_token);

  v_row := public.admin_create_product(
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

  update public.products p
  set revenue_neutral = coalesce(p_revenue_neutral, false)
  where p.id = v_row.id
  returning * into v_row;

  return v_row;
end;
$function$;

create or replace function public.api_admin_update_product(
  p_token text,
  p_id uuid,
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean,
  p_last_purchase_price_cents integer,
  p_mhd_sale_enabled boolean,
  p_package_size integer,
  p_revenue_neutral boolean
)
returns public.products
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_row public.products;
begin
  perform public.app_apply_session(p_token);

  v_row := public.admin_update_product(
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

  if p_revenue_neutral is not null then
    update public.products p
    set revenue_neutral = p_revenue_neutral
    where p.id = v_row.id
    returning * into v_row;
  end if;

  return v_row;
end;
$function$;

revoke all on function public.apply_product_revenue_type() from public;
revoke all on function public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean, integer, boolean, integer, boolean) from public;
revoke all on function public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean, integer, boolean, integer, boolean) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean, integer, boolean, integer, boolean) from anon';
    execute 'revoke all on function public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean, integer, boolean, integer, boolean) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean, integer, boolean, integer, boolean) from authenticated';
    execute 'revoke all on function public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean, integer, boolean, integer, boolean) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean, integer, boolean, integer, boolean) to service_role';
    execute 'grant execute on function public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean, integer, boolean, integer, boolean) to service_role';
  end if;
end
$$;

notify pgrst, 'reload schema';
