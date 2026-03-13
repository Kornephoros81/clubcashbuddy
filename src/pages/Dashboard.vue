<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRouter } from "vue-router";
import Datepicker from "@vuepic/vue-datepicker";
import "@vuepic/vue-datepicker/dist/main.css";
import { adminRpc } from "@/lib/adminApi";
import { fmt } from "@/utils/currency";

type RevenueEventRow = {
  event_type: "booking" | "cancellation";
  transaction_type: "sale_product" | "sale_free_amount" | "cash_withdrawal" | "credit_adjustment";
  event_at: string;
  local_day: string;
  member_id: string | null;
  member_name: string;
  product_id: string | null;
  product_name: string;
  product_category: string;
  amount_abs: number;
  is_free_amount: boolean;
  note?: string | null;
};

type HeatRow = {
  wochentag: number;
  stunde: number;
  anzahl_tx: number;
};

const loading = ref(true);
const error = ref<string | null>(null);
const preset = ref("30d");
const router = useRouter();

const today = new Date();
const thirtyDaysAgo = new Date();
thirtyDaysAgo.setDate(today.getDate() - 30);
const startDate = ref<Date>(thirtyDaysAgo);
const endDate = ref<Date>(today);

const revenueRows = ref<RevenueEventRow[]>([]);
const suppressDateReload = ref(false);
type HeatAggregationMode = "trimmed_mean" | "mean" | "max";
const heatAggregationMode = ref<HeatAggregationMode>("trimmed_mean");
const heatAggregationOptions: Array<{ value: HeatAggregationMode; label: string }> = [
  { value: "trimmed_mean", label: "Bereinigt" },
  { value: "mean", label: "Durchschnitt" },
  { value: "max", label: "Max" },
];
const minTrimmedDays = 35;
const canUseTrimmedAggregation = computed(() => {
  if (!startDate.value || !endDate.value) return false;
  const start = new Date(startDate.value);
  const end = new Date(endDate.value);
  start.setHours(0, 0, 0, 0);
  end.setHours(0, 0, 0, 0);
  const diffDays = Math.floor((end.getTime() - start.getTime()) / 86400000) + 1;
  return diffDays >= minTrimmedDays;
});
const heatAggregationModeEffective = computed<HeatAggregationMode>(() => {
  if (heatAggregationMode.value === "trimmed_mean" && !canUseTrimmedAggregation.value) {
    return "mean";
  }
  return heatAggregationMode.value;
});
const heatAggregationOptionsVisible = computed(() =>
  heatAggregationOptions.filter((opt) =>
    opt.value === "trimmed_mean" ? canUseTrimmedAggregation.value : true),
);

const trendCanvas = ref<HTMLCanvasElement | null>(null);
const categoryCanvas = ref<HTMLCanvasElement | null>(null);

let Chart: any = null;
let trendChart: any = null;
let categoryChart: any = null;

function destroyCharts() {
  trendChart?.destroy?.();
  categoryChart?.destroy?.();
  trendChart = null;
  categoryChart = null;
}

async function initChartJS() {
  if (!Chart) {
    const mod = await import("chart.js/auto");
    Chart = mod.default;
  }
}

function getLocalDayRange(date: Date, isEnd = false) {
  const d = new Date(date);
  if (!isEnd) d.setHours(0, 0, 0, 0);
  else d.setHours(23, 59, 59, 999);
  return d.toISOString();
}

function applyPreset(value: string) {
  const now = new Date();
  const s = new Date(now);

  switch (value) {
    case "day":
      s.setHours(0, 0, 0, 0);
      startDate.value = s;
      endDate.value = now;
      break;
    case "7d":
      s.setDate(s.getDate() - 7);
      startDate.value = s;
      endDate.value = now;
      break;
    case "30d":
      s.setDate(s.getDate() - 30);
      startDate.value = s;
      endDate.value = now;
      break;
    case "month":
      s.setDate(1);
      s.setHours(0, 0, 0, 0);
      startDate.value = s;
      endDate.value = now;
      break;
    case "year":
      s.setMonth(0, 1);
      s.setHours(0, 0, 0, 0);
      startDate.value = s;
      endDate.value = now;
      break;
    default:
      break;
  }
}

function onPresetChange() {
  if (preset.value !== "custom") {
    suppressDateReload.value = true;
    applyPreset(preset.value);
    suppressDateReload.value = false;
    loadData();
  }
}

