-- Store product images in Supabase Storage and keep only path/version metadata in DB.

alter table public.products
  add column if not exists product_image_path text null,
  add column if not exists product_image_version bigint null;

notify pgrst, 'reload schema';
