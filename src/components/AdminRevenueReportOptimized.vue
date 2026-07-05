<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRoute } from "vue-router";
import Datepicker from "@vuepic/vue-datepicker";
import DateRangeQuickSelect from "@/components/DateRangeQuickSelect.vue";
import "@vuepic/vue-datepicker/dist/main.css";
import { fetchAdminReportSummary } from "@/lib/adminApi";
import { fmt } from "@/utils/currency";
import { useToast } from "@/composables/useToast";
import { exportReportAsPdf } from "@/utils/reportExport";

type HeatAggregationMode = "trimmed_mean" | "mean" | "max";
type TrendBucketMode = "day" | "week" | "month";
type DailySummaryRow = { day: string; revenue: number; canceled: number };
type TrendSummaryRow = { day: string; label: string; revenue: number };
type MetricBundle = {
  revenueCents: number;
  canceledCents: number;
  goodsCostCents: number;
  canceledGoodsCostCents: number;
  netRevenueCents: number;
  netGoodsCostCents: number;
  grossProfitCents: number;
  grossMarginPercent: number;
  bookingCount: number;
  cancellationCount: number;
  avgTicketCents: number;
  activeMembers: number;
  revenuePerMemberCents: number;
  stornoRateAmount: number;
  stornoRateCount: number;
  freeAmountSummary: { count: number; cents: number; share: number };
  nonRevenueSummary: { count: number; cents: number; canceledCount: number; canceledCents: number };
};

const { show: showToast } = useToast();
const route = useRoute();

const loading = ref(false);
const error = ref<string | null>(null);
const suppressDateReload = ref(false);
const selectedMemberId = ref("");
const selectedCategory = ref("");
const selectedTransactionType = ref("");

const today = new Date();
const sevenDaysAgo = new Date();
sevenDaysAgo.setDate(today.getDate() - 7);
const startDate = ref<Date>(sevenDaysAgo);
const endDate = ref<Date>(today);

const heatAggregationMode = ref<HeatAggregationMode>("trimmed_mean");
const heatAggregationOptions: Array<{ value: HeatAggregationMode; label: string }> = [
  { value: "trimmed_mean", label: "Bereinigt" },
  { value: "mean", label: "Durchschnitt" },
  { value: "max", label: "Max" },
];

const metrics = ref<MetricBundle>({
  revenueCents: 0,
  canceledCents: 0,
  goodsCostCents: 0,
  canceledGoodsCostCents: 0,
  netRevenueCents: 0,
  netGoodsCostCents: 0,
  grossProfitCents: 0,
  grossMarginPercent: 0,
  bookingCount: 0,
  cancellationCount: 0,
  avgTicketCents: 0,
  activeMembers: 0,
  revenuePerMemberCents: 0,
  stornoRateAmount: 0,
  stornoRateCount: 0,
  freeAmountSummary: { count: 0, cents: 0, share: 0 },
  nonRevenueSummary: { count: 0, cents: 0, canceledCount: 0, canceledCents: 0 },
});
const memberOptions = ref<Array<{ id: string; name: string }>>([]);
const categoryOptions = ref<string[]>([]);
const dailySummary = ref<DailySummaryRow[]>([]);
const categorySummary = ref<Array<{ category: string; revenue: number; canceled: number }>>([]);
const productSummary = ref<Array<{ product_key: string; product_name: string; product_category: string; bookings: number; cancellations: number; net_quantity: number; revenue: number; canceled: number; goods_cost: number; canceled_goods_cost: number; gross_profit: number }>>([]);
const topProducts = ref<Array<{ product_key: string; product_name: string; bookings: number; cancellations: number; net_quantity: number; revenue: number; canceled: number; goods_cost: number; canceled_goods_cost: number; gross_profit: number }>>([]);
const heatGrid = ref<Array<{ day: number; label: string; cells: Array<{ day: number; hour: number; count: number }> }>>([]);
const recentEvents = ref<any[]>([]);