const activityHeat = computed<HeatRow[]>(() => {
  if (!startDate.value || !endDate.value) return [];

  const dateKeys = listDateKeysInRange(startDate.value, endDate.value);
  if (!dateKeys.length) return [];

  const weekdayDates = new Map<number, string[]>();
  for (const dateKey of dateKeys) {
    const day = new Date(`${dateKey}T12:00:00`).getDay();
    const list = weekdayDates.get(day) ?? [];
    list.push(dateKey);
    weekdayDates.set(day, list);
  }

  const dateHourCounts = new Map<string, number>();
  for (const row of revenueBookingRows.value) {
    const dt = new Date(row.event_at);
    const hour = dt.getHours();
    const dateKey = normalizeDateKey(row.local_day) || localDateKey(dt);
    const key = `${dateKey}-${hour}`;
    dateHourCounts.set(key, (dateHourCounts.get(key) ?? 0) + 1);
  }

  const result: HeatRow[] = [];
  for (let day = 0; day <= 6; day += 1) {
    const dayDates = weekdayDates.get(day) ?? [];
    for (let hour = 0; hour < 24; hour += 1) {
      const rawValues = dayDates.map((dateKey) => dateHourCounts.get(`${dateKey}-${hour}`) ?? 0);
      result.push({
        wochentag: day,
        stunde: hour,
        anzahl_tx: aggregateHeatValues(rawValues, heatAggregationModeEffective.value),
      });
    }
  }
  return result;
});

function formatDayKey(day: string) {
  const [y, m, d] = day.split("-");
  if (!y || !m || !d) return day;
  return `${d}.${m}.${y}`;
}

const bookingRows = computed(() => revenueRows.value.filter((r) => r.event_type === "booking"));
const cancellationRows = computed(() =>
  revenueRows.value.filter((r) => r.event_type === "cancellation"),
);
const revenueTransactionTypes = new Set(["sale_product", "sale_free_amount"]);
const revenueBookingRows = computed(() =>
  bookingRows.value.filter((r) => revenueTransactionTypes.has(r.transaction_type)),
);
const revenueCancellationRows = computed(() =>
  cancellationRows.value.filter((r) => revenueTransactionTypes.has(r.transaction_type)),
);
const nonRevenueBookings = computed(() =>
  bookingRows.value.filter((r) => !revenueTransactionTypes.has(r.transaction_type)),
);
const nonRevenueCancellations = computed(() =>
  cancellationRows.value.filter((r) => !revenueTransactionTypes.has(r.transaction_type)),
);

const revenueCents = computed(() =>
  revenueBookingRows.value.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0),
);
const canceledCents = computed(() =>
  revenueCancellationRows.value.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0),
);

const bookingCount = computed(() => revenueBookingRows.value.length);
const cancellationCount = computed(() => revenueCancellationRows.value.length);
const avgTicketCents = computed(() =>
  bookingCount.value > 0 ? Math.round(revenueCents.value / bookingCount.value) : 0,
);

const activeMembers = computed(() => {
  const set = new Set<string>();
  for (const row of revenueBookingRows.value) {
    if (row.member_id) set.add(row.member_id);
  }
  return set.size;
});

const revenuePerMemberCents = computed(() =>
  activeMembers.value > 0 ? Math.round(revenueCents.value / activeMembers.value) : 0,
);

const stornoRateAmount = computed(() =>
  revenueCents.value > 0 ? (canceledCents.value / revenueCents.value) * 100 : 0,
);
const stornoRateCount = computed(() =>
  bookingCount.value > 0 ? (cancellationCount.value / bookingCount.value) * 100 : 0,
);

const freeAmountSummary = computed(() => {
  const rows = revenueBookingRows.value.filter((r) => r.transaction_type === "sale_free_amount");
  const count = rows.length;
  const cents = rows.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0);
  const share = revenueCents.value > 0 ? (cents / revenueCents.value) * 100 : 0;
  return { count, cents, share };
});

const nonRevenueSummary = computed(() => ({
  count: nonRevenueBookings.value.length,
  cents: nonRevenueBookings.value.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0),
  canceledCount: nonRevenueCancellations.value.length,
  canceledCents: nonRevenueCancellations.value.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0),
}));

