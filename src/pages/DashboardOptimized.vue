<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRouter } from "vue-router";
import Datepicker from "@vuepic/vue-datepicker";
import "@vuepic/vue-datepicker/dist/main.css";
import { fetchAdminReportSummary } from "@/lib/adminApi";
import { fmt } from "@/utils/currency";

type HeatAggregationMode = "trimmed_mean" | "mean" | "max";
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

const loading = ref(true);
const error = ref<string | null>(null);
const preset = ref("30d");
const router = useRouter();

const today = new Date();
const thirtyDaysAgo = new Date();
thirtyDaysAgo.setDate(today.getDate() - 30);
const startDate = ref<Date>(thirtyDaysAgo);
const endDate = ref<Date>(today);
const suppressDateReload = ref(false);

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
const dailySummary = ref<Array<{ day: string; revenue: number; canceled: number }>>([]);
const categorySummary = ref<Array<{ category: string; revenue: number; canceled: number }>>([]);
const topProducts = ref<Array<{ product_key?: string; product_name?: string; product?: string; bookings: number; cancellations: number; net_quantity: number; revenue: number; canceled: number; gross_profit?: number }>>([]);
const heatGrid = ref<Array<{ day: number; label: string; cells: Array<{ day: number; hour: number; count: number }> }>>([]);
const peakHour = ref<{ stunde: number; anzahl_tx: number } | null>(null);
const peakWeekday = ref<{ day: number; count: number } | null>(null);

const revenueCents = computed(() => metrics.value.revenueCents);
const canceledCents = computed(() => metrics.value.canceledCents);
const goodsCostCents = computed(() => metrics.value.goodsCostCents);
const grossProfitCents = computed(() => metrics.value.grossProfitCents);
const grossMarginPercent = computed(() => metrics.value.grossMarginPercent);
const bookingCount = computed(() => metrics.value.bookingCount);
const cancellationCount = computed(() => metrics.value.cancellationCount);
const avgTicketCents = computed(() => metrics.value.avgTicketCents);
const activeMembers = computed(() => metrics.value.activeMembers);
const revenuePerMemberCents = computed(() => metrics.value.revenuePerMemberCents);
const stornoRateAmount = computed(() => metrics.value.stornoRateAmount);
const stornoRateCount = computed(() => metrics.value.stornoRateCount);
const freeAmountSummary = computed(() => metrics.value.freeAmountSummary);
const nonRevenueSummary = computed(() => metrics.value.nonRevenueSummary);

const minTrimmedDays = 35;
const canUseTrimmedAggregation = computed(() => {
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

function currentRangeQuery() {
  const start = getLocalDayRange(startDate.value, false);
  const endISOExclusive = new Date(getLocalDayRange(endDate.value, true));
  endISOExclusive.setMilliseconds(endISOExclusive.getMilliseconds() + 1);
  return { start, end: endISOExclusive.toISOString() };
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
    void loadData();
  }
}

function formatDayKey(day: string) {
  const [y, m, d] = day.split("-");
  if (!y || !m || !d) return day;
  return `${d}.${m}.${y}`;
}

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
  const total = Number(topProductTotalNet.value || 0);
  return total > 0 ? (Math.max(0, net) / total) * 100 : 0;
}

function goToRevenue(extra?: Record<string, string>) {
  router.push({ path: "/admin/revenue-report", query: { ...currentRangeQuery(), ...(extra ?? {}) } });
}

function goToBookings(extra?: Record<string, string>) {
  router.push({ path: "/admin/bookings-report", query: { ...currentRangeQuery(), ...(extra ?? {}) } });
}

function goToCancellations(extra?: Record<string, string>) {
  router.push({ path: "/admin/cancellations-report", query: { ...currentRangeQuery(), ...(extra ?? {}) } });
}

