create or replace function public.admin_mark_transaction_complimentary(
  p_transaction_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_tx public.transactions%rowtype;
  v_member_active boolean;
  v_balance_delta integer;
begin
  perform public.assert_admin();

  select *
  into v_tx
  from public.transactions t
  where t.id = p_transaction_id
  for update;

  if not found then
    raise exception 'Buchung nicht gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen als Freigetraenk umgebucht werden';
  end if;

  select m.active
  into v_member_active
  from public.members m
  where m.id = v_tx.member_id;

  if coalesce(v_member_active, false) = false then
    raise exception 'Buchungen von inaktiven Mitgliedern duerfen nicht umgebucht werden';
  end if;

  if v_tx.product_id is null then
    raise exception 'Nur Produktbuchungen koennen als Freigetraenk umgebucht werden';
  end if;

  if coalesce(v_tx.transaction_type, 'sale_product') = 'complimentary_product'
    and coalesce(v_tx.amount, 0) = 0 then
    return v_tx.id;
  end if;

  v_balance_delta := -coalesce(v_tx.amount, 0);

  update public.transactions t
  set
    amount = 0,
    transaction_type = 'complimentary_product',
    note = concat_ws('; ', nullif(t.note, ''), 'Freigetraenk')
  where t.id = v_tx.id;

  if v_balance_delta <> 0 then
    update public.members m
    set balance = m.balance + v_balance_delta
    where m.id = v_tx.member_id;
  end if;

  return v_tx.id;
end;
$function$;

create or replace function public.api_admin_mark_transaction_complimentary(
  p_token text,
  p_transaction_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_mark_transaction_complimentary(p_transaction_id);
end;
$function$;

revoke all on function public.admin_mark_transaction_complimentary(uuid) from public;
revoke all on function public.api_admin_mark_transaction_complimentary(text, uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_mark_transaction_complimentary(text, uuid) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';
