-- Lock down new internal tables: direct access forbidden, function-only access.

alter table public.app_branding_settings enable row level security;
alter table public.device_pairing_codes enable row level security;

revoke all on table public.app_branding_settings from public;
revoke all on table public.device_pairing_codes from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.app_branding_settings from anon';
    execute 'revoke all on table public.device_pairing_codes from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.app_branding_settings from authenticated';
    execute 'revoke all on table public.device_pairing_codes from authenticated';
  end if;
end
$$;
