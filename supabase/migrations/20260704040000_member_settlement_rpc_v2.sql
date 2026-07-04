-- Use a uniquely named wrapper for single-member settlement to avoid
-- PostgREST schema-cache ambiguity around the previous two-argument RPC.

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

revoke all on function public.api_admin_perform_member_settlement_v2(text, uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_perform_member_settlement_v2(text, uuid) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';