const revenueCents = computed(() => metrics.value.revenueCents);
const canceledCents = computed(() => metrics.value.canceledCents);
const goodsCostCents = computed(() => metrics.value.goodsCostCents);
const canceledGoodsCostCents = computed(() => metrics.value.canceledGoodsCostCents);
const netRevenueCents = computed(() => metrics.value.netRevenueCents);
const grossProfitCents = computed(() => metrics.value.grossProfitCents);
const grossMarginPercent = computed(() => metrics.value.grossMarginPercent);
const bookingCount = computed(() => metrics.value.bookingCount);
const cancellationCount = computed(() => metrics.value.cancellationCount);
const avgTicketCents = computed(() => metrics.value.avgTicketCents);
const stornoRateAmount = computed(() => metrics.value.stornoRateAmount);
const stornoRateCount = computed(() => metrics.value.stornoRateCount);
const activeMembers = computed(() => metrics.value.activeMembers);
const freeAmountSummary = computed(() => metrics.value.freeAmountSummary);
const nonRevenueSummary = computed(() => metrics.value.nonRevenueSummary);

const minTrimmedDays = 35;
const canUseTrimmedAggregation = computed(() => {
  const start = new Date(startDate.value);
  const end = new Date(endDate.value);
  start.setHours(0, 0, 0, 0);
  end.setHours(0, 0, 0, 0);
  return Math.floor((end.getTime() - start.getTime()) / 86400000) + 1 >= minTrimmedDays;
});
const heatAggregationModeEffective = computed<HeatAggregationMode>(() =>
  heatAggregationMode.value === "trimmed_mean" && !canUseTrimmedAggregation.value
    ? "mean"
    : heatAggregationMode.value,
);
const heatAggregationOptionsVisible = computed(() =>
  heatAggregationOptions.filter((opt) => opt.value === "trimmed_mean" ? canUseTrimmedAggregation.value : true),
);

const transactionTypeOptions = [
  { value: "", label: "Alle" },
  { value: "revenue", label: "Umsatzrelevant" },
  { value: "non_revenue", label: "Nicht umsatzrelevant" },
  { value: "sale_product", label: "Nur Produktverkäufe" },
  { value: "sale_free_amount", label: "Nur freie Verkäufe" },
  { value: "complimentary_product", label: "Nur Freigetränke" },
];

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

