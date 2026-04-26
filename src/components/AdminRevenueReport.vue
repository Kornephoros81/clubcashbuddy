<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRoute } from "vue-router";
import Datepicker from "@vuepic/vue-datepicker";
import "@vuepic/vue-datepicker/dist/main.css";
import { adminRpc } from "@/lib/adminApi";
import { fmt } from "@/utils/currency";
import { useToast } from "@/composables/useToast";
import { exportReportAsPdf } from "@/utils/reportExport";

type RevenueEventRow = {
  event_type: "booking" | "cancellation";
  transaction_type: "sale_product" | "sale_free_amount" | "cash_withdrawal" | "credit_adjustment" | "complimentary_product";
  event_at: string;
  local_day: string;
  transaction_created_at: string;
  member_id: string | null;
  member_name: string;
  product_id: string | null;
  product_name: string;
  product_category: string;
  amount: number;
  amount_abs: number;
  is_free_amount: boolean;
  note: string | null;
};

const { show: showToast } = useToast();
const route = useRoute();

const loading = ref(false);
const error = ref<string | null>(null);
const rows = ref<RevenueEventRow[]>([]);
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

const selectedMemberId = ref<string>("");
const selectedCategory = ref<string>("");
const selectedTransactionType = ref<string>("");

const today = new Date();
const sevenDaysAgo = new Date();
sevenDaysAgo.setDate(today.getDate() - 7);
const startDate = ref<Date>(sevenDaysAgo);
const endDate = ref<Date>(today);

const trendCanvas = ref<HTMLCanvasElement | null>(null);
const categoryCanvas = ref<HTMLCanvasElement | null>(null);
const revenuePageSize = 1000;
const revenueMaxPages = 200;

let Chart: any = null;
let trendChart: any = null;
let categoryChart: any = null;

function getLocalDayRange(date: Date, isEnd = false) {
  const d = new Date(date);
  if (!isEnd) d.setHours(0, 0, 0, 0);
  else d.setHours(23, 59, 59, 999);
  return d.toISOString();
}

function formatDayKey(day: string) {
  const [y, m, d] = day.split("-");
  if (!y || !m || !d) return day;
  return `${d}.${m}.${y}`;
}

function queryValue(v: unknown): string | null {
  if (Array.isArray(v)) return v[0] ? String(v[0]) : null;
  if (typeof v === "string" && v.trim()) return v;
  return null;
}

function applyQueryFilters() {
  const qStart = queryValue(route.query.start);
  const qEnd = queryValue(route.query.end);
  const qMember = queryValue(route.query.member_id);
  const qCategory = queryValue(route.query.category);
  const qType = queryValue(route.query.transaction_type);
  const qFreeOnly = queryValue(route.query.free_only);

  if (qStart) {
    const d = new Date(qStart);
    if (!Number.isNaN(d.getTime())) startDate.value = d;
  }
  if (qEnd) {
    const d = new Date(qEnd);
    if (!Number.isNaN(d.getTime())) endDate.value = d;
  }
  if (qMember) selectedMemberId.value = qMember;
  if (qCategory) selectedCategory.value = qCategory;
  if (qType) selectedTransactionType.value = qType;
  if (qFreeOnly === "1") selectedCategory.value = "Freier Betrag";
}

function destroyCharts() {
  trendChart?.destroy?.();
  categoryChart?.destroy?.();
  trendChart = null;
  categoryChart = null;
}

async function initChartJs() {
  if (!Chart) {
    const mod = await import("chart.js/auto");
    Chart = mod.default;
  }
}

const memberOptions = computed(() => {
  const map = new Map<string, string>();
  for (const row of rows.value) {
    if (!row.member_id) continue;
    if (!map.has(row.member_id)) map.set(row.member_id, row.member_name);
  }
  return [...map.entries()]
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name, "de-DE"));
});

const categoryOptions = computed(() => {
  const set = new Set<string>();
  for (const row of rows.value) {
    set.add(row.product_category || "Unbekannt");
  }
  return [...set].sort((a, b) => a.localeCompare(b, "de-DE"));
});

const revenueTransactionTypes = new Set(["sale_product", "sale_free_amount"]);
const transactionTypeOptions = [
  { value: "", label: "Alle" },
  { value: "revenue", label: "Umsatzrelevant" },
  { value: "non_revenue", label: "Nicht umsatzrelevant" },
  { value: "sale_product", label: "Nur Produktverkäufe" },
  { value: "sale_free_amount", label: "Nur freie Verkäufe" },
  { value: "complimentary_product", label: "Nur Freigetränke" },
];