const dailySummary = computed(() => {
  const map = new Map<string, { day: string; revenue: number; canceled: number }>();
  for (const row of revenueBookingRows.value) {
    const day = row.local_day;
    const rec = map.get(day) ?? { day, revenue: 0, canceled: 0 };
    rec.revenue += Number(row.amount_abs ?? 0);
    map.set(day, rec);
  }
  for (const row of revenueCancellationRows.value) {
    const day = row.local_day;
    const rec = map.get(day) ?? { day, revenue: 0, canceled: 0 };
    rec.canceled += Number(row.amount_abs ?? 0);
    map.set(day, rec);
  }
  return [...map.values()].sort((a, b) => a.day.localeCompare(b.day));
});

const categorySummary = computed(() => {
  const map = new Map<string, { category: string; revenue: number; canceled: number }>();
  for (const row of revenueBookingRows.value) {
    const key = row.product_category || "Unbekannt";
    const rec = map.get(key) ?? { category: key, revenue: 0, canceled: 0 };
    rec.revenue += Number(row.amount_abs ?? 0);
    map.set(key, rec);
  }
  for (const row of revenueCancellationRows.value) {
    const key = row.product_category || "Unbekannt";
    const rec = map.get(key) ?? { category: key, revenue: 0, canceled: 0 };
    rec.canceled += Number(row.amount_abs ?? 0);
    map.set(key, rec);
  }
  return [...map.values()].sort((a, b) => b.revenue - a.revenue);
});

const productSummary = computed(() => {
  const map = new Map<
    string,
    {
      product: string;
      revenue: number;
      canceled: number;
      bookings: number;
      cancellations: number;
      net_quantity: number;
    }
  >();

  for (const row of revenueBookingRows.value) {
    const key = row.product_id ?? `free:${row.note ?? row.product_name}`;
    const rec = map.get(key) ?? {
      product: row.product_name || "Unbekannt",
      revenue: 0,
      canceled: 0,
      bookings: 0,
      cancellations: 0,
      net_quantity: 0,
    };
    rec.revenue += Number(row.amount_abs ?? 0);
    rec.bookings += 1;
    rec.net_quantity += 1;
    map.set(key, rec);
  }

  for (const row of revenueCancellationRows.value) {
    const key = row.product_id ?? `free:${row.note ?? row.product_name}`;
    const rec = map.get(key) ?? {
      product: row.product_name || "Unbekannt",
      revenue: 0,
      canceled: 0,
      bookings: 0,
      cancellations: 0,
      net_quantity: 0,
    };
    rec.canceled += Number(row.amount_abs ?? 0);
    rec.cancellations += 1;
    rec.net_quantity -= 1;
    map.set(key, rec);
  }

  return [...map.values()].sort((a, b) =>
    b.net_quantity - a.net_quantity
    || (b.revenue - b.canceled) - (a.revenue - a.canceled)
    || b.revenue - a.revenue,
  );
});

const topProducts = computed(() => productSummary.value.slice(0, 10));
const topProductMaxAbs = computed(() =>
  Math.max(1, ...topProducts.value.map((p) => Math.abs(Number(p.net_quantity ?? 0)))),
);
const topProductTotalNet = computed(() =>
  topProducts.value.reduce((sum, p) => sum + Math.max(0, Number(p.net_quantity ?? 0)), 0),
);

const heatScaleP95 = computed(() => {
  const values = activityHeat.value
    .map((r) => Number(r.anzahl_tx ?? 0))
    .filter((v) => Number.isFinite(v) && v > 0)
    .sort((a, b) => a - b);

  if (!values.length) return 1;
  const max = values[values.length - 1] ?? 1;
  const idx = Math.max(0, Math.ceil(values.length * 0.95) - 1);
  return Math.max(1, values[idx] ?? max);
});

const weekdayOrder = [1, 2, 3, 4, 5, 6, 0];
const heatGrid = computed(() => {
  const lookup = new Map<string, number>();
  for (const r of activityHeat.value) {
    lookup.set(`${r.wochentag}-${r.stunde}`, Number(r.anzahl_tx ?? 0));
  }
  return weekdayOrder.map((day) => ({
    day,
    label: dayLabel(day),
    cells: Array.from({ length: 24 }).map((_, hour) => ({
      day,
      hour,
      count: lookup.get(`${day}-${hour}`) ?? 0,
    })),
  }));
});

