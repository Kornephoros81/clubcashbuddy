alter table public.product_purchase_lots
  drop constraint if exists product_purchase_lots_corrected_by_fkey;

alter table public.product_purchase_lots
  add constraint product_purchase_lots_corrected_by_fkey
  foreign key (corrected_by) references public.app_users(id);

notify pgrst, 'reload schema';