const filteredRows = computed(() =>
  rows.value.filter((row) => {
    const eventAtMs = new Date(row.event_at).getTime();
    const startMs = startDate.value ? new Date(getLocalDayRange(startDate.value, false)).getTime() : Number.NEGATIVE_INFINITY;
    const endExclusiveMs = endDate.value
      ? new Date(getLocalDayRange(endDate.value, true)).getTime() + 1
      : Number.POSITIVE_INFINITY;
    const dateOk = Number.isFinite(eventAtMs) && eventAtMs >= startMs && eventAtMs < endExclusiveMs;
    const memberOk = !selectedMemberId.value || row.member_id === selectedMemberId.value;
    const categoryOk = !selectedCategory.value || row.product_category === selectedCategory.value;
    const typeOk = !selectedTransactionType.value
      || (selectedTransactionType.value === "revenue"
        ? revenueTransactionTypes.has(row.transaction_type)
        : selectedTransactionType.value === "non_revenue"
          ? !revenueTransactionTypes.has(row.transaction_type)
          : row.transaction_type === selectedTransactionType.value);
    return dateOk && memberOk && categoryOk && typeOk;
  }),
);

const bookingRows = computed(() => filteredRows.value.filter((r) => r.event_type === "booking"));
const cancellationRows = computed(() => filteredRows.value.filter((r) => r.event_type === "cancellation"));
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
const stornoRateAmount = computed(() =>
  revenueCents.value > 0 ? (canceledCents.value / revenueCents.value) * 100 : 0,
);
const stornoRateCount = computed(() =>
  bookingCount.value > 0 ? (cancellationCount.value / bookingCount.value) * 100 : 0,
);
const activeMembers = computed(() => {
  const set = new Set<string>();
  for (const row of revenueBookingRows.value) {
    if (row.member_id) set.add(row.member_id);
  }
  return set.size;
});

const freeAmountSummary = computed(() => {
  const rows = revenueBookingRows.value.filter((r) => r.transaction_type === "sale_free_amount");
  const count = rows.length;
  const cents = rows.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0);
  return { count, cents };
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
      product_key: string;
      product_name: string;
      product_category: string;
      bookings: number;
      cancellations: number;
      net_quantity: number;
      revenue: number;
      canceled: number;
    }
  >();

  for (const row of revenueBookingRows.value) {
    const key = row.product_id ?? `free:${row.note ?? "free"}`;
    const rec = map.get(key) ?? {
      product_key: key,
      product_name: row.product_name,
      product_category: row.product_category,
      bookings: 0,
      cancellations: 0,
      net_quantity: 0,
      revenue: 0,
      canceled: 0,
    };
    rec.bookings += 1;
    rec.net_quantity += 1;
    rec.revenue += Number(row.amount_abs ?? 0);
    map.set(key, rec);
  }

  for (const row of revenueCancellationRows.value) {
    const key = row.product_id ?? `free:${row.note ?? "free"}`;
    const rec = map.get(key) ?? {
      product_key: key,
      product_name: row.product_name,
      product_category: row.product_category,
      bookings: 0,
      cancellations: 0,
      net_quantity: 0,
      revenue: 0,
      canceled: 0,
    };
    rec.cancellations += 1;
    rec.net_quantity -= 1;
    rec.canceled += Number(row.amount_abs ?? 0);
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

const activityHeat = computed(() => {
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

  const result: Array<{ wochentag: number; stunde: number; anzahl_tx: number }> = [];
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

const recentEvents = computed(() =>
  [...filteredRows.value].sort(
    (a, b) => new Date(b.event_at).getTime() - new Date(a.event_at).getTime(),
  ).slice(0, 100),
);

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
        scales: {
          y: {
            beginAtZero: true,
            ticks: {
              callback: (v: any) => `${v} €`,
            },
          },
          x: {
            grid: { display: false },
          },
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
        plugins: {
          legend: { position: "bottom" },
        },
      },
    });
  }

}

function formatEuroFromCents(cents: number) {
  return fmt(cents / 100);
}

function dayLabel(day: number) {
  return ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][day] ?? "-";
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

function transactionTypeLabel(v: RevenueEventRow["transaction_type"]) {
  if (v === "complimentary_product") return "Freigetränk";
  if (v === "cash_withdrawal") return "Bar-Entnahme";
  if (v === "credit_adjustment") return "Guthabenbuchung";
  if (v === "sale_free_amount") return "Freier Verkauf";
  return "Produktverkauf";
}

