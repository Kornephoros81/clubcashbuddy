-- Normalize product categories into a managed catalog and enforce referential integrity.

begin;

create table if not exists public.product_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamp with time zone not null default now(),
  constraint product_categories_name_not_blank_chk check (btrim(name) <> '')
);

-- Normalize existing product category values first.
update public.products p
set category = coalesce(nullif(btrim(p.category), ''), 'Sonstiges')
where true;

-- Ensure all legacy free-text categories exist in the managed catalog.
insert into public.product_categories (name, active, sort_order)
select distinct
  p.category,
  true,
  0
from public.products p
where p.category is not null
on conflict (name) do nothing;

-- Make sure default category exists even on empty datasets.
insert into public.product_categories (name, active, sort_order)
values ('Sonstiges', true, 999)
on conflict (name) do nothing;

alter table public.products
  drop constraint if exists products_category_fkey;

alter table public.products
  add constraint products_category_fkey
  foreign key (category)
  references public.product_categories (name)
  on update cascade
  on delete restrict;

create or replace function public.admin_list_product_categories()
returns table(
  id uuid,
  name text,
  active boolean,
  sort_order integer,
  created_at timestamp with time zone,
  product_count bigint
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();

  return query
  select
    c.id,
    c.name,
    c.active,
    c.sort_order,
    c.created_at,
    count(p.id)::bigint as product_count
  from public.product_categories c
  left join public.products p on p.category = c.name
  group by c.id, c.name, c.active, c.sort_order, c.created_at
  order by c.active desc, c.sort_order asc, c.name asc;
end;
$function$;

create or replace function public.admin_create_product_category(
  p_name text,
  p_active boolean default true,
  p_sort_order integer default 0
)
returns public.product_categories
language plpgsql
security definer
as $function$
declare
  v_row public.product_categories;
  v_name text;
begin
  perform public.assert_admin();
  v_name := nullif(btrim(coalesce(p_name, '')), '');
  if v_name is null then
    raise exception 'Kategorie-Name darf nicht leer sein';
  end if;

  insert into public.product_categories (name, active, sort_order)
  values (v_name, coalesce(p_active, true), coalesce(p_sort_order, 0))
  returning * into v_row;

  return v_row;
end;
$function$;

create or replace function public.admin_update_product_category(
  p_id uuid,
  p_name text default null,
  p_active boolean default null,
  p_sort_order integer default null
)
returns public.product_categories
language plpgsql
security definer
as $function$
declare
  v_row public.product_categories;
  v_name text;
begin
  perform public.assert_admin();
  v_name := case
    when p_name is null then null
    else nullif(btrim(p_name), '')
  end;

  if p_name is not null and v_name is null then
    raise exception 'Kategorie-Name darf nicht leer sein';
  end if;

  update public.product_categories c
  set
    name = coalesce(v_name, c.name),
    active = coalesce(p_active, c.active),
    sort_order = coalesce(p_sort_order, c.sort_order)
  where c.id = p_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Kategorie nicht gefunden';
  end if;

  return v_row;
end;
$function$;

revoke all on function public.admin_list_product_categories() from public;
grant execute on function public.admin_list_product_categories() to authenticated;

revoke all on function public.admin_create_product_category(text, boolean, integer) from public;
grant execute on function public.admin_create_product_category(text, boolean, integer) to authenticated;

revoke all on function public.admin_update_product_category(uuid, text, boolean, integer) from public;
grant execute on function public.admin_update_product_category(uuid, text, boolean, integer) to authenticated;

create or replace function public.api_admin_list_product_categories(p_token text)
returns table(
  id uuid,
  name text,
  active boolean,
  sort_order integer,
  created_at timestamp with time zone,
  product_count bigint
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_product_categories();
end;
$function$;

create or replace function public.api_admin_create_product_category(
  p_token text,
  p_name text,
  p_active boolean default true,
  p_sort_order integer default 0
)
returns public.product_categories
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_create_product_category(p_name, p_active, p_sort_order);
end;
$function$;

create or replace function public.api_admin_update_product_category(
  p_token text,
  p_id uuid,
  p_name text default null,
  p_active boolean default null,
  p_sort_order integer default null
)
returns public.product_categories
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_update_product_category(p_id, p_name, p_active, p_sort_order);
end;
$function$;

revoke all on function public.api_admin_list_product_categories(text) from public;
revoke all on function public.api_admin_create_product_category(text, text, boolean, integer) from public;
revoke all on function public.api_admin_update_product_category(text, uuid, text, boolean, integer) from public;

commit;
