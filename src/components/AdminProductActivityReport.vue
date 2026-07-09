<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import Datepicker from "@vuepic/vue-datepicker";
import DateRangeQuickSelect from "@/components/DateRangeQuickSelect.vue";
import "@vuepic/vue-datepicker/dist/main.css";
import { adminRpc } from "@/lib/adminApi";
import { fmt } from "@/utils/currency";
import { useToast } from "@/composables/useToast";
import { exportReportAsPdf } from "@/utils/reportExport";

type SortKey = "sold_count" | "mhd_count" | "current_stock" | "stock_delta_period" | "revenue_cents" | "gross_profit_cents" | "name";

type ProductRow = {
  product_id: string;
  name: string;
  category: string;
  active: boolean;
  inventoried: boolean;
  sold_count: number;
  mhd_count: number;
  mhd_share_percent: number;
  revenue_cents: number;
  goods_cost_cents: number;
  gross_profit_cents: number;
  current_stock: number;
  current_stock_value_cents: number;
  stock_delta_period: number;
  last_purchase_price_cents: number;
};

type StockTrendRow = {
  product_id: string;
  day: string;
  stock: number;
};

type Metrics = {
  totalSoldCount: number;
  totalMhdCount: number;
  mhdSharePercent: number;
  totalRevenueCents: number;
  totalGoodsCostCents: number;
  totalGrossProfitCents: number;
  grossMarginPercent: number;
  soldProductsCount: number;
  currentStockUnits: number;
  currentStockValueCents: number;
};

const { show: showToast } = useToast();
const loading = ref(false);
const error = ref<string | null>(null);

const today = new Date();
const start = new Date();
start.setDate(today.getDate() - 30);
const startDate = ref<Date>(start);
const endDate = ref<Date>(today);

const selectedCategory = ref("");
const stockOnly = ref(false);
const sortKey = ref<SortKey>("sold_count");
const sortDir = ref<"asc" | "desc">("desc");

const metrics = ref<Metrics>({
  totalSoldCount: 0,
  totalMhdCount: 0,
  mhdSharePercent: 0,
  totalRevenueCents: 0,
  totalGoodsCostCents: 0,
  totalGrossProfitCents: 0,
  grossMarginPercent: 0,
  soldProductsCount: 0,
  currentStockUnits: 0,
  currentStockValueCents: 0,
});
const products = ref<ProductRow[]>([]);
const stockTrend = ref<StockTrendRow[]>([]);

const salesCanvas = ref<HTMLCanvasElement | null>(null);
const stockCanvas = ref<HTMLCanvasElement | null>(null);
let Chart: any = null;
let salesChart: any = null;
let stockChart: any = null;

const categoryOptions = computed(() =>
  Array.from(new Set(products.value.map((p) => p.category || "Allgemein"))).sort((a, b) => a.localeCompare(b, "de"))
);

function sortValue(row: ProductRow, key: SortKey) {
  if (key === "name") return row.name;
  return row[key];
}

const filteredProducts = computed(() => {
  const rows = products.value.filter((p) => {
    if (selectedCategory.value && p.category !== selectedCategory.value) return false;
    if (stockOnly.value && !p.inventoried) return false;
    return true;
  });
  return [...rows].sort((a, b) => {
    const dir = sortDir.value === "asc" ? 1 : -1;
    if (sortKey.value === "name") return a.name.localeCompare(b.name, "de") * dir;
    return ((Number(sortValue(a, sortKey.value) ?? 0) - Number(sortValue(b, sortKey.value) ?? 0)) * dir) || a.name.localeCompare(b.name, "de");
  });
});

const topSoldProducts = computed(() =>
  [...filteredProducts.value]
    .filter((p) => p.sold_count > 0 || p.mhd_count > 0)
    .sort((a, b) => b.sold_count - a.sold_count || b.mhd_count - a.mhd_count)
    .slice(0, 12)
);

const stockChartProducts = computed(() =>
  [...filteredProducts.value]
    .filter((p) => p.inventoried)
    .sort((a, b) => b.sold_count - a.sold_count || Math.abs(b.stock_delta_period) - Math.abs(a.stock_delta_period))
    .slice(0, 6)
);

const avgMhdPerSoldProduct = computed(() =>
  metrics.value.soldProductsCount > 0 ? metrics.value.totalMhdCount / metrics.value.soldProductsCount : 0
);

function euro(cents: number) {
  return fmt(Number(cents ?? 0) / 100);
}