async function initChartJs() {
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

function formatDayKey(day: string) {
  const [y, m, d] = day.split("-");
  if (!y || !m || !d) return day;
  return `${d}.${m}.${y}`;
}

function parseDayKey(day: string) {
  const [y, m, d] = day.split("-").map((part) => Number(part));
  if (!y || !m || !d) return null;
  const date = new Date(y, m - 1, d);
  return Number.isNaN(date.getTime()) ? null : date;
}

function daySpan() {
  const start = new Date(startDate.value);
  const end = new Date(endDate.value);
  start.setHours(0, 0, 0, 0);
  end.setHours(0, 0, 0, 0);
  return Math.max(1, Math.floor((end.getTime() - start.getTime()) / 86400000) + 1);
}

function trendBucketMode(): TrendBucketMode {
  const days = daySpan();
  if (days <= 60) return "day";
  if (days <= 180) return "week";
  return "month";
}

function isoDateKey(date: Date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function weekStart(date: Date) {
  const d = new Date(date);
  const day = d.getDay();
  const diff = day === 0 ? -6 : 1 - day;
  d.setDate(d.getDate() + diff);
  d.setHours(0, 0, 0, 0);
  return d;
}

function trendLabel(mode: TrendBucketMode, bucketStart: Date) {
  if (mode === "month") {
    return bucketStart.toLocaleDateString("de-DE", { month: "short", year: "numeric" });
  }
  if (mode === "week") {
    const end = new Date(bucketStart);
    end.setDate(bucketStart.getDate() + 6);
    return `${bucketStart.toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit" })}. - ${end.toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit" })}.`;
  }
  return formatDayKey(isoDateKey(bucketStart));
}

function buildTrendSummary(rows: DailySummaryRow[]): TrendSummaryRow[] {
  const mode = trendBucketMode();
  const buckets = new Map<string, TrendSummaryRow>();

  for (const row of rows) {
    const day = parseDayKey(row.day);
    if (!day) continue;

    const bucketStart = mode === "month"
      ? new Date(day.getFullYear(), day.getMonth(), 1)
      : mode === "week"
        ? weekStart(day)
        : day;
    const key = isoDateKey(bucketStart);
    const current = buckets.get(key) ?? {
      day: key,
      label: trendLabel(mode, bucketStart),
      revenue: 0,
    };
    current.revenue += Number(row.revenue ?? 0);
    buckets.set(key, current);
  }

  return [...buckets.values()].sort((a, b) => a.day.localeCompare(b.day));
}

function formatEuroFromCents(cents: number) {
  return fmt(cents / 100);
}

function productGrossMarginPercent(row: { revenue: number; gross_profit: number }) {
  return row.revenue > 0 ? (row.gross_profit / row.revenue) * 100 : 0;
}

function transactionTypeLabel(v: string) {
  if (v === "complimentary_product") return "Freigetränk";
  if (v === "cash_withdrawal") return "Bar-Entnahme";
  if (v === "credit_adjustment") return "Guthabenbuchung";
  if (v === "sale_free_amount") return "Freier Verkauf";
  return "Produktverkauf";
}

function dayLabel(day: number) {
  return ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][day] ?? "-";
}

function ratio(value: number, max: number) {
  return max > 0 ? Math.max(0, Math.min(1, value / max)) : 0;
}

function heatAggregationLabel(mode: HeatAggregationMode) {
  return heatAggregationOptions.find((opt) => opt.value === mode)?.label ?? "Bereinigt";
}

function fmtHeatValue(value: number) {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

const heatScaleP95 = computed(() => {
  const values = heatGrid.value
    .flatMap((row) => row.cells.map((cell) => Number(cell.count ?? 0)))
    .filter((value) => Number.isFinite(value) && value > 0)
    .sort((a, b) => a - b);
  if (!values.length) return 1;
  const idx = Math.max(0, Math.ceil(values.length * 0.95) - 1);
  return Math.max(1, values[idx] ?? values[values.length - 1] ?? 1);
});

function heatCellStyle(count: number) {
  const r = ratio(count, heatScaleP95.value);
  const cool: [number, number, number] = [229, 231, 235];
  const mid: [number, number, number] = [250, 204, 21];
  const hot: [number, number, number] = [220, 38, 38];
  const t = r <= 0.5 ? r / 0.5 : (r - 0.5) / 0.5;
  const from = r <= 0.5 ? cool : mid;
  const to = r <= 0.5 ? mid : hot;
  const mix = (a: number, b: number) => Math.round(a + (b - a) * t);
  return {
    backgroundColor: `rgb(${mix(from[0], to[0])}, ${mix(from[1], to[1])}, ${mix(from[2], to[2])})`,
    opacity: count > 0 ? 0.95 : 0.5,
  };
}

function heatCellTitle(day: number, hour: number, count: number) {
  return `${dayLabel(day)}, ${hour.toString().padStart(2, "0")}:00 - ${(hour + 1)
    .toString()
    .padStart(2, "0")}:00 | ${heatAggregationLabel(heatAggregationModeEffective.value)} ${fmtHeatValue(count)} Buchungen`;
}

const topProductMaxAbs = computed(() =>
  Math.max(1, ...topProducts.value.map((product) => Math.abs(Number(product.net_quantity ?? 0)))),
);
const topProductTotalNet = computed(() =>
  topProducts.value.reduce((sum, product) => sum + Math.max(0, Number(product.net_quantity ?? 0)), 0),
);

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
  return topProductTotalNet.value > 0 ? (Math.max(0, net) / topProductTotalNet.value) * 100 : 0;
}

async function renderCharts() {
  await nextTick();
  destroyCharts();
  if (!Chart) return;

  if (trendCanvas.value) {
    const trendSummary = buildTrendSummary(dailySummary.value);
    trendChart = new Chart(trendCanvas.value, {
      type: "line",
      data: {
        labels: trendSummary.map((row) => row.label),
        datasets: [
          { label: "Umsatz", data: trendSummary.map((row) => row.revenue / 100), borderColor: "#2563eb", backgroundColor: "rgba(37,99,235,0.15)", fill: true, tension: 0.2 },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { tooltip: { callbacks: { label: (ctx: any) => `${ctx.dataset.label}: ${ctx.parsed.y.toFixed(2)} €` } } },
        scales: {
          y: { beginAtZero: true, ticks: { callback: (v: any) => `${v} €` } },
          x: { grid: { display: false }, ticks: { maxRotation: 0, autoSkip: true, maxTicksLimit: 12 } },
        },
      },
    });
  }

  if (categoryCanvas.value) {
    categoryChart = new Chart(categoryCanvas.value, {
      type: "doughnut",
      data: {
        labels: categorySummary.value.map((row) => row.category),
        datasets: [{ data: categorySummary.value.map((row) => Math.max(row.revenue, 0) / 100), backgroundColor: ["#1d4ed8", "#059669", "#d97706", "#7c3aed", "#dc2626", "#0f766e", "#4f46e5", "#9a3412", "#3f6212"] }],
      },
      options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: "bottom" } } },
    });
  }
}