async function loadReport() {
  if (!startDate.value || !endDate.value) {
    showToast("⚠️ Bitte Start- und Enddatum auswählen");
    return;
  }

  loading.value = true;
  error.value = null;
  rows.value = [];

  try {
    const startISO = getLocalDayRange(startDate.value, false);
    const endISOExclusive = new Date(getLocalDayRange(endDate.value, true));
    endISOExclusive.setMilliseconds(endISOExclusive.getMilliseconds() + 1);

    const chunks: any[] = [];
    let offset = 0;
    let truncated = false;

    for (let page = 0; page < revenueMaxPages; page += 1) {
      const data = await adminRpc("get_revenue_report_period", {
        start: startISO,
        end: endISOExclusive.toISOString(),
        limit: revenuePageSize,
        offset,
      });
      const batch = (data as any[]) ?? [];
      chunks.push(...batch);
      if (batch.length < revenuePageSize) break;
      offset += revenuePageSize;
      if (page === revenueMaxPages - 1) truncated = true;
    }

    rows.value = chunks.map((row: any) => ({
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
      transaction_created_at: row.transaction_created_at ?? row.event_at,
      member_id: row.member_id ?? null,
      member_name: row.member_name ?? "Unbekanntes Mitglied",
      product_id: row.product_id ?? null,
      product_name: row.product_name ?? "Unbekanntes Produkt",
      product_category: row.product_category ?? "Unbekannt",
      amount: Number(row.amount ?? 0),
      amount_abs: Number(row.amount_abs ?? Math.abs(Number(row.amount ?? 0))),
      is_free_amount: Boolean(row.is_free_amount),
      note: row.note ?? null,
    }));

    if (truncated) {
      showToast("⚠️ Umsatzreport wurde auf viele Seiten begrenzt geladen");
    }

    showToast("✅ Umsatzreport geladen");
  } catch (err) {
    console.error("[AdminRevenueReport]", err);
    error.value = "Fehler beim Laden des Umsatzreports";
    showToast("⚠️ Fehler beim Laden des Umsatzreports");
  } finally {
    loading.value = false;
    await nextTick();
    await renderCharts();
  }
}

onMounted(async () => {
  suppressDateReload.value = true;
  applyQueryFilters();
  suppressDateReload.value = false;
  await initChartJs();
  await loadReport();
});

watch([startDate, endDate], async () => {
  if (suppressDateReload.value) return;
  if (!startDate.value || !endDate.value) return;
  await loadReport();
});

watch([selectedMemberId, selectedCategory, selectedTransactionType], async () => {
  await renderCharts();
});

watch(rows, async () => {
  await renderCharts();
});

watch(canUseTrimmedAggregation, (enabled) => {
  if (!enabled && heatAggregationMode.value === "trimmed_mean") {
    heatAggregationMode.value = "mean";
  }
});

onBeforeUnmount(destroyCharts);

async function exportPdf() {
  try {
    await exportReportAsPdf("admin-revenue-report", "Umsatzreport");
  } catch (err) {
    console.error("[AdminRevenueReport.exportPdf]", err);
    showToast("⚠️ PDF-Export fehlgeschlagen");
  }
}
</script>

