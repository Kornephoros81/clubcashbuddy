drop function if exists public.book_transaction(uuid, integer, uuid, text, uuid);
drop function if exists public.book_transaction(uuid, uuid, integer, text, uuid);

create or replace function public.book_transaction(
  member_id uuid default null::uuid,
  product_id uuid default null::uuid,
  free_amount integer default null::integer,
  p_note text default null::text,
  client_tx_id_param uuid default null::uuid
)
returns uuid
language plpgsql
security definer
as $function$
declare
  amt integer;
  pid uuid;
  note text;
  txid uuid;
  is_guest boolean;
begin
  select m.is_guest into is_guest
  from public.members m
  where m.id = member_id;

  if product_id is not null then
    select
      case
        when is_guest then p.guest_price
        else p.price
      end
      into amt
    from public.products p
    where p.id = product_id
      and p.active = true;

    if amt is null then
      raise exception 'Produkt nicht gefunden oder inaktiv';
    end if;

    amt := -abs(amt);
    pid := product_id;
    note := null;
  else
    amt := coalesce(free_amount, 0);
    if amt = 0 then
      raise exception 'Betrag fehlt';
    end if;
    note := coalesce(p_note, 'frei');
  end if;

  insert into public.transactions(member_id, product_id, amount, note, client_tx_id)
  values (member_id, pid, amt, note, client_tx_id_param)
  on conflict (client_tx_id)
  where client_tx_id is not null
  do nothing
  returning id into txid;

  if txid is not null and pid is not null then
    update public.products
    set stored = coalesce(stored, 0) - 1
    where id = pid;
  end if;

  if txid is null and client_tx_id_param is not null then
    select t.id into txid
    from public.transactions t
    where t.client_tx_id = client_tx_id_param;
  end if;

  return txid;
end;
$function$;

grant execute on function public.book_transaction(uuid, uuid, integer, text, uuid) to anon, authenticated;
