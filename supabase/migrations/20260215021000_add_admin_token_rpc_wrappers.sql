-- Token-based RPC wrappers for admin API endpoints.
-- These wrappers apply app session context and then call existing admin RPCs.

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
  last_restocked_at timestamp with time zone
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

create or replace function public.api_admin_create_product(
  p_token text,
  p_name text,
  p_price integer,
  p_guest_price integer,
  p_category text,
  p_active boolean,
  p_inventoried boolean
)
returns public.products
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_create_product(
    p_name,
    p_price,
    p_guest_price,
    p_category,
    p_active,
    p_inventoried
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
  p_inventoried boolean default null
)
returns public.products
language plpgsql
security definer
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
    p_inventoried
  );
end;
$function$;

create or replace function public.api_admin_delete_product(
  p_token text,
  p_product_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.admin_delete_product(p_product_id, p_force);
end;
$function$;

create or replace function public.api_admin_list_members()
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  raise exception 'Use api_admin_list_members_token(p_token)';
end;
$function$;

drop function if exists public.api_admin_list_members();

create or replace function public.api_admin_list_members_token(p_token text)
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  active boolean,
  created_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_members();
end;
$function$;

create or replace function public.api_admin_create_member(
  p_token text,
  p_firstname text,
  p_lastname text
)
returns public.members
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_create_member(p_firstname, p_lastname);
end;
$function$;

create or replace function public.api_admin_update_member(
  p_token text,
  p_id uuid,
  p_firstname text default null,
  p_lastname text default null,
  p_balance integer default null,
  p_active boolean default null
)
returns public.members
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_update_member(
    p_id,
    p_firstname,
    p_lastname,
    p_balance,
    p_active
  );
end;
$function$;

create or replace function public.api_admin_delete_member(
  p_token text,
  p_member_id uuid,
  p_force boolean default false
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.admin_delete_member(p_member_id, p_force);
end;
$function$;

create or replace function public.api_admin_add_storage(
  p_token text,
  p_product_id uuid,
  p_amount integer
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  perform public.add_storage(p_product_id, p_amount);
end;
$function$;

revoke all on function public.api_admin_list_products(text) from public;
revoke all on function public.api_admin_create_product(text, text, integer, integer, text, boolean, boolean) from public;
revoke all on function public.api_admin_update_product(text, uuid, text, integer, integer, text, boolean, boolean) from public;
revoke all on function public.api_admin_delete_product(text, uuid, boolean) from public;
revoke all on function public.api_admin_list_members_token(text) from public;
revoke all on function public.api_admin_create_member(text, text, text) from public;
revoke all on function public.api_admin_update_member(text, uuid, text, text, integer, boolean) from public;
revoke all on function public.api_admin_delete_member(text, uuid, boolean) from public;
revoke all on function public.api_admin_add_storage(text, uuid, integer) from public;

create or replace function public.api_admin_get_inventory_snapshot(p_token text)
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  soll_warehouse_stock integer,
  soll_fridge_stock integer,
  soll_total_stock integer
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_inventory_snapshot();
end;
$function$;

create or replace function public.api_admin_apply_inventory_count(
  p_token text,
  p_items jsonb,
  p_note text default null
)
returns table(
  product_id uuid,
  name text,
  soll_warehouse_stock integer,
  ist_warehouse_stock integer,
  delta_warehouse integer,
  soll_fridge_stock integer,
  ist_fridge_stock integer,
  delta_fridge integer
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_apply_inventory_count(p_items, p_note);
end;
$function$;

create or replace function public.api_admin_get_inventory_adjustments_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_inventory_adjustments_period(p_start, p_end);
end;
$function$;

create or replace function public.api_admin_get_fridge_refills_period(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  stock_adjustment_id uuid,
  product_id uuid,
  product_name text,
  product_category text,
  quantity integer,
  member_id uuid,
  member_name text,
  device_id uuid,
  device_name text,
  note text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_fridge_refills_period(p_start, p_end);
end;
$function$;

create or replace function public.api_admin_get_all_bookings_grouped(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  local_day date,
  member_id uuid,
  member_name text,
  member_active boolean,
  total integer,
  items jsonb
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_get_all_bookings_grouped(p_start, p_end);
end;
$function$;

create or replace function public.api_admin_cancel_transaction(
  p_token text,
  p_cancel_tx_id uuid default null,
  p_member_id uuid default null,
  p_product_id uuid default null,
  p_note text default null
)
returns uuid
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return public.cancel_transaction(p_cancel_tx_id, p_member_id, p_product_id, p_note);
end;
$function$;

create or replace function public.api_admin_book_free_amount(
  p_token text,
  p_member_id uuid,
  p_amount_cents integer,
  p_note text default null
)
returns uuid
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return public.book_transaction(
    p_member_id,
    null,
    p_amount_cents,
    p_note,
    null
  );
end;
$function$;

create or replace function public.api_admin_perform_monthly_settlement(p_token text)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.admin_perform_monthly_settlement();
end;
$function$;

create or replace function public.api_admin_list_members_balances(p_token text)
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  last_settled_at timestamp with time zone
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select
    m.id,
    m.firstname,
    m.lastname,
    m.balance,
    m.last_settled_at
  from public.members m
  where m.balance <> 0
    and m.is_guest = false
  order by m.lastname asc, m.firstname asc;
end;
$function$;

create or replace function public.api_admin_list_member_pins(p_token text)
returns table(
  member_id uuid,
  pin_plain text
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select mp.member_id, mp.pin_plain
  from public.member_pins mp;
end;
$function$;

create or replace function public.api_admin_upsert_member_pin(
  p_token text,
  p_member_id uuid,
  p_pin_plain text
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  insert into public.member_pins(member_id, pin_plain)
  values (p_member_id, p_pin_plain)
  on conflict (member_id) do update
  set pin_plain = excluded.pin_plain;
end;
$function$;

create or replace function public.api_admin_delete_member_pin(
  p_token text,
  p_member_id uuid
)
returns void
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  delete from public.member_pins
  where member_id = p_member_id;
end;
$function$;

revoke all on function public.api_admin_get_inventory_snapshot(text) from public;
revoke all on function public.api_admin_apply_inventory_count(text, jsonb, text) from public;
revoke all on function public.api_admin_get_inventory_adjustments_period(text, timestamp with time zone, timestamp with time zone) from public;
revoke all on function public.api_admin_get_fridge_refills_period(text, timestamp with time zone, timestamp with time zone) from public;
revoke all on function public.api_admin_get_all_bookings_grouped(text, timestamp with time zone, timestamp with time zone) from public;
revoke all on function public.api_admin_cancel_transaction(text, uuid, uuid, uuid, text) from public;
revoke all on function public.api_admin_book_free_amount(text, uuid, integer, text) from public;
revoke all on function public.api_admin_perform_monthly_settlement(text) from public;
revoke all on function public.api_admin_list_members_balances(text) from public;
revoke all on function public.api_admin_list_member_pins(text) from public;
revoke all on function public.api_admin_upsert_member_pin(text, uuid, text) from public;
revoke all on function public.api_admin_delete_member_pin(text, uuid) from public;

create or replace function public.api_admin_stats_sales_trend(
  p_token text,
  p_range text
)
returns table(tag date, umsatz_eur numeric)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select * from public.stats_sales_trend(p_range);
end;
$function$;

create or replace function public.api_admin_stats_top_products_period(
  p_token text,
  p_range text
)
returns table(product text, qty integer)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select * from public.stats_top_products_period(p_range);
end;
$function$;

create or replace function public.api_admin_stats_activity_heatmap_period(
  p_token text,
  p_range text
)
returns table(wochentag integer, stunde integer, anzahl_tx integer)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select * from public.stats_activity_heatmap_period(p_range);
end;
$function$;

create or replace function public.api_admin_stats_active_members_period(
  p_token text,
  p_range text
)
returns table(active_count integer)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  return query
  select * from public.stats_active_members_period(p_range);
end;
$function$;

revoke all on function public.api_admin_stats_sales_trend(text, text) from public;
revoke all on function public.api_admin_stats_top_products_period(text, text) from public;
revoke all on function public.api_admin_stats_activity_heatmap_period(text, text) from public;
revoke all on function public.api_admin_stats_active_members_period(text, text) from public;