function onQuickDateSelect(start: Date, end: Date) {
  suppressDateReload.value = true;
  startDate.value = start;
  endDate.value = end;
  void nextTick().then(() => { suppressDateReload.value = false; });
  void loadReport();
}

let loadSeq = 0;

async function loadReport() {
  const seq = ++loadSeq;
  loading.value = true;
  error.value = null;
  try {
    const startISO = getLocalDayRange(startDate.value, false);
    const endISOExclusive = new Date(getLocalDayRange(endDate.value, true));
    endISOExclusive.setMilliseconds(endISOExclusive.getMilliseconds() + 1);

    const payload = await fetchAdminReportSummary({
      start: startISO,
      end: endISOExclusive.toISOString(),
      heat_aggregation_mode: heatAggregationModeEffective.value,
      filters: {
        member_id: selectedMemberId.value || undefined,
        category: selectedCategory.value || undefined,
        transaction_type: selectedTransactionType.value || undefined,
      },
      recent_events_limit: 100,
    });

    if (seq !== loadSeq) return;

    metrics.value = payload.metrics ?? metrics.value;
    memberOptions.value = Array.isArray(payload.memberOptions) ? payload.memberOptions : [];
    categoryOptions.value = Array.isArray(payload.categoryOptions) ? payload.categoryOptions : [];
    dailySummary.value = Array.isArray(payload.dailySummary) ? payload.dailySummary : [];
    categorySummary.value = Array.isArray(payload.categorySummary) ? payload.categorySummary : [];
    productSummary.value = Array.isArray(payload.productSummary) ? payload.productSummary : [];
    topProducts.value = Array.isArray(payload.topProducts) ? payload.topProducts : [];
    heatGrid.value = Array.isArray(payload.heatGrid) ? payload.heatGrid : [];
    recentEvents.value = Array.isArray(payload.recentEvents) ? payload.recentEvents : [];

    if (payload.truncated) {
      showToast("⚠️ Umsatzreport wurde serverseitig begrenzt zusammengefasst");
    }
  } catch (err: any) {
    console.error("[AdminRevenueReportOptimized]", err);
    if (seq !== loadSeq) return;
    error.value = err.message || "Fehler beim Laden des Umsatzreports";
    showToast("⚠️ Fehler beim Laden des Umsatzreports");
  } finally {
    if (seq === loadSeq) {
      loading.value = false;
      await renderCharts();
    }
  }
}

onMounted(async () => {
  suppressDateReload.value = true;
  applyQueryFilters();
  void nextTick().then(() => { suppressDateReload.value = false; });
  await initChartJs();
  await loadReport();
});

watch([startDate, endDate], async () => {
  if (suppressDateReload.value) return;
  await loadReport();
});

watch([selectedMemberId, selectedCategory, selectedTransactionType], async () => {
  await loadReport();
});

