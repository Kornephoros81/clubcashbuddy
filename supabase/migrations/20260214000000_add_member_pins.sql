create table if not exists public.member_pins (
  member_id uuid not null,
  pin_plain text not null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint member_pins_pkey primary key (member_id),
  constraint member_pins_pin_plain_format_chk check (pin_plain ~ '^[A-Za-z0-9]{4}$'),
  constraint member_pins_member_id_fkey foreign key (member_id) references public.members (id) on delete cascade
) TABLESPACE pg_default;

create or replace function public.trg_set_member_pins_updated_at()
returns trigger
language plpgsql
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

drop trigger if exists tg_member_pins_updated_at on public.member_pins;
create trigger tg_member_pins_updated_at
before update on public.member_pins
for each row
execute function public.trg_set_member_pins_updated_at();
