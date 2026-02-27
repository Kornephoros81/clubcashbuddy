create table if not exists public.storno_log (
  id uuid not null default gen_random_uuid(),
  original_transaction_id uuid not null,
  member_id uuid null,
  product_id uuid null,
  transaction_created_at timestamp with time zone not null,
  canceled_at timestamp with time zone not null default now(),
  amount integer null,
  note text null,
  constraint storno_log_pkey primary key (id),
  constraint storno_log_member_id_fkey foreign key (member_id) references public.members (id) on delete set null,
  constraint storno_log_product_id_fkey foreign key (product_id) references public.products (id) on delete set null
) TABLESPACE pg_default;

create index if not exists storno_log_canceled_at_idx
  on public.storno_log using btree (canceled_at desc) TABLESPACE pg_default;

create index if not exists storno_log_member_id_idx
  on public.storno_log using btree (member_id) TABLESPACE pg_default;

create or replace function public.cancel_transaction(
  cancel_tx_id uuid default null::uuid,
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  note text default null::text
)
returns uuid
language plpgsql
security definer
as $function$
declare
  v_tx record;
  v_cancel_id uuid;
  v_member_active boolean;
  v_canceled_at timestamp with time zone;
begin
  if cancel_tx_id is not null then
    select * into v_tx
    from public.transactions t
    where t.id = cancel_tx_id;
  elsif member_id is not null
    and product_id is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id = cancel_transaction.product_id
    order by t.created_at desc
    limit 1;
  elsif member_id is not null
    and note is not null then
    select * into v_tx
    from public.transactions t
    where t.member_id = cancel_transaction.member_id
      and t.product_id is null
      and t.note = cancel_transaction.note
    order by t.created_at desc
    limit 1;
  else
    raise exception 'Ungueltige Storno-Parameter: cancel_tx_id oder (member_id + product_id/note) erforderlich';
  end if;

  if not found then
    raise exception 'Keine passende Buchung gefunden';
  end if;

  if v_tx.settled_at is not null then
    raise exception 'Nur nicht abgerechnete Buchungen duerfen storniert werden';
  end if;

  select m.active into v_member_active
  from public.members m
  where m.id = v_tx.member_id;

  if coalesce(v_member_active, false) = false then
    raise exception 'Buchungen von inaktiven Mitgliedern duerfen nicht storniert werden';
  end if;

  update public.members m
  set balance = m.balance - v_tx.amount
  where m.id = v_tx.member_id;

  v_canceled_at := now();

  delete from public.transactions t
  where t.id = v_tx.id
  returning t.id into v_cancel_id;

  if v_cancel_id is null then
    raise exception 'Storno fehlgeschlagen';
  end if;

  insert into public.storno_log (
    original_transaction_id,
    member_id,
    product_id,
    transaction_created_at,
    canceled_at,
    amount,
    note
  ) values (
    v_tx.id,
    v_tx.member_id,
    v_tx.product_id,
    v_tx.created_at,
    v_canceled_at,
    v_tx.amount,
    v_tx.note
  );

  if v_tx.product_id is not null then
    update public.products
    set stored = coalesce(stored, 0) + 1
    where id = v_tx.product_id;
  end if;

  return v_cancel_id;
end;
$function$;
