-- Hard cleanup: remove legacy admins table and dependencies.
-- Authorization is role-based via app_users.role = 'admin'.

do $$
declare
  r record;
begin
  -- Drop any policies that still reference legacy "admins".
  for r in
    select
      quote_ident(p.polname) as policy_name,
      quote_ident(n.nspname) || '.' || quote_ident(c.relname) as table_name
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where coalesce(pg_get_expr(p.polqual, p.polrelid), '') ilike '%admins%'
       or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') ilike '%admins%'
  loop
    execute format('drop policy if exists %s on %s', r.policy_name, r.table_name);
  end loop;

  if to_regclass('public.admins') is not null then
    drop table public.admins;
  end if;
end
$$;
