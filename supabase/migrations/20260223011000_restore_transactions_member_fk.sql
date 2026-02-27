-- Restore referential integrity for transactions.member_id while preserving history on member delete.
update public.transactions t
set member_id = null
where t.member_id is not null
  and not exists (
    select 1
    from public.members m
    where m.id = t.member_id
  );

alter table public.transactions
  alter column member_id drop not null;

alter table public.transactions
  drop constraint if exists transactions_member_id_fkey;

alter table public.transactions
  add constraint transactions_member_id_fkey
  foreign key (member_id)
  references public.members (id)
  on delete set null;

