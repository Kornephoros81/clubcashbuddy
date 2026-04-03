const REVENUE_TRANSACTION_TYPES = new Set(["sale_product", "sale_free_amount"]);
const HEAT_WEEKDAY_ORDER = [1, 2, 3, 4, 5, 6, 0];

function normalizeRevenueRow(row) {
  return {
    event_type: row?.event_type === "cancellation" ? "cancellation" : "booking",
    transaction_type:
      row?.transaction_type
      ?? (Number(row?.amount ?? 0) > 0
        ? "credit_adjustment"
        : row?.product_id
          ? "sale_product"
          : "sale_free_amount"),
    event_at: row?.event_at ?? null,
    local_day: row?.local_day ?? null,
    transaction_created_at: row?.transaction_created_at ?? row?.event_at ?? null,
    member_id: row?.member_id ?? null,
    member_name: row?.member_name ?? "Unbekanntes Mitglied",
    product_id: row?.product_id ?? null,
    product_name: row?.product_name ?? "Unbekanntes Produkt",
    product_category: row?.product_category ?? "Unbekannt",
    amount: Number(row?.amount ?? 0),
    amount_abs: Number(row?.amount_abs ?? Math.abs(Number(row?.amount ?? 0))),
    is_free_amount: Boolean(row?.is_free_amount),
    note: row?.note ?? null,
  };
}

function localDateKey(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function normalizeDateKey(value) {
  return typeof value === "string" ? value.slice(0, 10) : "";
}

function listDateKeysInRange(start, end) {
  const current = new Date(start);
  current.setHours(0, 0, 0, 0);
  const last = new Date(end);
  last.setHours(0, 0, 0, 0);

  const keys = [];
  while (current.getTime() <= last.getTime()) {
    keys.push(localDateKey(current));
    current.setDate(current.getDate() + 1);
  }
  return keys;
}

function mean(values) {
  if (!values.length) return 0;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function quantileSorted(sorted, q) {
  if (!sorted.length) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * q) - 1));
  return sorted[idx] ?? 0;
}

function medianSorted(sorted) {
  if (!sorted.length) return 0;
  const mid = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 1) return sorted[mid] ?? 0;
  return ((sorted[mid - 1] ?? 0) + (sorted[mid] ?? 0)) / 2;
}

function trimmedMean(values, outlierFactor = 4) {
  if (!values.length) return 0;
  const baseMean = mean(values);
  const positive = values.filter((value) => value > 0);
  if (positive.length < 6) return baseMean;

  const sortedPos = [...positive].sort((a, b) => a - b);
  const q1 = quantileSorted(sortedPos, 0.25);
  const q3 = quantileSorted(sortedPos, 0.75);
  const iqr = q3 - q1;
  const medianPos = medianSorted(sortedPos);
  const threshold = iqr > 0 ? q3 + 3 * iqr : medianPos * outlierFactor;
  if (!Number.isFinite(threshold) || threshold <= 0) return baseMean;

  const hasOutlier = positive.some((value) => value > threshold);
  if (!hasOutlier) return baseMean;

  const filtered = values.filter((value) => value === 0 || value <= threshold);
  return filtered.length ? mean(filtered) : baseMean;
}

function maxValue(values) {
  return values.length ? Math.max(...values) : 0;
}

function aggregateHeatValues(values, mode) {
  if (mode === "max") return maxValue(values);
  if (mode === "mean") return mean(values);
  return trimmedMean(values);
}

function filterRows(rows, filters) {
  const memberId = String(filters?.member_id ?? "").trim();
  const category = String(filters?.category ?? "").trim();
  const transactionType = String(filters?.transaction_type ?? "").trim();

  return rows.filter((row) => {
    const memberOk = !memberId || row.member_id === memberId;
    const categoryOk = !category || row.product_category === category;
    const typeOk = !transactionType
      || (transactionType === "revenue"
        ? REVENUE_TRANSACTION_TYPES.has(row.transaction_type)
        : transactionType === "non_revenue"
          ? !REVENUE_TRANSACTION_TYPES.has(row.transaction_type)
          : row.transaction_type === transactionType);
    return memberOk && categoryOk && typeOk;
  });
}