const peakHour = computed(() => {
  if (!activityHeat.value.length) return null;
  return [...activityHeat.value].sort((a, b) => b.anzahl_tx - a.anzahl_tx)[0];
});

const peakWeekday = computed(() => {
  if (!activityHeat.value.length) return null;
  const grouped = new Map<number, number>();
  for (const row of activityHeat.value) {
    grouped.set(row.wochentag, (grouped.get(row.wochentag) ?? 0) + Number(row.anzahl_tx ?? 0));
  }
  const sorted = [...grouped.entries()].sort((a, b) => b[1] - a[1]);
  if (!sorted.length) return null;
  return { day: sorted[0][0], count: sorted[0][1] };
});

function dayLabel(day: number) {
  return ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][day] ?? "-";
}

function euro(cents: number) {
  return fmt(cents / 100);
}

function ratio(value: number, max: number) {
  if (!max || max <= 0) return 0;
  return Math.max(0, Math.min(1, value / max));
}

function localDateKey(date: Date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function normalizeDateKey(value: unknown) {
  if (typeof value !== "string") return "";
  return value.slice(0, 10);
}

function listDateKeysInRange(start: Date, end: Date) {
  const current = new Date(start);
  current.setHours(0, 0, 0, 0);
  const last = new Date(end);
  last.setHours(0, 0, 0, 0);

  const keys: string[] = [];
  while (current.getTime() <= last.getTime()) {
    keys.push(localDateKey(current));
    current.setDate(current.getDate() + 1);
  }
  return keys;
}

function mean(values: number[]) {
  if (!values.length) return 0;
  return values.reduce((sum, v) => sum + v, 0) / values.length;
}

function trimmedMean(values: number[], outlierFactor = 4) {
  if (!values.length) return 0;
  const baseMean = mean(values);
  const positive = values.filter((v) => v > 0);
  if (positive.length < 6) return baseMean;

  const sortedPos = [...positive].sort((a, b) => a - b);
  const q1 = quantileSorted(sortedPos, 0.25);
  const q3 = quantileSorted(sortedPos, 0.75);
  const iqr = q3 - q1;
  const medianPos = medianSorted(sortedPos);
  const threshold = iqr > 0 ? q3 + 3 * iqr : medianPos * outlierFactor;
  if (!Number.isFinite(threshold) || threshold <= 0) return baseMean;

  const hasOutlier = positive.some((v) => v > threshold);
  if (!hasOutlier) return baseMean;

  const filtered = values.filter((v) => v === 0 || v <= threshold);
  if (!filtered.length) return baseMean;
  return mean(filtered);
}

function quantileSorted(sorted: number[], q: number) {
  if (!sorted.length) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * q) - 1));
  return sorted[idx] ?? 0;
}

function medianSorted(sorted: number[]) {
  if (!sorted.length) return 0;
  const mid = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 1) return sorted[mid] ?? 0;
  return ((sorted[mid - 1] ?? 0) + (sorted[mid] ?? 0)) / 2;
}

function maxValue(values: number[]) {
  if (!values.length) return 0;
  return Math.max(...values);
}

function aggregateHeatValues(values: number[], mode: HeatAggregationMode) {
  if (mode === "max") return maxValue(values);
  if (mode === "mean") return mean(values);
  return trimmedMean(values);
}

function heatAggregationLabel(mode: HeatAggregationMode) {
  const match = heatAggregationOptions.find((o) => o.value === mode);
  return match?.label ?? "Ausreißerbereinigt";
}

