-- DB performance quick wins:
-- - add indexes for frequent filters/lookups
-- - remove redundant unique index on transactions.client_tx_id

-- Fast path for open transactions per member (API + admin checks).
create index if not exists tx_member_open_created_idx
  on public.transactions (member_id, created_at desc)
  where settled_at is null;

-- Speed up inventory adjustment report filters by reason + time range.
create index if not exists im_reason_created_idx
  on public.inventory_movements (reason, created_at desc);

-- Speed up fridge refill report (positive adjustments in time range).
create index if not exists sa_created_positive_idx
  on public.stock_adjustments (created_at desc)
  where quantity > 0;

-- Case-insensitive login/device lookups use lower(...).
create index if not exists app_users_username_lower_idx
  on public.app_users (lower(username));

create index if not exists kiosk_devices_name_lower_idx
  on public.kiosk_devices (lower(name));

-- Keep only one uniqueness structure for client_tx_id.
drop index if exists public.ux_tx_client;

notify pgrst, 'reload schema';