function buildHeatData(rows, start, end, mode) {
  const dateKeys = listDateKeysInRange(start, end);
  const weekdayDates = new Map();

  for (const dateKey of dateKeys) {
    const day = new Date(`${dateKey}T12:00:00`).getDay();
    const list = weekdayDates.get(day) ?? [];
    list.push(dateKey);
    weekdayDates.set(day, list);
  }

  const dateHourCounts = new Map();
  for (const row of rows) {
    const dt = new Date(row.event_at);
    const hour = dt.getHours();
    const dateKey = normalizeDateKey(row.local_day) || localDateKey(dt);
    const key = `${dateKey}-${hour}`;
    dateHourCounts.set(key, (dateHourCounts.get(key) ?? 0) + 1);
  }

  const activityHeat = [];
  for (let day = 0; day <= 6; day += 1) {
    const dayDates = weekdayDates.get(day) ?? [];
    for (let hour = 0; hour < 24; hour += 1) {
      const rawValues = dayDates.map((dateKey) => dateHourCounts.get(`${dateKey}-${hour}`) ?? 0);
      activityHeat.push({
        wochentag: day,
        stunde: hour,
        anzahl_tx: aggregateHeatValues(rawValues, mode),
      });
    }
  }

  const lookup = new Map();
  for (const row of activityHeat) {
    lookup.set(`${row.wochentag}-${row.stunde}`, Number(row.anzahl_tx ?? 0));
  }

  const heatGrid = HEAT_WEEKDAY_ORDER.map((day) => ({
    day,
    label: ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][day] ?? "-",
    cells: Array.from({ length: 24 }).map((_, hour) => ({
      day,
      hour,
      count: lookup.get(`${day}-${hour}`) ?? 0,
    })),
  }));

  const peakHour = activityHeat.length
    ? [...activityHeat].sort((a, b) => b.anzahl_tx - a.anzahl_tx)[0]
    : null;

  const weekdayTotals = new Map();
  for (const row of activityHeat) {
    weekdayTotals.set(row.wochentag, (weekdayTotals.get(row.wochentag) ?? 0) + Number(row.anzahl_tx ?? 0));
  }
  const peakWeekdayEntry = [...weekdayTotals.entries()].sort((a, b) => b[1] - a[1])[0] ?? null;
  const peakWeekday = peakWeekdayEntry
    ? { day: peakWeekdayEntry[0], count: peakWeekdayEntry[1] }
    : null;

  return { activityHeat, heatGrid, peakHour, peakWeekday };
}

