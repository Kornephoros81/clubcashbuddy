create or replace function public.assert_admin()
returns void
language plpgsql
security definer
as $function$
begin
  if auth.uid() is null then
    -- Allow trusted backend calls that run with service role key.
    if coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role' then
      return;
    end if;
    raise exception 'Unauthorized';
  end if;

  if not exists (
    select 1
    from public.admins a
    where a.user_id = auth.uid()
  ) then
    raise exception 'Forbidden';
  end if;
end;
$function$;

revoke all on function public.assert_admin() from public;
grant execute on function public.assert_admin() to authenticated;