function getLocalRange(date: Date, isEnd = false) {
  const d = new Date(date);
  if (isEnd) d.setHours(23, 59, 59, 999);
  else d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

function formatDay(value: string) {
  const d = new Date(`${value}T00:00:00`);
  if (Number.isNaN(d.getTime())) return value;
  return d.toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit" });
}

function setSort(key: SortKey) {
  if (sortKey.value === key) sortDir.value = sortDir.value === "asc" ? "desc" : "asc";
  else {
    sortKey.value = key;
    sortDir.value = key === "name" ? "asc" : "desc";
  }
}

function sortMark(key: SortKey) {
  if (sortKey.value !== key) return "";
  return sortDir.value === "asc" ? " ▲" : " ▼";
}

async function initChartJs() {
  if (!Chart) {
    const mod = await import("chart.js/auto");
    Chart = mod.default;
  }
}

function destroyCharts() {
  salesChart?.destroy?.();
  stockChart?.destroy?.();
  salesChart = null;
  stockChart = null;
}

function renderSalesChart() {
  if (!Chart || !salesCanvas.value) return;
  const rows = topSoldProducts.value;
  salesChart = new Chart(salesCanvas.value, {
    type: "bar",
    data: {
      labels: rows.map((p) => p.name),
      datasets: [
        { label: "Verkauft", data: rows.map((p) => p.sold_count), backgroundColor: "rgba(37, 99, 235, 0.78)", borderColor: "#1d4ed8", borderWidth: 1 },
        { label: "MHD", data: rows.map((p) => p.mhd_count), backgroundColor: "rgba(245, 158, 11, 0.78)", borderColor: "#b45309", borderWidth: 1 },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      scales: { y: { beginAtZero: true, ticks: { precision: 0 } } },
      plugins: { legend: { position: "top" } },
    },
  });
}

function renderStockChart() {
  if (!Chart || !stockCanvas.value) return;
  const rows = stockChartProducts.value;
  const ids = new Set(rows.map((p) => p.product_id));
  const labels = Array.from(new Set(stockTrend.value.map((r) => r.day))).sort();
  const byProductDay = new Map<string, number>();
  for (const row of stockTrend.value) {
    if (ids.has(row.product_id)) byProductDay.set(`${row.product_id}|${row.day}`, Number(row.stock ?? 0));
  }
  const palette = ["#2563eb", "#059669", "#dc2626", "#7c3aed", "#0891b2", "#ca8a04"];
  stockChart = new Chart(stockCanvas.value, {
    type: "line",
    data: {
      labels: labels.map(formatDay),
      datasets: rows.map((p, index) => ({
        label: p.name,
        data: labels.map((day) => byProductDay.get(`${p.product_id}|${day}`) ?? null),
        borderColor: palette[index % palette.length],
        backgroundColor: `${palette[index % palette.length]}22`,
        tension: 0.2,
        spanGaps: true,
        pointRadius: labels.length > 45 ? 0 : 2,
      })),
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      scales: { y: { ticks: { precision: 0 } } },
      plugins: { legend: { position: "bottom" } },
    },
  });
}

async function renderCharts() {
  destroyCharts();
  await nextTick();
  await initChartJs();
  renderSalesChart();
  renderStockChart();
}

async function loadReport() {
  loading.value = true;
  error.value = null;
  try {
    const data = await adminRpc("get_product_activity_report", {
      start: getLocalRange(startDate.value),
      end: getLocalRange(endDate.value, true),
    });
    metrics.value = { ...metrics.value, ...(data?.metrics ?? {}) };
    products.value = Array.isArray(data?.products) ? data.products : [];
    stockTrend.value = Array.isArray(data?.stockTrend) ? data.stockTrend : [];
    await renderCharts();
  } catch (err) {
    console.error("[AdminProductActivityReport]", err);
    error.value = err instanceof Error ? err.message : "Fehler beim Laden des Artikelreports";
    showToast("Fehler beim Laden des Artikelreports");
  } finally {
    loading.value = false;
  }
}

function onQuickRange(start: Date, end: Date) {
  startDate.value = start;
  endDate.value = end;
  void loadReport();
}

async function exportPdf() {
  try {
    await exportReportAsPdf("admin-product-activity-report", "Artikelreport");
  } catch (err) {
    console.error("[AdminProductActivityReport.exportPdf]", err);
    showToast("PDF konnte nicht erstellt werden");
  }
}

watch([selectedCategory, stockOnly], () => void renderCharts());
onMounted(loadReport);
onBeforeUnmount(destroyCharts);
</script>

<template>
  <div class="space-y-6" data-report-id="admin-product-activity-report">
    <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm print-card">
      <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <h2 class="text-xl font-semibold text-primary">Artikelreport</h2>
          <p class="mt-1 text-sm text-slate-600">Verkäufe, MHD-Anteil und Lagerbestandsverlauf je Artikel.</p>
        </div>
        <div class="flex flex-wrap gap-2 print:hidden">
          <button type="button" class="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold hover:bg-slate-50" @click="exportPdf">PDF</button>
          <button type="button" class="rounded-xl bg-primary px-4 py-2 text-sm font-semibold text-white hover:bg-primary/90" :disabled="loading" @click="loadReport">Aktualisieren</button>
        </div>
      </div>

      <div class="mt-5 grid gap-3 lg:grid-cols-[1fr_1fr_auto] lg:items-end print:hidden">
        <label class="block">
          <span class="mb-1 block text-xs font-semibold uppercase text-slate-500">Von</span>
          <Datepicker v-model="startDate" :enable-time-picker="false" locale="de" auto-apply format="dd.MM.yyyy" />
        </label>
        <label class="block">
          <span class="mb-1 block text-xs font-semibold uppercase text-slate-500">Bis</span>
          <Datepicker v-model="endDate" :enable-time-picker="false" locale="de" auto-apply format="dd.MM.yyyy" />
        </label>
        <button type="button" class="rounded-xl border border-primary bg-white px-4 py-2 text-sm font-semibold text-primary hover:bg-primary/5" @click="loadReport">Zeitraum laden</button>
      </div>
      <div class="mt-3 print:hidden">
        <DateRangeQuickSelect @select="onQuickRange" />
      </div>
    </section>

    <p v-if="error" class="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm font-semibold text-red-700">{{ error }}</p>

    <section class="grid gap-3 sm:grid-cols-2 xl:grid-cols-5 print-card">
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">Verkaufte Artikel</div>
        <div class="mt-1 text-2xl font-semibold text-primary">{{ metrics.totalSoldCount }}</div>
        <div class="text-xs text-slate-500">{{ metrics.soldProductsCount }} Artikel mit Verkauf</div>
      </div>
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">MHD Buchungen</div>
        <div class="mt-1 text-2xl font-semibold text-amber-700">{{ metrics.totalMhdCount }}</div>
        <div class="text-xs text-slate-500">{{ metrics.mhdSharePercent }}% Anteil</div>
      </div>
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">Umsatz</div>
        <div class="mt-1 text-2xl font-semibold text-primary">{{ euro(metrics.totalRevenueCents) }}</div>
        <div class="text-xs text-slate-500">Wareneinsatz {{ euro(metrics.totalGoodsCostCents) }}</div>
      </div>
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">Rohgewinn</div>
        <div class="mt-1 text-2xl font-semibold" :class="metrics.totalGrossProfitCents >= 0 ? 'text-emerald-700' : 'text-red-700'">{{ euro(metrics.totalGrossProfitCents) }}</div>
        <div class="text-xs text-slate-500">Marge {{ metrics.grossMarginPercent }}%</div>
      </div>
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">Aktueller Bestand</div>
        <div class="mt-1 text-2xl font-semibold text-slate-900">{{ metrics.currentStockUnits }}</div>
        <div class="text-xs text-slate-500">Wert {{ euro(metrics.currentStockValueCents) }}</div>
      </div>
    </section>

    <section class="grid gap-4 xl:grid-cols-2">
      <div class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm print-card">
        <div class="mb-3 flex items-center justify-between gap-3">
          <div>
            <h3 class="font-semibold text-primary">Verkaufte Artikel und MHD</h3>
            <p class="text-xs text-slate-500">Top-Artikel im gewählten Zeitraum.</p>
          </div>
          <span class="rounded-full bg-amber-50 px-3 py-1 text-xs font-semibold text-amber-700">Ø MHD {{ avgMhdPerSoldProduct.toFixed(1) }}</span>
        </div>
        <div class="h-[340px]"><canvas ref="salesCanvas"></canvas></div>
      </div>

      <div class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm print-card">
        <div class="mb-3">
          <h3 class="font-semibold text-primary">Lagerbestandsverlauf</h3>
          <p class="text-xs text-slate-500">Kumulierter Tagesbestand für die meistverkauften inventarisierten Artikel.</p>
        </div>
        <div class="h-[340px]"><canvas ref="stockCanvas"></canvas></div>
      </div>
    </section>

    <section class="rounded-xl border border-slate-200 bg-white shadow-sm print-card">
      <div class="flex flex-col gap-3 border-b border-slate-200 p-4 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h3 class="font-semibold text-primary">Artikelübersicht</h3>
          <p class="text-xs text-slate-500">Sortierbare Detailwerte pro Artikel.</p>
        </div>
        <div class="flex flex-wrap items-center gap-2 print:hidden">
          <select v-model="selectedCategory" class="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
            <option value="">Alle Kategorien</option>
            <option v-for="category in categoryOptions" :key="category" :value="category">{{ category }}</option>
          </select>
          <label class="flex items-center gap-2 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-700">
            <input v-model="stockOnly" type="checkbox" class="accent-primary" />
            Nur Lagerartikel
          </label>
        </div>
      </div>

      <div v-if="loading" class="p-8 text-center text-slate-500">Artikelreport wird geladen...</div>
      <div v-else class="overflow-x-auto">
        <table class="min-w-full text-sm">
          <thead class="bg-slate-100 text-xs uppercase text-primary">
            <tr>
              <th class="px-4 py-3 text-left"><button type="button" @click="setSort('name')">Artikel{{ sortMark('name') }}</button></th>
              <th class="px-4 py-3 text-left">Kategorie</th>
              <th class="px-4 py-3 text-right"><button type="button" @click="setSort('sold_count')">Verkauft{{ sortMark('sold_count') }}</button></th>
              <th class="px-4 py-3 text-right"><button type="button" @click="setSort('mhd_count')">MHD{{ sortMark('mhd_count') }}</button></th>
              <th class="px-4 py-3 text-right">MHD Anteil</th>
              <th class="px-4 py-3 text-right"><button type="button" @click="setSort('revenue_cents')">Umsatz{{ sortMark('revenue_cents') }}</button></th>
              <th class="px-4 py-3 text-right"><button type="button" @click="setSort('gross_profit_cents')">Rohgewinn{{ sortMark('gross_profit_cents') }}</button></th>
              <th class="px-4 py-3 text-right"><button type="button" @click="setSort('current_stock')">Bestand{{ sortMark('current_stock') }}</button></th>
              <th class="px-4 py-3 text-right"><button type="button" @click="setSort('stock_delta_period')">Bestandsänderung{{ sortMark('stock_delta_period') }}</button></th>
              <th class="px-4 py-3 text-right">Bestandswert</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-slate-100">
            <tr v-for="p in filteredProducts" :key="p.product_id" class="hover:bg-slate-50">
              <td class="px-4 py-3 font-semibold text-slate-900">{{ p.name }}</td>
              <td class="px-4 py-3 text-slate-600">{{ p.category }}</td>
              <td class="px-4 py-3 text-right tabular-nums">{{ p.sold_count }}</td>
              <td class="px-4 py-3 text-right tabular-nums font-semibold" :class="p.mhd_count > 0 ? 'text-amber-700' : 'text-slate-500'">{{ p.mhd_count }}</td>
              <td class="px-4 py-3 text-right tabular-nums">{{ p.mhd_share_percent }}%</td>
              <td class="px-4 py-3 text-right tabular-nums">{{ euro(p.revenue_cents) }}</td>
              <td class="px-4 py-3 text-right tabular-nums" :class="p.gross_profit_cents >= 0 ? 'text-emerald-700' : 'text-red-700'">{{ euro(p.gross_profit_cents) }}</td>
              <td class="px-4 py-3 text-right tabular-nums" :class="p.current_stock <= 0 && p.inventoried ? 'text-red-700 font-semibold' : ''">{{ p.inventoried ? p.current_stock : '-' }}</td>
              <td class="px-4 py-3 text-right tabular-nums" :class="p.stock_delta_period < 0 ? 'text-red-700' : p.stock_delta_period > 0 ? 'text-emerald-700' : 'text-slate-500'">{{ p.inventoried ? p.stock_delta_period : '-' }}</td>
              <td class="px-4 py-3 text-right tabular-nums">{{ p.inventoried ? euro(p.current_stock_value_cents) : '-' }}</td>
            </tr>
          </tbody>
        </table>
        <div v-if="!filteredProducts.length" class="p-8 text-center text-slate-500">Keine Artikel im gewählten Zeitraum.</div>
      </div>
    </section>
  </div>
</template>