export function buildRevenueReportPayload(rawRows, options = {}) {
  const start = new Date(options.start);
  const end = new Date(options.end);
  const heatAggregationMode = options.heatAggregationMode === "max"
    ? "max"
    : options.heatAggregationMode === "mean"
      ? "mean"
      : "trimmed_mean";
  const recentEventsLimit = Math.max(1, Math.min(500, Number(options.recentEventsLimit ?? 100)));

  const rows = (Array.isArray(rawRows) ? rawRows : []).map(normalizeRevenueRow);
  const filteredRows = filterRows(rows, options.filters);

  const bookingRows = filteredRows.filter((row) => row.event_type === "booking");
  const cancellationRows = filteredRows.filter((row) => row.event_type === "cancellation");
  const revenueBookingRows = bookingRows.filter((row) => REVENUE_TRANSACTION_TYPES.has(row.transaction_type));
  const revenueCancellationRows = cancellationRows.filter((row) => REVENUE_TRANSACTION_TYPES.has(row.transaction_type));
  const nonRevenueBookings = bookingRows.filter((row) => !REVENUE_TRANSACTION_TYPES.has(row.transaction_type));
  const nonRevenueCancellations = cancellationRows.filter((row) => !REVENUE_TRANSACTION_TYPES.has(row.transaction_type));

  const revenueCents = revenueBookingRows.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0);
  const canceledCents = revenueCancellationRows.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0);
  const bookingCount = revenueBookingRows.length;
  const cancellationCount = revenueCancellationRows.length;
  const avgTicketCents = bookingCount > 0 ? Math.round(revenueCents / bookingCount) : 0;

  const activeMemberIds = new Set();
  for (const row of revenueBookingRows) {
    if (row.member_id) activeMemberIds.add(row.member_id);
  }
  const activeMembers = activeMemberIds.size;
  const revenuePerMemberCents = activeMembers > 0 ? Math.round(revenueCents / activeMembers) : 0;
  const stornoRateAmount = revenueCents > 0 ? (canceledCents / revenueCents) * 100 : 0;
  const stornoRateCount = bookingCount > 0 ? (cancellationCount / bookingCount) * 100 : 0;

  const freeAmountRows = revenueBookingRows.filter((row) => row.transaction_type === "sale_free_amount");
  const freeAmountCents = freeAmountRows.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0);
  const freeAmountSummary = {
    count: freeAmountRows.length,
    cents: freeAmountCents,
    share: revenueCents > 0 ? (freeAmountCents / revenueCents) * 100 : 0,
  };

  const nonRevenueSummary = {
    count: nonRevenueBookings.length,
    cents: nonRevenueBookings.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0),
    canceledCount: nonRevenueCancellations.length,
    canceledCents: nonRevenueCancellations.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0),
  };

  const dailyMap = new Map();
  for (const row of revenueBookingRows) {
    const current = dailyMap.get(row.local_day) ?? { day: row.local_day, revenue: 0, canceled: 0 };
    current.revenue += Number(row.amount_abs ?? 0);
    dailyMap.set(row.local_day, current);
  }
  for (const row of revenueCancellationRows) {
    const current = dailyMap.get(row.local_day) ?? { day: row.local_day, revenue: 0, canceled: 0 };
    current.canceled += Number(row.amount_abs ?? 0);
    dailyMap.set(row.local_day, current);
  }
  const dailySummary = [...dailyMap.values()].sort((a, b) => String(a.day).localeCompare(String(b.day)));

  const categoryMap = new Map();
  for (const row of revenueBookingRows) {
    const key = row.product_category || "Unbekannt";
    const current = categoryMap.get(key) ?? { category: key, revenue: 0, canceled: 0 };
    current.revenue += Number(row.amount_abs ?? 0);
    categoryMap.set(key, current);
  }
  for (const row of revenueCancellationRows) {
    const key = row.product_category || "Unbekannt";
    const current = categoryMap.get(key) ?? { category: key, revenue: 0, canceled: 0 };
    current.canceled += Number(row.amount_abs ?? 0);
    categoryMap.set(key, current);
  }
  const categorySummary = [...categoryMap.values()].sort((a, b) => b.revenue - a.revenue);

  const productMap = new Map();
  for (const row of revenueBookingRows) {
    const key = row.product_id ?? `free:${row.note ?? row.product_name}`;
    const current = productMap.get(key) ?? {
      product_key: key,
      product_name: row.product_name || "Unbekannt",
      product_category: row.product_category || "Unbekannt",
      bookings: 0,
      cancellations: 0,
      net_quantity: 0,
      revenue: 0,
      canceled: 0,
    };
    current.bookings += 1;
    current.net_quantity += 1;
    current.revenue += Number(row.amount_abs ?? 0);
    productMap.set(key, current);
  }
  for (const row of revenueCancellationRows) {
    const key = row.product_id ?? `free:${row.note ?? row.product_name}`;
    const current = productMap.get(key) ?? {
      product_key: key,
      product_name: row.product_name || "Unbekannt",
      product_category: row.product_category || "Unbekannt",
      bookings: 0,
      cancellations: 0,
      net_quantity: 0,
      revenue: 0,
      canceled: 0,
    };
    current.cancellations += 1;
    current.net_quantity -= 1;
    current.canceled += Number(row.amount_abs ?? 0);
    productMap.set(key, current);
  }
  const productSummary = [...productMap.values()].sort((a, b) =>
    b.net_quantity - a.net_quantity
    || (b.revenue - b.canceled) - (a.revenue - a.canceled)
    || b.revenue - a.revenue,
  );

  const recentEvents = [...filteredRows]
    .sort((a, b) => new Date(b.event_at).getTime() - new Date(a.event_at).getTime())
    .slice(0, recentEventsLimit);

  const memberMap = new Map();
  const categorySet = new Set();
  for (const row of rows) {
    if (row.member_id && !memberMap.has(row.member_id)) {
      memberMap.set(row.member_id, row.member_name);
    }
    categorySet.add(row.product_category || "Unbekannt");
  }

  return {
    metrics: {
      revenueCents,
      canceledCents,
      bookingCount,
      cancellationCount,
      avgTicketCents,
      activeMembers,
      revenuePerMemberCents,
      stornoRateAmount,
      stornoRateCount,
      freeAmountSummary,
      nonRevenueSummary,
    },
    dailySummary,
    categorySummary,
    productSummary,
    topProducts: productSummary.slice(0, 10),
    ...buildHeatData(revenueBookingRows, start, end, heatAggregationMode),
    recentEvents,
    memberOptions: [...memberMap.entries()]
      .map(([id, name]) => ({ id, name }))
      .sort((a, b) => a.name.localeCompare(b.name, "de-DE")),
    categoryOptions: [...categorySet].sort((a, b) => String(a).localeCompare(String(b), "de-DE")),
    totalRowCount: rows.length,
    filteredRowCount: filteredRows.length,
  };
}
