-- Monthly settlement must close the transaction rows it settles.

create or replace function public.perform_monthly_settlement(p_user_id uuid)
returns void
language plpgsql
security definer
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

-- Backfill older monthly settlements where the member was marked settled
-- but the underlying transactions were left open.
update public.transactions t
set settled_at = m.last_settled_at
from public.members m
where t.member_id = m.id
  and t.settled_at is null
  and m.last_settled_at is not null
  and t.created_at <= m.last_settled_at;

drop function if exists public.api_admin_list_members_balances(text);
create or replace function public.api_admin_list_members_balances(p_token text)
returns table(
  id uuid,
  firstname text,
  lastname text,
  balance integer,
  last_settled_at timestamp with time zone,
  open_transactions integer,
  open_amount integer
)
language plpgsql
security definer
as $function$
begin
  perform public.app_apply_session(p_token);
  perform public.assert_admin();

  return query
  with open_tx as (
    select
      t.member_id,
      count(*)::integer as open_transactions,
      coalesce(sum(t.amount), 0)::integer as open_amount
    from public.transactions t
    where t.settled_at is null
    group by t.member_id
  )
  select
    m.id,
    m.firstname,
    m.lastname,
    m.balance,
    m.last_settled_at,
    coalesce(open_tx.open_transactions, 0)::integer as open_transactions,
    coalesce(open_tx.open_amount, 0)::integer as open_amount
  from public.members m
  left join open_tx on open_tx.member_id = m.id
  where m.is_guest = false
    and (
      m.balance <> 0
      or coalesce(open_tx.open_transactions, 0) > 0
    )
  order by m.lastname asc, m.firstname asc;
end;
$function$;

revoke all on function public.api_admin_list_members_balances(text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_list_members_balances(text) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';
