-- Harden remaining unrestricted objects:
-- - member_pins (table)
-- - storno_log (table)
-- - stock_overview (view)
--
-- Strategy: deny direct client access (no table/view privileges for public/anon/authenticated).
-- Access should happen via controlled RPC/API only.

-- ------------------------------------------------------------
-- 1) member_pins
-- ------------------------------------------------------------
alter table if exists public.member_pins enable row level security;

drop policy if exists member_pins_select_all on public.member_pins;
drop policy if exists member_pins_insert_all on public.member_pins;
drop policy if exists member_pins_update_all on public.member_pins;
drop policy if exists member_pins_delete_all on public.member_pins;

revoke all on table public.member_pins from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.member_pins from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.member_pins from authenticated';
  end if;
end
$$;

-- ------------------------------------------------------------
-- 2) storno_log
-- ------------------------------------------------------------
alter table if exists public.storno_log enable row level security;

drop policy if exists storno_log_select_all on public.storno_log;
drop policy if exists storno_log_insert_all on public.storno_log;
drop policy if exists storno_log_update_all on public.storno_log;
drop policy if exists storno_log_delete_all on public.storno_log;

revoke all on table public.storno_log from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.storno_log from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.storno_log from authenticated';
  end if;
end
$$;

-- ------------------------------------------------------------
-- 3) stock_overview view
-- ------------------------------------------------------------
revoke all on table public.stock_overview from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.stock_overview from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.stock_overview from authenticated';
  end if;
end
$$;