function selectHeatAggregationMode(mode: HeatAggregationMode) {
  if (heatAggregationMode.value === mode) return;
  heatAggregationMode.value = mode;
  void loadReport();
}

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
        <button @click="exportPdf" class="text-sm px-3 py-2 rounded-lg border border-gray-300 text-gray-700 hover:bg-gray-50 transition">Drucken</button>
        <RouterLink to="/admin/dashboard" class="text-sm text-gray-500 hover:text-primary underline">← Zurück zum Dashboard</RouterLink>
      </div>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 grid grid-cols-1 md:grid-cols-2 xl:grid-cols-5 gap-4 items-end">
      <div class="col-span-full"><DateRangeQuickSelect @select="onQuickDateSelect" /></div>
      <div><label class="block text-sm font-medium text-gray-600 mb-1">Startdatum</label><Datepicker v-model="startDate" :enable-time-picker="false" :format="'dd.MM.yyyy'" :auto-apply="true" :close-on-auto-apply="true" :config="{ keepActionRow: true }" :action-row="{ showNow: true, nowBtnLabel: 'Heute', showSelect: false, showCancel: false }" /></div>
      <div><label class="block text-sm font-medium text-gray-600 mb-1">Enddatum</label><Datepicker v-model="endDate" :enable-time-picker="false" :format="'dd.MM.yyyy'" :auto-apply="true" :close-on-auto-apply="true" :config="{ keepActionRow: true }" :action-row="{ showNow: true, nowBtnLabel: 'Heute', showSelect: false, showCancel: false }" /></div>
      <div><label class="block text-sm font-medium text-gray-600 mb-1">Mitglied</label><select v-model="selectedMemberId" class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"><option value="">Alle Mitglieder</option><option v-for="member in memberOptions" :key="member.id" :value="member.id">{{ member.name }}</option></select></div>
      <div><label class="block text-sm font-medium text-gray-600 mb-1">Kategorie</label><select v-model="selectedCategory" class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"><option value="">Alle Kategorien</option><option v-for="category in categoryOptions" :key="category" :value="category">{{ category }}</option></select></div>
      <div><label class="block text-sm font-medium text-gray-600 mb-1">Typ</label><select v-model="selectedTransactionType" class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"><option v-for="opt in transactionTypeOptions" :key="opt.value || 'all'" :value="opt.value">{{ opt.label }}</option></select></div>
      <div v-if="loading" class="h-[38px] inline-flex items-center gap-2 text-xs text-gray-500 xl:self-end"><span class="inline-block h-3.5 w-3.5 rounded-full border-2 border-gray-300 border-t-primary animate-spin"></span>Lädt…</div>
    </div>

    <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Umsatz</div><div class="text-2xl font-semibold text-primary">{{ formatEuroFromCents(revenueCents) }}</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Stornosumme</div><div class="text-2xl font-semibold text-red-700">{{ formatEuroFromCents(canceledCents) }}</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Wareneinsatz</div><div class="text-2xl font-semibold text-amber-700">{{ formatEuroFromCents(goodsCostCents) }}</div><div class="text-xs text-gray-500">Storno: {{ formatEuroFromCents(canceledGoodsCostCents) }}</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Rohgewinn</div><div class="text-2xl font-semibold" :class="grossProfitCents >= 0 ? 'text-emerald-700' : 'text-red-700'">{{ formatEuroFromCents(grossProfitCents) }}</div><div class="text-xs text-gray-500">Marge: {{ grossMarginPercent.toFixed(1) }}%</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Stornoquote</div><div class="text-sm text-gray-600">Anzahl: {{ stornoRateCount.toFixed(1) }}%</div><div class="text-xl font-semibold text-primary">Betrag: {{ stornoRateAmount.toFixed(1) }}%</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Durchschnittsbon</div><div class="text-2xl font-semibold text-primary">{{ formatEuroFromCents(avgTicketCents) }}</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Buchungen</div><div class="text-2xl font-semibold text-primary">{{ bookingCount }}</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Stornos</div><div class="text-2xl font-semibold text-primary">{{ cancellationCount }}</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Aktive Käufer</div><div class="text-2xl font-semibold text-primary">{{ activeMembers }}</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Freie Beträge</div><div class="text-sm text-gray-600">{{ freeAmountSummary.count }} Buchungen</div><div class="text-xl font-semibold text-primary">{{ formatEuroFromCents(freeAmountSummary.cents) }}</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Nicht umsatzrelevant</div><div class="text-sm text-gray-600">{{ nonRevenueSummary.count }} Buchungen · {{ nonRevenueSummary.canceledCount }} Stornos</div><div class="text-xl font-semibold text-amber-700">{{ formatEuroFromCents(nonRevenueSummary.cents) }}</div><div class="text-xs text-gray-500">Storno: {{ formatEuroFromCents(nonRevenueSummary.canceledCents) }}</div></div>
      <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Report-Umsatz</div><div class="text-2xl font-semibold text-primary">{{ formatEuroFromCents(netRevenueCents) }}</div></div>
    </div>

    <div v-if="loading" class="text-center py-10 text-gray-500">⏳ Umsatzreport wird geladen...</div>
    <div v-else-if="error" class="text-center py-10 text-red-500">{{ error }}</div>

    <div v-else class="space-y-6">
      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6 print-section">
        <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 h-[340px] print-card"><h3 class="font-semibold text-primary mb-3">Umsatzverlauf</h3><canvas ref="trendCanvas" class="h-[270px]"></canvas></div>
        <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 h-[340px] print-card"><h3 class="font-semibold text-primary mb-3">Umsatzanteil nach Kategorie (Umsatz)</h3><canvas ref="categoryCanvas" class="h-[270px]"></canvas></div>
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6 print-section">
        <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 print-card">
          <h3 class="font-semibold text-primary mb-3">Top 10 Produkte nach Buchungen</h3>
          <div class="space-y-3">
            <div v-for="(row, idx) in topProducts" :key="row.product_key" class="rounded-xl border border-gray-200 p-3 bg-gradient-to-r from-white to-gray-50/80">
              <div class="flex items-center justify-between gap-3 mb-2"><div class="flex items-center gap-2 min-w-0"><span class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-primary/10 text-primary text-xs font-semibold">{{ idx + 1 }}</span><span class="font-medium text-gray-800 truncate">{{ row.product_name }}</span></div><div class="text-sm font-semibold whitespace-nowrap text-emerald-700">{{ row.net_quantity }} gebucht</div></div>
              <div class="h-2.5 rounded-full bg-slate-100 overflow-hidden"><div class="h-full rounded-full transition-all duration-500" :style="productBarStyle(row.net_quantity)"></div></div>
              <div class="mt-2 flex items-center justify-between text-xs text-gray-500"><span>{{ row.bookings }} Buchungen · {{ row.cancellations }} Stornos · {{ formatEuroFromCents(row.gross_profit) }} Rohgewinn</span><span>{{ productSharePercent(row.net_quantity).toFixed(1) }}% Anteil</span></div>
            </div>
            <div v-if="topProducts.length === 0" class="text-sm text-gray-400 italic py-8 text-center">Keine Produktdaten im Zeitraum</div>
          </div>
        </div>

        <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 print-card print-heatmap">
          <div class="flex items-center justify-between mb-3">
            <h3 class="font-semibold text-primary">Aktivitäts-Heatmap</h3>
            <div class="flex flex-wrap items-center justify-end gap-2">
              <div class="inline-flex max-w-full rounded-lg border border-gray-200 overflow-hidden">
                <button v-for="opt in heatAggregationOptionsVisible" :key="opt.value" type="button" class="px-2 py-1 text-[11px] transition whitespace-nowrap" :class="[heatAggregationMode === opt.value ? 'bg-primary text-white' : 'bg-white text-gray-600 hover:bg-gray-50', opt.value !== heatAggregationOptionsVisible[0].value ? 'border-l border-gray-200' : '']" @click="selectHeatAggregationMode(opt.value)">{{ opt.label }}</button>
              </div>
              <span class="text-xs text-gray-500">Montag bis Sonntag, 0-23 Uhr</span>
            </div>
          </div>
          <div class="rounded-xl border border-gray-100 p-2 print-heatmap-grid">
            <div class="grid grid-cols-[32px_repeat(24,minmax(0,1fr))] gap-0 mb-1"><div></div><div v-for="hour in 24" :key="`hour-${hour - 1}`" class="text-[9px] text-center text-gray-400">{{ (hour - 1) % 2 === 0 ? (hour - 1).toString().padStart(2, "0") : "" }}</div></div>
            <div v-for="row in heatGrid" :key="`day-${row.day}`" class="grid grid-cols-[32px_repeat(24,minmax(0,1fr))] gap-0 mb-[2px] items-center print-heatmap-row"><div class="text-[11px] font-medium text-gray-600">{{ row.label }}</div><div v-for="cell in row.cells" :key="`cell-${cell.day}-${cell.hour}`" class="h-5 sm:h-6 rounded-[2px] transition-colors duration-200 print-heatmap-cell" :style="heatCellStyle(cell.count)" :title="heatCellTitle(cell.day, cell.hour, cell.count)"></div></div>
            <div class="mt-3 flex items-center gap-2"><span class="text-[11px] text-gray-500">Wenig</span><div class="h-2.5 flex-1 rounded-full bg-gradient-to-r from-gray-200 via-amber-300 to-red-600"></div><span class="text-[11px] text-gray-500">Viel</span></div>
          </div>
        </div>
      </div>

      <div class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200 print-table-card">
        <h3 class="font-semibold text-primary px-4 pt-4">Produktübersicht</h3>
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold"><tr><th class="px-4 py-3 text-left">Kategorie</th><th class="px-4 py-3 text-left">Produkt</th><th class="px-4 py-3 text-right">Buchungen</th><th class="px-4 py-3 text-right">Stornos</th><th class="px-4 py-3 text-right">Menge</th><th class="px-4 py-3 text-right">Umsatz</th><th class="px-4 py-3 text-right">Wareneinsatz</th><th class="px-4 py-3 text-right">Rohgewinn</th><th class="px-4 py-3 text-right">Marge</th></tr></thead>
          <tbody>
            <tr v-for="row in productSummary" :key="row.product_key" class="border-t hover:bg-primary/5 transition-colors"><td class="px-4 py-2">{{ row.product_category }}</td><td class="px-4 py-2">{{ row.product_name }}</td><td class="px-4 py-2 text-right">{{ row.bookings }}</td><td class="px-4 py-2 text-right">{{ row.cancellations }}</td><td class="px-4 py-2 text-right font-semibold">{{ row.net_quantity }}</td><td class="px-4 py-2 text-right">{{ formatEuroFromCents(row.revenue) }}</td><td class="px-4 py-2 text-right text-amber-700">{{ formatEuroFromCents(row.goods_cost) }}</td><td class="px-4 py-2 text-right font-semibold" :class="row.gross_profit >= 0 ? 'text-emerald-700' : 'text-red-700'">{{ formatEuroFromCents(row.gross_profit) }}</td><td class="px-4 py-2 text-right font-semibold" :class="row.gross_profit >= 0 ? 'text-emerald-700' : 'text-red-700'">{{ productGrossMarginPercent(row).toFixed(1) }}%</td></tr>
            <tr v-if="productSummary.length === 0"><td colspan="9" class="text-center py-6 text-gray-400 italic">Keine Umsätze im gewählten Zeitraum</td></tr>
          </tbody>
        </table>
      </div>

      <div class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200 print-table-card">
        <h3 class="font-semibold text-primary px-4 pt-4">Letzte Ereignisse (max. 100)</h3>
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold"><tr><th class="px-4 py-3 text-left">Typ</th><th class="px-4 py-3 text-left">Zeitpunkt</th><th class="px-4 py-3 text-left">Tag</th><th class="px-4 py-3 text-left">Mitglied</th><th class="px-4 py-3 text-left">Produkt</th><th class="px-4 py-3 text-left">Kategorie</th><th class="px-4 py-3 text-right">Betrag</th><th class="px-4 py-3 text-left">Notiz</th></tr></thead>
          <tbody>
            <tr v-for="row in recentEvents" :key="`${row.event_type}-${row.event_at}-${row.transaction_created_at}-${row.amount_abs}-${row.member_id ?? 'x'}-${row.product_id ?? 'y'}`" class="border-t hover:bg-primary/5 transition-colors"><td class="px-4 py-2"><span class="px-2 py-1 rounded text-xs font-semibold" :class="row.event_type === 'booking' ? 'bg-emerald-100 text-emerald-800' : 'bg-red-100 text-red-800'">{{ row.event_type === "booking" ? "Buchung" : "Storno" }}</span><div class="mt-1 text-[11px] text-gray-500">{{ transactionTypeLabel(row.transaction_type) }}</div></td><td class="px-4 py-2">{{ new Date(row.event_at).toLocaleString("de-DE") }}</td><td class="px-4 py-2">{{ formatDayKey(row.local_day) }}</td><td class="px-4 py-2">{{ row.member_name }}</td><td class="px-4 py-2">{{ row.product_name }}</td><td class="px-4 py-2">{{ row.product_category }}</td><td class="px-4 py-2 text-right font-semibold" :class="row.event_type === 'booking' ? 'text-emerald-700' : 'text-red-700'">{{ formatEuroFromCents(row.amount_abs) }}</td><td class="px-4 py-2">{{ row.note || "-" }}</td></tr>
            <tr v-if="recentEvents.length === 0"><td colspan="8" class="text-center py-6 text-gray-400 italic">Keine Daten im gewählten Zeitraum</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>
