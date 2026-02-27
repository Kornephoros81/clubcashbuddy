-- Demo reset script
-- Deletes all business/auth data so demo_seed.sql can be run again from a clean state.

begin;

truncate table
  public.app_sessions,
  public.app_users,
  public.inventory_movements,
  public.kiosk_devices,
  public.member_pins,
  public.members,
  public.members_archive,
  public.products,
  public.products_archive,
  public.settlements,
  public.stock_adjustments,
  public.stock_locations,
  public.storno_log,
  public.transactions
restart identity cascade;

commit;
