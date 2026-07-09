create or replace function public.get_inventory_adjustments_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  value_delta_cents integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language sql
security definer
set search_path = public, extensions, pg_temp
as $function$
  with movement_adjustments as (
    select
      im.created_at,
      (im.created_at at time zone 'Europe/Berlin')::date as local_day,
      im.product_id,
      coalesce(p.name, '[Geloeschtes Produkt]') as product_name,
      coalesce(p.category, 'Unbekannt') as product_category,
      coalesce(p.active, false) as active,
      'warehouse'::text as location,
      (
        case when im.to_location_id is not null then im.quantity else 0 end
        - case when im.from_location_id is not null then im.quantity else 0 end
      )::integer as delta,
      (
        (
          case when im.to_location_id is not null then im.quantity else 0 end
          - case when im.from_location_id is not null then im.quantity else 0 end
        ) * greatest(
          0,
          coalesce(
            nullif(im.purchase_price_snapshot_cents, 0),
            nullif(p.last_purchase_price_cents, 0),
            nullif(latest_lot.unit_cost_cents, 0),
            0
          )
        )
      )::integer as value_delta_cents,
      case
        when (
          case when im.to_location_id is not null then im.quantity else 0 end
          - case when im.from_location_id is not null then im.quantity else 0 end
        ) < 0 then 'fehlbestand'
        when (
          case when im.to_location_id is not null then im.quantity else 0 end
          - case when im.from_location_id is not null then im.quantity else 0 end
        ) > 0 then 'ueberbestand'
        else 'neutral'
      end as adjustment_kind,
      im.reason,
      im.note,
      coalesce(im.meta->>'source', 'unknown') as source
    from public.inventory_movements im
    left join public.products p on p.id = im.product_id
    left join lateral (
      select l.unit_cost_cents
      from public.product_purchase_lots l
      where l.product_id = im.product_id
        and l.source_reason <> 'sale_fallback'
      order by l.created_at desc, l.id desc
      limit 1
    ) latest_lot on true
    where im.created_at >= p_start
      and im.created_at < p_end
      and im.reason in ('count_adjustment', 'shrinkage', 'waste')
      and coalesce(im.meta->>'source', '') <> 'purchase_lot_remaining_cancel'
  ), open_fallback_sales as (
    select
      a.created_at,
      (a.created_at at time zone 'Europe/Berlin')::date as local_day,
      a.product_id,
      coalesce(p.name, '[Geloeschtes Produkt]') as product_name,
      coalesce(p.category, 'Unbekannt') as product_category,
      coalesce(p.active, false) as active,
      'warehouse'::text as location,
      (-a.quantity)::integer as delta,
      (-a.quantity * greatest(
        0,
        coalesce(
          nullif(a.unit_cost_cents, 0),
          nullif(l.unit_cost_cents, 0),
          nullif(p.last_purchase_price_cents, 0),
          0
        )
      ))::integer as value_delta_cents,
      'fehlbestand'::text as adjustment_kind,
      'sale_fallback'::text as reason,
      coalesce(l.note, 'Verkauf ohne gedecktes Lot') as note,
      'fallback_lot'::text as source
    from public.product_lot_allocations a
    join public.product_purchase_lots l on l.id = a.purchase_lot_id
    left join public.products p on p.id = a.product_id
    where a.created_at >= p_start
      and a.created_at < p_end
      and a.reason = 'sale'
      and a.reversed_at is null
      and l.source_reason = 'sale_fallback'
  )
  select * from movement_adjustments
  union all
  select * from open_fallback_sales
  order by created_at desc;
$function$;

notify pgrst, 'reload schema';
