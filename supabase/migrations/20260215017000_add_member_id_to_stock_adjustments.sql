-- Track who performed a refill on stock_adjustments.
alter table public.stock_adjustments
  add column if not exists member_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'stock_adjustments_member_id_fkey'
      and conrelid = 'public.stock_adjustments'::regclass
  ) then
    alter table public.stock_adjustments
      add constraint stock_adjustments_member_id_fkey
      foreign key (member_id) references public.members(id);
  end if;
end
$$;

create index if not exists stock_adjustments_member_id_idx
  on public.stock_adjustments(member_id);
