alter table public.transactions
  drop constraint if exists transactions_transaction_type_chk;

alter table public.transactions
  add constraint transactions_transaction_type_chk
  check (
    transaction_type in (
      'sale_product',
      'sale_free_amount',
      'cash_withdrawal',
      'credit_adjustment',
      'complimentary_product'
    )
  );

alter table public.storno_log
  drop constraint if exists storno_log_transaction_type_chk;

alter table public.storno_log
  add constraint storno_log_transaction_type_chk
  check (
    transaction_type in (
      'sale_product',
      'sale_free_amount',
      'cash_withdrawal',
      'credit_adjustment',
      'complimentary_product'
    )
  );