function fmtHeatValue(value: number) {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

function heatCellStyle(count: number) {
  const r = ratio(count, heatScaleP95.value);
  const cool: [number, number, number] = [229, 231, 235];
  const mid: [number, number, number] = [250, 204, 21];
  const hot: [number, number, number] = [220, 38, 38];
  const t = r <= 0.5 ? r / 0.5 : (r - 0.5) / 0.5;
  const from = r <= 0.5 ? cool : mid;
  const to = r <= 0.5 ? mid : hot;
  const mix = (a: number, b: number) => Math.round(a + (b - a) * t);
  const color = `rgb(${mix(from[0], to[0])}, ${mix(from[1], to[1])}, ${mix(from[2], to[2])})`;
  return {
    backgroundColor: color,
    opacity: count > 0 ? 0.95 : 0.5,
  };
}

function heatCellTitle(day: number, hour: number, count: number) {
  const aggLabel = heatAggregationLabel(heatAggregationModeEffective.value);
  return `${dayLabel(day)}, ${hour
    .toString()
    .padStart(2, "0")}:00 - ${(hour + 1)
    .toString()
    .padStart(2, "0")}:00 | ${aggLabel} ${fmtHeatValue(count)} Buchungen`;
}

function productBarStyle(net: number) {
  const r = ratio(Math.abs(net), topProductMaxAbs.value);
  const width = `${Math.max(3, r * 100)}%`;
  const background =
    net >= 0
      ? "linear-gradient(90deg, rgba(16,185,129,0.95), rgba(34,197,94,0.8))"
      : "linear-gradient(90deg, rgba(244,63,94,0.92), rgba(220,38,38,0.85))";
  return { width, background };
}

function productSharePercent(net: number) {
  const total = Number(topProductTotalNet.value || 0);
  if (total <= 0) return 0;
  return (Math.max(0, net) / total) * 100;
}

function currentRangeQuery() {
  if (!startDate.value || !endDate.value) return { start: "", end: "" };
  const start = getLocalDayRange(startDate.value, false);
  const endISOExclusive = new Date(getLocalDayRange(endDate.value, true));
  endISOExclusive.setMilliseconds(endISOExclusive.getMilliseconds() + 1);
  return { start, end: endISOExclusive.toISOString() };
}

function goToRevenue(extra?: Record<string, string>) {
  router.push({ path: "/admin/revenue-report", query: { ...currentRangeQuery(), ...(extra ?? {}) } });
}

function goToBookings(extra?: Record<string, string>) {
  router.push({ path: "/admin/bookings-report", query: { ...currentRangeQuery(), ...(extra ?? {}) } });
}

function goToCancellations(extra?: Record<string, string>) {
  router.push({
    path: "/admin/cancellations-report",
    query: { ...currentRangeQuery(), ...(extra ?? {}) },
  });
}

async function renderCharts() {
  await nextTick();
  destroyCharts();
  if (!Chart) return;

  if (trendCanvas.value) {
    trendChart = new Chart(trendCanvas.value, {
      type: "line",
      data: {
        labels: dailySummary.value.map((r) => formatDayKey(r.day)),
        datasets: [
          {
            label: "Umsatz",
            data: dailySummary.value.map((r) => r.revenue / 100),
            borderColor: "#2563eb",
            backgroundColor: "rgba(37,99,235,0.15)",
            fill: true,
            tension: 0.2,
          },
          {
            label: "Storno",
            data: dailySummary.value.map((r) => r.canceled / 100),
            borderColor: "#dc2626",
            backgroundColor: "rgba(220,38,38,0.12)",
            fill: true,
            tension: 0.2,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          tooltip: {
            callbacks: {
              label: (ctx: any) => `${ctx.dataset.label}: ${ctx.parsed.y.toFixed(2)} €`,
            },
          },
        },
        scales: {
          y: {
            beginAtZero: true,
            ticks: { callback: (v: any) => `${v} €` },
          },
          x: { grid: { display: false } },
        },
      },
    });
  }

  if (categoryCanvas.value) {
    categoryChart = new Chart(categoryCanvas.value, {
      type: "doughnut",
      data: {
        labels: categorySummary.value.map((r) => r.category),
        datasets: [
          {
            data: categorySummary.value.map((r) => Math.max(r.revenue, 0) / 100),
            backgroundColor: [
              "#1d4ed8",
              "#059669",
              "#d97706",
              "#7c3aed",
              "#dc2626",
              "#0f766e",
              "#4f46e5",
              "#9a3412",
              "#3f6212",
            ],
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { position: "bottom" } },
      },
    });
  }

}

async function loadData() {
  if (!startDate.value || !endDate.value) return;
  loading.value = true;
  error.value = null;
  try {
    const range = currentRangeQuery();
    const pageSize = 1000;
    const maxPages = 200;
    const chunks: any[] = [];
    let offset = 0;

    for (let page = 0; page < maxPages; page += 1) {
      const revenue = await adminRpc("get_revenue_report_period", {
        start: range.start,
        end: range.end,
        limit: pageSize,
        offset,
      });
      const batch = (revenue as any[]) ?? [];
      chunks.push(...batch);
      if (batch.length < pageSize) break;
      offset += pageSize;
    }

    revenueRows.value = chunks.map((row: any) => ({
      event_type: row.event_type === "cancellation" ? "cancellation" : "booking",
      transaction_type:
        row.transaction_type
        ?? (Number(row.amount ?? 0) > 0
          ? "credit_adjustment"
          : row.product_id
            ? "sale_product"
            : "sale_free_amount"),
      event_at: row.event_at,
      local_day: row.local_day,
      member_id: row.member_id ?? null,
      member_name: row.member_name ?? "Unbekanntes Mitglied",
      product_id: row.product_id ?? null,
      product_name: row.product_name ?? "Unbekannt",
      product_category: row.product_category ?? "Unbekannt",
      amount_abs: Number(row.amount_abs ?? 0),
      is_free_amount: Boolean(row.is_free_amount),
      note: row.note ?? null,
    }));
  } catch (e: any) {
    console.error("[Dashboard]", e);
    error.value = e.message || "Fehler beim Laden der Dashboard-Daten.";
  } finally {
    loading.value = false;
    await renderCharts();
  }
}

onMounted(async () => {
  await initChartJS();
  suppressDateReload.value = true;
  applyPreset(preset.value);
  suppressDateReload.value = false;
  await loadData();
});

watch([startDate, endDate], async () => {
  if (suppressDateReload.value) return;
  if (!startDate.value || !endDate.value) return;
  await loadData();
});

watch(canUseTrimmedAggregation, (enabled) => {
  if (!enabled && heatAggregationMode.value === "trimmed_mean") {
    heatAggregationMode.value = "mean";
  }
});

onBeforeUnmount(destroyCharts);
</script>

<template>
  <div class="p-6 max-w-7xl mx-auto space-y-8">
    <div class="flex flex-wrap items-center justify-between gap-4">
      <h1 class="text-3xl font-bold text-primary">📊 Dashboard</h1>
      <div class="flex flex-wrap items-end gap-3">
        <div>
          <label class="block text-xs text-gray-500 mb-1">Vorauswahl</label>
          <select
            v-model="preset"
            class="border rounded-md px-3 py-2 text-sm bg-white shadow-sm"
            @change="onPresetChange"
          >
            <option value="day">Heute</option>
            <option value="7d">Letzte 7 Tage</option>
            <option value="30d">Letzte 30 Tage</option>
            <option value="month">Aktueller Monat</option>
            <option value="year">Aktuelles Jahr</option>
            <option value="custom">Benutzerdefiniert</option>
          </select>
        </div>
        <div>
          <label class="block text-xs text-gray-500 mb-1">Von</label>
          <Datepicker
            v-model="startDate"
            :enable-time-picker="false"
            :format="'dd.MM.yyyy'"
            :auto-apply="true"
            :close-on-auto-apply="true"
            :config="{ keepActionRow: true }"
            :action-row="{ showNow: true, nowBtnLabel: 'Heute', showSelect: false, showCancel: false }"
          />
        </div>
        <div>
          <label class="block text-xs text-gray-500 mb-1">Bis</label>
          <Datepicker
            v-model="endDate"
            :enable-time-picker="false"
            :format="'dd.MM.yyyy'"
            :auto-apply="true"
            :close-on-auto-apply="true"
            :config="{ keepActionRow: true }"
            :action-row="{ showNow: true, nowBtnLabel: 'Heute', showSelect: false, showCancel: false }"
          />
        </div>
        <div v-if="loading" class="h-[38px] inline-flex items-center gap-2 text-xs text-gray-500">
          <span class="inline-block h-3.5 w-3.5 rounded-full border-2 border-gray-300 border-t-primary animate-spin"></span>
          Lädt…
        </div>
      </div>
    </div>

    <div v-if="loading" class="text-center text-gray-500 py-8">Lade Daten …</div>
    <div v-else-if="error" class="text-center text-red-500 py-8">{{ error }}</div>

    <div v-else class="space-y-8">
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Umsatz</div>
          <div class="text-2xl font-semibold text-primary">{{ euro(revenueCents) }}</div>
        </button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToCancellations()">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Stornosumme</div>
          <div class="text-2xl font-semibold text-red-700">{{ euro(canceledCents) }}</div>
        </button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToCancellations()">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Stornos</div>
          <div class="text-2xl font-semibold text-primary">{{ cancellationCount }}</div>
        </button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Ø Bon</div>
          <div class="text-2xl font-semibold text-primary">{{ euro(avgTicketCents) }}</div>
        </button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToBookings()">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Buchungen</div>
          <div class="text-2xl font-semibold text-primary">{{ bookingCount }}</div>
        </button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToCancellations()">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Stornoquote</div>
          <div class="text-sm text-gray-600">Anzahl: {{ stornoRateCount.toFixed(1) }}%</div>
          <div class="text-xl font-semibold text-primary">
            Betrag: {{ stornoRateAmount.toFixed(1) }}%
          </div>
        </button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Aktive Käufer</div>
          <div class="text-2xl font-semibold text-primary">{{ activeMembers }}</div>
        </button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Umsatz pro Mitglied</div>
          <div class="text-2xl font-semibold text-primary">{{ euro(revenuePerMemberCents) }}</div>
        </button>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue({ free_only: '1' })">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Freie Beträge</div>
          <div class="text-sm text-gray-600">{{ freeAmountSummary.count }} Buchungen</div>
          <div class="text-xl font-semibold text-primary">{{ euro(freeAmountSummary.cents) }}</div>
          <div class="text-xs text-gray-500">{{ freeAmountSummary.share.toFixed(1) }}% vom Umsatz</div>
        </button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()">
          <span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span>
          <div class="text-xs uppercase text-gray-500">Nicht umsatzrelevant</div>
          <div class="text-sm text-gray-600">{{ nonRevenueSummary.count }} Buchungen · {{ nonRevenueSummary.canceledCount }} Stornos</div>
          <div class="text-xl font-semibold text-amber-700">{{ euro(nonRevenueSummary.cents) }}</div>
          <div class="text-xs text-gray-500">Storno: {{ euro(nonRevenueSummary.canceledCents) }}</div>
        </button>
        <div class="bg-white rounded-xl border border-gray-200 p-4">
          <div class="text-xs uppercase text-gray-500">Peak-Stunde</div>
          <div class="text-2xl font-semibold text-primary">
            {{ peakHour ? `${peakHour.stunde}:00` : "-" }}
          </div>
          <div class="text-xs text-gray-500">
            {{ peakHour ? `${heatAggregationLabel(heatAggregationModeEffective)} ${fmtHeatValue(peakHour.anzahl_tx)} Buchungen` : "Keine Daten" }}
          </div>
        </div>
        <div class="bg-white rounded-xl border border-gray-200 p-4">
          <div class="text-xs uppercase text-gray-500">Peak-Wochentag</div>
          <div class="text-2xl font-semibold text-primary">
            {{ peakWeekday ? dayLabel(peakWeekday.day) : "-" }}
          </div>
          <div class="text-xs text-gray-500">
            {{ peakWeekday ? `${heatAggregationLabel(heatAggregationModeEffective)} ${fmtHeatValue(peakWeekday.count)} Buchungen` : "Keine Daten" }}
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <div class="bg-white p-6 rounded-2xl shadow border border-gray-200 h-[360px]">
          <h2 class="text-lg font-semibold mb-2">📈 Umsatztrend (Umsatz/Storno)</h2>
          <canvas ref="trendCanvas" class="h-[290px]"></canvas>
        </div>
        <div class="bg-white p-6 rounded-2xl shadow border border-gray-200 h-[360px]">
          <h2 class="text-lg font-semibold mb-2">🧩 Kategorien-Anteil (Umsatz)</h2>
          <canvas ref="categoryCanvas" class="h-[290px]"></canvas>
        </div>
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <div class="bg-white p-6 rounded-2xl shadow border border-gray-200">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold">🥇 Top-Produkte nach Netto-Menge</h2>
            <button
              class="text-xs px-2 py-1 rounded border border-emerald-200 text-emerald-700 hover:bg-emerald-50"
              @click="goToRevenue()"
            >
              Details
            </button>
          </div>
          <div class="space-y-3">
            <div
              v-for="(row, idx) in topProducts"
              :key="row.product"
              class="rounded-xl border border-gray-200 p-3 bg-gradient-to-r from-white to-gray-50/80"
            >
              <div class="flex items-center justify-between gap-3 mb-2">
                <div class="flex items-center gap-2 min-w-0">
                  <span class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-primary/10 text-primary text-xs font-semibold">
                    {{ idx + 1 }}
                  </span>
                  <span class="font-medium text-gray-800 truncate">{{ row.product }}</span>
                </div>
                <div
                  class="text-sm font-semibold whitespace-nowrap"
                  :class="row.net_quantity >= 0 ? 'text-emerald-700' : 'text-rose-700'"
                >
                  {{ row.net_quantity }} netto
                </div>
              </div>
              <div class="h-2.5 rounded-full bg-slate-100 overflow-hidden">
                <div class="h-full rounded-full transition-all duration-500" :style="productBarStyle(row.net_quantity)"></div>
              </div>
              <div class="mt-2 flex items-center justify-between text-xs text-gray-500">
                <span>{{ row.bookings }} Buchungen · {{ row.cancellations }} Stornos · {{ euro(row.revenue - row.canceled) }}</span>
                <span>{{ productSharePercent(row.net_quantity).toFixed(1) }}% Anteil</span>
              </div>
            </div>
            <div v-if="topProducts.length === 0" class="text-sm text-gray-400 italic py-8 text-center">
              Keine Produktdaten im Zeitraum
            </div>
          </div>
        </div>

        <div class="bg-white p-6 rounded-2xl shadow border border-gray-200">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-semibold">🕒 Aktivitäts-Heatmap</h2>
            <div class="flex flex-wrap items-center justify-end gap-2">
              <div class="inline-flex max-w-full rounded-lg border border-gray-200 overflow-hidden">
                <button
                  v-for="opt in heatAggregationOptionsVisible"
                  :key="opt.value"
                  type="button"
                  class="px-2 py-1 text-[11px] transition whitespace-nowrap"
                  :class="[
                    heatAggregationMode === opt.value ? 'bg-primary text-white' : 'bg-white text-gray-600 hover:bg-gray-50',
                    opt.value !== heatAggregationOptionsVisible[0].value ? 'border-l border-gray-200' : '',
                  ]"
                  @click="heatAggregationMode = opt.value"
                >
                  {{ opt.label }}
                </button>
              </div>
              <span class="text-xs text-gray-500">Montag bis Sonntag, 0-23 Uhr</span>
            </div>
          </div>
          <div class="rounded-xl border border-gray-100 p-2">
            <div class="grid grid-cols-[32px_repeat(24,minmax(0,1fr))] gap-0 mb-1">
              <div></div>
              <div
                v-for="hour in 24"
                :key="`hour-${hour - 1}`"
                class="text-[9px] text-center text-gray-400"
              >
                {{ (hour - 1) % 2 === 0 ? (hour - 1).toString().padStart(2, "0") : "" }}
              </div>
            </div>

            <div
              v-for="row in heatGrid"
              :key="`day-${row.day}`"
              class="grid grid-cols-[32px_repeat(24,minmax(0,1fr))] gap-0 mb-[2px] items-center"
            >
              <div class="text-[11px] font-medium text-gray-600">{{ row.label }}</div>
              <div
                v-for="cell in row.cells"
                :key="`cell-${cell.day}-${cell.hour}`"
                class="h-5 sm:h-6 rounded-[2px] transition-colors duration-200"
                :style="heatCellStyle(cell.count)"
                :title="heatCellTitle(cell.day, cell.hour, cell.count)"
              ></div>
            </div>

            <div class="mt-3 flex items-center gap-2">
              <span class="text-[11px] text-gray-500">Wenig</span>
              <div class="h-2.5 flex-1 rounded-full bg-gradient-to-r from-gray-200 via-amber-300 to-red-600"></div>
              <span class="text-[11px] text-gray-500">Viel</span>
            </div>
          </div>
        </div>
      </div>

      <div class="flex flex-wrap gap-3">
        <RouterLink
          to="/admin/revenue-report"
          class="px-4 py-2 rounded-lg bg-primary text-white hover:bg-primary/90 transition"
        >
          Zum Umsatzreport
        </RouterLink>
        <RouterLink
          to="/admin/bookings-report"
          class="px-4 py-2 rounded-lg bg-white border border-gray-300 text-gray-700 hover:bg-gray-50 transition"
        >
          Zur Buchungsübersicht
        </RouterLink>
        <RouterLink
          to="/admin/cancellations-report"
          class="px-4 py-2 rounded-lg bg-white border border-gray-300 text-gray-700 hover:bg-gray-50 transition"
        >
          Zum Storno-Report
        </RouterLink>
      </div>
    </div>
  </div>
</template>
