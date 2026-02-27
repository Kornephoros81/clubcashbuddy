-- Store product images directly in DB (data URL) to avoid storage dependency.

alter table public.products
  add column if not exists product_image_data_url text null;

notify pgrst, 'reload schema';