<template>
  <div class="space-y-6" data-report-id="admin-revenue-report">
    <div class="flex flex-col lg:flex-row justify-between items-start lg:items-center gap-3">
      <h2 class="text-xl font-semibold text-primary">💶 Umsatzreport</h2>
      <div class="flex flex-col sm:flex-row items-stretch sm:items-center gap-3 no-print w-full lg:w-auto">
        <button
          @click="exportPdf"
          class="text-sm px-3 py-2 rounded-lg border border-gray-300 text-gray-700 hover:bg-gray-50 transition"
        >
          Drucken
        </button>
        <RouterLink
          to="/admin/dashboard"
          class="text-sm text-gray-500 hover:text-primary underline"
        >
          ← Zurück zum Dashboard
        </RouterLink>
      </div>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 grid grid-cols-1 md:grid-cols-2 xl:grid-cols-5 gap-4 items-end">
      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">Startdatum</label>
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
        <label class="block text-sm font-medium text-gray-600 mb-1">Enddatum</label>
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

      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">Mitglied</label>
        <select
          v-model="selectedMemberId"
          class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"
        >
          <option value="">Alle Mitglieder</option>
          <option v-for="member in memberOptions" :key="member.id" :value="member.id">
            {{ member.name }}
          </option>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">Kategorie</label>
        <select
          v-model="selectedCategory"
          class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"
        >
          <option value="">Alle Kategorien</option>
          <option v-for="category in categoryOptions" :key="category" :value="category">
            {{ category }}
          </option>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">Typ</label>
        <select
          v-model="selectedTransactionType"
          class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"
        >
          <option v-for="opt in transactionTypeOptions" :key="opt.value || 'all'" :value="opt.value">
            {{ opt.label }}
          </option>
        </select>
      </div>

      <div v-if="loading" class="h-[38px] inline-flex items-center gap-2 text-xs text-gray-500 xl:self-end">
        <span class="inline-block h-3.5 w-3.5 rounded-full border-2 border-gray-300 border-t-primary animate-spin"></span>
        Lädt…
      </div>
    </div>

    <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Umsatz</div>
        <div class="text-2xl font-semibold text-primary">{{ formatEuroFromCents(revenueCents) }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Stornosumme</div>
        <div class="text-2xl font-semibold text-red-700">{{ formatEuroFromCents(canceledCents) }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Stornoquote</div>
        <div class="text-sm text-gray-600">Anzahl: {{ stornoRateCount.toFixed(1) }}%</div>
        <div class="text-xl font-semibold text-primary">Betrag: {{ stornoRateAmount.toFixed(1) }}%</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Durchschnittsbon</div>
        <div class="text-2xl font-semibold text-primary">{{ formatEuroFromCents(avgTicketCents) }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Buchungen</div>
        <div class="text-2xl font-semibold text-primary">{{ bookingCount }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Stornos</div>
        <div class="text-2xl font-semibold text-primary">{{ cancellationCount }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Aktive Käufer</div>
        <div class="text-2xl font-semibold text-primary">{{ activeMembers }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Freie Beträge</div>
        <div class="text-sm text-gray-600">
          {{ freeAmountSummary.count }} Buchungen
        </div>
        <div class="text-xl font-semibold text-primary">
          {{ formatEuroFromCents(freeAmountSummary.cents) }}
        </div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Nicht umsatzrelevant</div>
        <div class="text-sm text-gray-600">
          {{ nonRevenueSummary.count }} Buchungen · {{ nonRevenueSummary.canceledCount }} Stornos
        </div>
        <div class="text-xl font-semibold text-amber-700">
          {{ formatEuroFromCents(nonRevenueSummary.cents) }}
        </div>
        <div class="text-xs text-gray-500">
          Storno: {{ formatEuroFromCents(nonRevenueSummary.canceledCents) }}
        </div>
      </div>
    </div>

    <div v-if="loading" class="text-center py-10 text-gray-500">
      ⏳ Umsatzreport wird geladen...
    </div>
    <div v-else-if="error" class="text-center py-10 text-red-500">
      {{ error }}
    </div>

    <div v-else class="space-y-6">
      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 h-[340px]">
          <h3 class="font-semibold text-primary mb-3">Tagesverlauf (Umsatz / Storno)</h3>
          <canvas ref="trendCanvas" class="h-[270px]"></canvas>
        </div>
        <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 h-[340px]">
          <h3 class="font-semibold text-primary mb-3">Umsatzanteil nach Kategorie (Umsatz)</h3>
          <canvas ref="categoryCanvas" class="h-[270px]"></canvas>
        </div>
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <div class="bg-white rounded-2xl shadow border border-gray-200 p-4">
          <h3 class="font-semibold text-primary mb-3">Top 10 Produkte nach Netto-Menge</h3>
          <div class="space-y-3">
            <div
              v-for="(row, idx) in topProducts"
              :key="row.product_key"
              class="rounded-xl border border-gray-200 p-3 bg-gradient-to-r from-white to-gray-50/80"
            >
              <div class="flex items-center justify-between gap-3 mb-2">
                <div class="flex items-center gap-2 min-w-0">
                  <span class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-primary/10 text-primary text-xs font-semibold">
                    {{ idx + 1 }}
                  </span>
                  <span class="font-medium text-gray-800 truncate">{{ row.product_name }}</span>
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
                <span>{{ row.bookings }} Buchungen · {{ row.cancellations }} Stornos · {{ formatEuroFromCents(row.revenue - row.canceled) }}</span>
                <span>{{ productSharePercent(row.net_quantity).toFixed(1) }}% Anteil</span>
              </div>
            </div>
            <div v-if="topProducts.length === 0" class="text-sm text-gray-400 italic py-8 text-center">
              Keine Produktdaten im Zeitraum
            </div>
          </div>
        </div>

        <div class="bg-white rounded-2xl shadow border border-gray-200 p-4">
          <div class="flex items-center justify-between mb-3">
            <h3 class="font-semibold text-primary">Aktivitäts-Heatmap</h3>
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

      <div class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200">
        <h3 class="font-semibold text-primary px-4 pt-4">Produktübersicht</h3>
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
            <tr>
              <th class="px-4 py-3 text-left">Kategorie</th>
              <th class="px-4 py-3 text-left">Produkt</th>
              <th class="px-4 py-3 text-right">Buchungen</th>
              <th class="px-4 py-3 text-right">Stornos</th>
              <th class="px-4 py-3 text-right">Netto</th>
              <th class="px-4 py-3 text-right">Umsatz</th>
              <th class="px-4 py-3 text-right">Storno</th>
              <th class="px-4 py-3 text-right">Stornoquote</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="row in productSummary"
              :key="row.product_key"
              class="border-t hover:bg-primary/5 transition-colors"
            >
              <td class="px-4 py-2">{{ row.product_category }}</td>
              <td class="px-4 py-2">{{ row.product_name }}</td>
              <td class="px-4 py-2 text-right">{{ row.bookings }}</td>
              <td class="px-4 py-2 text-right">{{ row.cancellations }}</td>
              <td class="px-4 py-2 text-right font-semibold">{{ row.net_quantity }}</td>
              <td class="px-4 py-2 text-right">{{ formatEuroFromCents(row.revenue) }}</td>
              <td class="px-4 py-2 text-right text-red-700">{{ formatEuroFromCents(row.canceled) }}</td>
              <td class="px-4 py-2 text-right font-semibold text-gray-700">
                {{ row.revenue > 0 ? ((row.canceled / row.revenue) * 100).toFixed(1) : "0.0" }}%
              </td>
            </tr>
            <tr v-if="productSummary.length === 0">
              <td colspan="8" class="text-center py-6 text-gray-400 italic">
                Keine Umsätze im gewählten Zeitraum
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200">
        <h3 class="font-semibold text-primary px-4 pt-4">Letzte Ereignisse (max. 100)</h3>
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
            <tr>
              <th class="px-4 py-3 text-left">Typ</th>
              <th class="px-4 py-3 text-left">Zeitpunkt</th>
              <th class="px-4 py-3 text-left">Tag</th>
              <th class="px-4 py-3 text-left">Mitglied</th>
              <th class="px-4 py-3 text-left">Produkt</th>
              <th class="px-4 py-3 text-left">Kategorie</th>
              <th class="px-4 py-3 text-right">Betrag</th>
              <th class="px-4 py-3 text-left">Notiz</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="row in recentEvents"
              :key="`${row.event_type}-${row.event_at}-${row.transaction_created_at}-${row.amount_abs}-${row.member_id ?? 'x'}-${row.product_id ?? 'y'}`"
              class="border-t hover:bg-primary/5 transition-colors"
            >
              <td class="px-4 py-2">
                <span
                  class="px-2 py-1 rounded text-xs font-semibold"
                  :class="
                    row.event_type === 'booking'
                      ? 'bg-emerald-100 text-emerald-800'
                      : 'bg-red-100 text-red-800'
                  "
                >
                  {{ row.event_type === "booking" ? "Buchung" : "Storno" }}
                </span>
                <div class="mt-1 text-[11px] text-gray-500">{{ transactionTypeLabel(row.transaction_type) }}</div>
              </td>
              <td class="px-4 py-2">{{ new Date(row.event_at).toLocaleString("de-DE") }}</td>
              <td class="px-4 py-2">{{ formatDayKey(row.local_day) }}</td>
              <td class="px-4 py-2">{{ row.member_name }}</td>
              <td class="px-4 py-2">{{ row.product_name }}</td>
              <td class="px-4 py-2">{{ row.product_category }}</td>
              <td
                class="px-4 py-2 text-right font-semibold"
                :class="row.event_type === 'booking' ? 'text-emerald-700' : 'text-red-700'"
              >
                {{ formatEuroFromCents(row.amount_abs) }}
              </td>
              <td class="px-4 py-2">{{ row.note || "-" }}</td>
            </tr>
            <tr v-if="recentEvents.length === 0">
              <td colspan="8" class="text-center py-6 text-gray-400 italic">
                Keine Daten im gewählten Zeitraum
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>

