-- Production safety migration: ensure the single-member settlement core
-- function exists before RPC wrappers call it.

create or replace function public.perform_member_settlement(
  p_user_id uuid,
  p_member_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  r record;
  v_settled_at timestamp with time zone := now();
begin
  for r in
    select
      m.id,
      m.balance
    from public.members m
    where m.is_guest = false
      and (p_member_id is null or m.id = p_member_id)
      and (
        m.balance <> 0
        or exists (
          select 1
          from public.transactions t
          where t.member_id = m.id
            and t.settled_at is null
        )
      )
  loop
    if r.balance < 0 then
      insert into public.settlements (member_id, user_id, settled_at, amount)
      values (r.id, p_user_id, v_settled_at, r.balance);
    end if;

    update public.transactions t
    set settled_at = v_settled_at
    where t.member_id = r.id
      and t.settled_at is null;

    update public.members m
    set
      balance = case when m.balance < 0 then 0 else m.balance end,
      last_settled_at = v_settled_at
    where m.id = r.id;
  end loop;
end;
$function$;

create or replace function public.perform_monthly_settlement(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.perform_member_settlement(p_user_id, null);
end;
$function$;

create or replace function public.api_admin_perform_member_settlement_v2(
  p_token text,
  p_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();
  perform public.perform_member_settlement(public.app_current_user_id(), p_member_id);
end;
$function$;

revoke all on function public.perform_member_settlement(uuid, uuid) from public;
revoke all on function public.perform_monthly_settlement(uuid) from public;
revoke all on function public.api_admin_perform_member_settlement_v2(text, uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_perform_member_settlement_v2(text, uuid) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';