async function renderCharts() {
  await nextTick();
  destroyCharts();
  if (!Chart) return;

  if (trendCanvas.value) {
    trendChart = new Chart(trendCanvas.value, {
      type: "line",
      data: {
        labels: dailySummary.value.map((row) => formatDayKey(row.day)),
        datasets: [
          { label: "Umsatz", data: dailySummary.value.map((row) => row.revenue / 100), borderColor: "#2563eb", backgroundColor: "rgba(37,99,235,0.15)", fill: true, tension: 0.2 },
          { label: "Storno", data: dailySummary.value.map((row) => row.canceled / 100), borderColor: "#dc2626", backgroundColor: "rgba(220,38,38,0.12)", fill: true, tension: 0.2 },
        ],
      },
      options: { responsive: true, maintainAspectRatio: false, plugins: { tooltip: { callbacks: { label: (ctx: any) => `${ctx.dataset.label}: ${ctx.parsed.y.toFixed(2)} €` } } }, scales: { y: { beginAtZero: true, ticks: { callback: (value: any) => `${value} €` } }, x: { grid: { display: false } } } },
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

async function loadData() {
  loading.value = true;
  error.value = null;
  try {
    const range = currentRangeQuery();
    const payload = await fetchAdminReportSummary({
      start: range.start,
      end: range.end,
      heat_aggregation_mode: heatAggregationModeEffective.value,
      recent_events_limit: 0,
    });
    metrics.value = payload.metrics ?? metrics.value;
    dailySummary.value = Array.isArray(payload.dailySummary) ? payload.dailySummary : [];
    categorySummary.value = Array.isArray(payload.categorySummary) ? payload.categorySummary : [];
    topProducts.value = Array.isArray(payload.topProducts) ? payload.topProducts : [];
    heatGrid.value = Array.isArray(payload.heatGrid) ? payload.heatGrid : [];
    peakHour.value = payload.peakHour ?? null;
    peakWeekday.value = payload.peakWeekday ?? null;
  } catch (e: any) {
    console.error("[DashboardOptimized]", e);
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
  await loadData();
});

watch(heatAggregationModeEffective, async () => {
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
          <select v-model="preset" class="border rounded-md px-3 py-2 text-sm bg-white shadow-sm" @change="onPresetChange">
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
          <Datepicker v-model="startDate" :enable-time-picker="false" :format="'dd.MM.yyyy'" :auto-apply="true" :close-on-auto-apply="true" :config="{ keepActionRow: true }" :action-row="{ showNow: true, nowBtnLabel: 'Heute', showSelect: false, showCancel: false }" />
        </div>
        <div>
          <label class="block text-xs text-gray-500 mb-1">Bis</label>
          <Datepicker v-model="endDate" :enable-time-picker="false" :format="'dd.MM.yyyy'" :auto-apply="true" :close-on-auto-apply="true" :config="{ keepActionRow: true }" :action-row="{ showNow: true, nowBtnLabel: 'Heute', showSelect: false, showCancel: false }" />
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
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Umsatz</div><div class="text-2xl font-semibold text-primary">{{ euro(revenueCents) }}</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToCancellations()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Stornosumme</div><div class="text-2xl font-semibold text-red-700">{{ euro(canceledCents) }}</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Wareneinsatz</div><div class="text-2xl font-semibold text-amber-700">{{ euro(goodsCostCents) }}</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Rohgewinn</div><div class="text-2xl font-semibold" :class="grossProfitCents >= 0 ? 'text-emerald-700' : 'text-red-700'">{{ euro(grossProfitCents) }}</div><div class="text-xs text-gray-500">Marge {{ grossMarginPercent.toFixed(1) }}%</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToCancellations()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Stornos</div><div class="text-2xl font-semibold text-primary">{{ cancellationCount }}</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Ø Bon</div><div class="text-2xl font-semibold text-primary">{{ euro(avgTicketCents) }}</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToBookings()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Buchungen</div><div class="text-2xl font-semibold text-primary">{{ bookingCount }}</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToCancellations()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Stornoquote</div><div class="text-sm text-gray-600">Anzahl: {{ stornoRateCount.toFixed(1) }}%</div><div class="text-xl font-semibold text-primary">Betrag: {{ stornoRateAmount.toFixed(1) }}%</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Aktive Käufer</div><div class="text-2xl font-semibold text-primary">{{ activeMembers }}</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Umsatz pro Mitglied</div><div class="text-2xl font-semibold text-primary">{{ euro(revenuePerMemberCents) }}</div></button>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue({ free_only: '1' })"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Freie Beträge</div><div class="text-sm text-gray-600">{{ freeAmountSummary.count }} Buchungen</div><div class="text-xl font-semibold text-primary">{{ euro(freeAmountSummary.cents) }}</div><div class="text-xs text-gray-500">{{ freeAmountSummary.share.toFixed(1) }}% vom Umsatz</div></button>
        <button class="relative bg-white rounded-xl border border-primary/25 p-4 pr-14 text-left transition active:scale-[0.99]" @click="goToRevenue()"><span class="absolute right-3 top-3 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary">Details</span><div class="text-xs uppercase text-gray-500">Nicht umsatzrelevant</div><div class="text-sm text-gray-600">{{ nonRevenueSummary.count }} Buchungen · {{ nonRevenueSummary.canceledCount }} Stornos</div><div class="text-xl font-semibold text-amber-700">{{ euro(nonRevenueSummary.cents) }}</div><div class="text-xs text-gray-500">Storno: {{ euro(nonRevenueSummary.canceledCents) }}</div></button>
        <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Peak-Stunde</div><div class="text-2xl font-semibold text-primary">{{ peakHour ? `${peakHour.stunde}:00` : "-" }}</div><div class="text-xs text-gray-500">{{ peakHour ? `${heatAggregationLabel(heatAggregationModeEffective)} ${fmtHeatValue(peakHour.anzahl_tx)} Buchungen` : "Keine Daten" }}</div></div>
        <div class="bg-white rounded-xl border border-gray-200 p-4"><div class="text-xs uppercase text-gray-500">Peak-Wochentag</div><div class="text-2xl font-semibold text-primary">{{ peakWeekday ? dayLabel(peakWeekday.day) : "-" }}</div><div class="text-xs text-gray-500">{{ peakWeekday ? `${heatAggregationLabel(heatAggregationModeEffective)} ${fmtHeatValue(peakWeekday.count)} Buchungen` : "Keine Daten" }}</div></div>
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <div class="bg-white p-6 rounded-2xl shadow border border-gray-200 h-[360px]"><h2 class="text-lg font-semibold mb-2">📈 Umsatztrend (Umsatz/Storno)</h2><canvas ref="trendCanvas" class="h-[290px]"></canvas></div>
        <div class="bg-white p-6 rounded-2xl shadow border border-gray-200 h-[360px]"><h2 class="text-lg font-semibold mb-2">🧩 Kategorien-Anteil (Umsatz)</h2><canvas ref="categoryCanvas" class="h-[290px]"></canvas></div>
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <div class="bg-white p-6 rounded-2xl shadow border border-gray-200">
          <div class="flex items-center justify-between mb-4"><h2 class="text-lg font-semibold">🥇 Top-Produkte nach Netto-Menge</h2><button class="text-xs px-2 py-1 rounded border border-emerald-200 text-emerald-700 hover:bg-emerald-50" @click="goToRevenue()">Details</button></div>
          <div class="space-y-3">
            <div v-for="(row, idx) in topProducts" :key="row.product_key ?? row.product_name ?? row.product ?? idx" class="rounded-xl border border-gray-200 p-3 bg-gradient-to-r from-white to-gray-50/80">
              <div class="flex items-center justify-between gap-3 mb-2"><div class="flex items-center gap-2 min-w-0"><span class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-primary/10 text-primary text-xs font-semibold">{{ idx + 1 }}</span><span class="font-medium text-gray-800 truncate">{{ row.product_name || row.product }}</span></div><div class="text-sm font-semibold whitespace-nowrap" :class="row.net_quantity >= 0 ? 'text-emerald-700' : 'text-rose-700'">{{ row.net_quantity }} netto</div></div>
              <div class="h-2.5 rounded-full bg-slate-100 overflow-hidden"><div class="h-full rounded-full transition-all duration-500" :style="productBarStyle(row.net_quantity)"></div></div>
              <div class="mt-2 flex items-center justify-between text-xs text-gray-500"><span>{{ row.bookings }} Buchungen · {{ row.cancellations }} Stornos · {{ euro(row.gross_profit ?? (row.revenue - row.canceled)) }} Rohgewinn</span><span>{{ productSharePercent(row.net_quantity).toFixed(1) }}% Anteil</span></div>
            </div>
            <div v-if="topProducts.length === 0" class="text-sm text-gray-400 italic py-8 text-center">Keine Produktdaten im Zeitraum</div>
          </div>
        </div>

        <div class="bg-white p-6 rounded-2xl shadow border border-gray-200">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-semibold">🕒 Aktivitäts-Heatmap</h2>
            <div class="flex flex-wrap items-center justify-end gap-2">
              <div class="inline-flex max-w-full rounded-lg border border-gray-200 overflow-hidden">
                <button v-for="opt in heatAggregationOptionsVisible" :key="opt.value" type="button" class="px-2 py-1 text-[11px] transition whitespace-nowrap" :class="[heatAggregationMode === opt.value ? 'bg-primary text-white' : 'bg-white text-gray-600 hover:bg-gray-50', opt.value !== heatAggregationOptionsVisible[0].value ? 'border-l border-gray-200' : '']" @click="heatAggregationMode = opt.value">{{ opt.label }}</button>
              </div>
              <span class="text-xs text-gray-500">Montag bis Sonntag, 0-23 Uhr</span>
            </div>
          </div>
          <div class="rounded-xl border border-gray-100 p-2">
            <div class="grid grid-cols-[32px_repeat(24,minmax(0,1fr))] gap-0 mb-1"><div></div><div v-for="hour in 24" :key="`hour-${hour - 1}`" class="text-[9px] text-center text-gray-400">{{ (hour - 1) % 2 === 0 ? (hour - 1).toString().padStart(2, "0") : "" }}</div></div>
            <div v-for="row in heatGrid" :key="`day-${row.day}`" class="grid grid-cols-[32px_repeat(24,minmax(0,1fr))] gap-0 mb-[2px] items-center">
              <div class="text-[11px] font-medium text-gray-600">{{ row.label }}</div>
              <div v-for="cell in row.cells" :key="`cell-${cell.day}-${cell.hour}`" class="h-5 sm:h-6 rounded-[2px] transition-colors duration-200" :style="heatCellStyle(cell.count)" :title="heatCellTitle(cell.day, cell.hour, cell.count)"></div>
            </div>
            <div class="mt-3 flex items-center gap-2"><span class="text-[11px] text-gray-500">Wenig</span><div class="h-2.5 flex-1 rounded-full bg-gradient-to-r from-gray-200 via-amber-300 to-red-600"></div><span class="text-[11px] text-gray-500">Viel</span></div>
          </div>
        </div>
      </div>

      <div class="flex flex-wrap gap-3">
        <RouterLink to="/admin/revenue-report" class="px-4 py-2 rounded-lg bg-primary text-white hover:bg-primary/90 transition">Zum Umsatzreport</RouterLink>
        <RouterLink to="/admin/bookings-report" class="px-4 py-2 rounded-lg bg-white border border-gray-300 text-gray-700 hover:bg-gray-50 transition">Zur Buchungsübersicht</RouterLink>
        <RouterLink to="/admin/cancellations-report" class="px-4 py-2 rounded-lg bg-white border border-gray-300 text-gray-700 hover:bg-gray-50 transition">Zum Storno-Report</RouterLink>
      </div>
    </div>
  </div>
</template>
