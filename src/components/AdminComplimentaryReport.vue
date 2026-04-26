<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import Datepicker from "@vuepic/vue-datepicker";
import "@vuepic/vue-datepicker/dist/main.css";
import { adminRpc } from "@/lib/adminApi";
import { fmt } from "@/utils/currency";
import { exportReportAsPdf } from "@/utils/reportExport";

type ComplimentaryRow = {
  event_type: "booking" | "cancellation";
  event_at: string;
  local_day: string;
  member_id: string | null;
  member_name: string;
  product_id: string | null;
  product_name: string;
  product_category: string;
  amount_abs: number;
  cost_amount_abs: number;
  note: string | null;
};

const loading = ref(false);
const error = ref<string | null>(null);
const rows = ref<ComplimentaryRow[]>([]);

const today = new Date();
const sevenDaysAgo = new Date();
sevenDaysAgo.setDate(today.getDate() - 7);
const startDate = ref<Date>(sevenDaysAgo);
const endDate = ref<Date>(today);

const selectedMemberId = ref("");
const selectedCategory = ref("");
const pageSize = 1000;
const maxPages = 200;

function getLocalDayRange(date: Date, isEnd = false) {
  const d = new Date(date);
  if (!isEnd) d.setHours(0, 0, 0, 0);
  else d.setHours(23, 59, 59, 999);
  return d.toISOString();
}

function formatDayKey(day: string) {
  const [y, m, d] = String(day ?? "").split("-");
  if (!y || !m || !d) return day;
  return `${d}.${m}.${y}`;
}

function formatEuroFromCents(cents: number) {
  return fmt(Number(cents || 0) / 100);
}

const filteredRows = computed(() =>
  rows.value.filter((row) => {
    const memberOk = !selectedMemberId.value || row.member_id === selectedMemberId.value;
    const categoryOk = !selectedCategory.value || row.product_category === selectedCategory.value;
    return memberOk && categoryOk;
  }),
);

const bookingRows = computed(() => filteredRows.value.filter((row) => row.event_type === "booking"));
const cancellationRows = computed(() => filteredRows.value.filter((row) => row.event_type === "cancellation"));

const bookingCount = computed(() => bookingRows.value.length);
const cancellationCount = computed(() => cancellationRows.value.length);
const originalValueCents = computed(() =>
  bookingRows.value.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0),
);
const canceledOriginalValueCents = computed(() =>
  cancellationRows.value.reduce((sum, row) => sum + Number(row.amount_abs ?? 0), 0),
);
const goodsCostCents = computed(() =>
  bookingRows.value.reduce((sum, row) => sum + Number(row.cost_amount_abs ?? 0), 0),
);
const canceledGoodsCostCents = computed(() =>
  cancellationRows.value.reduce((sum, row) => sum + Number(row.cost_amount_abs ?? 0), 0),
);

const memberOptions = computed(() => {
  const map = new Map<string, string>();
  for (const row of rows.value) {
    if (row.member_id && !map.has(row.member_id)) map.set(row.member_id, row.member_name);
  }
  return [...map.entries()]
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name, "de-DE"));
});

const categoryOptions = computed(() =>
  [...new Set(rows.value.map((row) => row.product_category || "Unbekannt"))]
    .sort((a, b) => a.localeCompare(b, "de-DE")),
);

const productSummary = computed(() => {
  const map = new Map<string, {
    key: string;
    product_name: string;
    product_category: string;
    bookings: number;
    cancellations: number;
    original_value: number;
    canceled_original_value: number;
    goods_cost: number;
    canceled_goods_cost: number;
  }>();

  for (const row of filteredRows.value) {
    const key = row.product_id ?? `product:${row.product_name}`;
    const current = map.get(key) ?? {
      key,
      product_name: row.product_name || "Unbekannt",
      product_category: row.product_category || "Unbekannt",
      bookings: 0,
      cancellations: 0,
      original_value: 0,
      canceled_original_value: 0,
      goods_cost: 0,
      canceled_goods_cost: 0,
    };

    if (row.event_type === "cancellation") {
      current.cancellations += 1;
      current.canceled_original_value += Number(row.amount_abs ?? 0);
      current.canceled_goods_cost += Number(row.cost_amount_abs ?? 0);
    } else {
      current.bookings += 1;
      current.original_value += Number(row.amount_abs ?? 0);
      current.goods_cost += Number(row.cost_amount_abs ?? 0);
    }
    map.set(key, current);
  }

  return [...map.values()].sort((a, b) =>
    (b.bookings - b.cancellations) - (a.bookings - a.cancellations)
    || b.original_value - a.original_value
    || a.product_name.localeCompare(b.product_name, "de-DE"),
  );
});

const memberSummary = computed(() => {
  const map = new Map<string, {
    key: string;
    member_name: string;
    bookings: number;
    cancellations: number;
    original_value: number;
    goods_cost: number;
  }>();

  for (const row of filteredRows.value) {
    const key = row.member_id ?? row.member_name;
    const current = map.get(key) ?? {
      key,
      member_name: row.member_name || "Unbekannt",
      bookings: 0,
      cancellations: 0,
      original_value: 0,
      goods_cost: 0,
    };
    if (row.event_type === "cancellation") {
      current.cancellations += 1;
      current.original_value -= Number(row.amount_abs ?? 0);
      current.goods_cost -= Number(row.cost_amount_abs ?? 0);
    } else {
      current.bookings += 1;
      current.original_value += Number(row.amount_abs ?? 0);
      current.goods_cost += Number(row.cost_amount_abs ?? 0);
    }
    map.set(key, current);
  }

  return [...map.values()].sort((a, b) =>
    b.original_value - a.original_value || a.member_name.localeCompare(b.member_name, "de-DE"),
  );
});

async function loadReport() {
  if (!startDate.value || !endDate.value) return;
  loading.value = true;
  error.value = null;
  rows.value = [];

  try {
    const startISO = getLocalDayRange(startDate.value, false);
    const endISOExclusive = new Date(getLocalDayRange(endDate.value, true));
    endISOExclusive.setMilliseconds(endISOExclusive.getMilliseconds() + 1);

    const chunks: any[] = [];
    let offset = 0;
    for (let page = 0; page < maxPages; page += 1) {
      const data = await adminRpc("get_complimentary_report_period", {
        start: startISO,
        end: endISOExclusive.toISOString(),
        limit: pageSize,
        offset,
      });
      const batch = Array.isArray(data) ? data : [];
      chunks.push(...batch);
      if (batch.length < pageSize) break;
      offset += pageSize;
    }

    rows.value = chunks
      .map((row) => ({
        event_type: row.event_type === "cancellation" ? "cancellation" : "booking",
        event_at: row.event_at,
        local_day: row.local_day,
        member_id: row.member_id ?? null,
        member_name: row.member_name ?? "Unbekanntes Mitglied",
        product_id: row.product_id ?? null,
        product_name: row.product_name ?? "Unbekanntes Produkt",
        product_category: row.product_category ?? "Unbekannt",
        amount_abs: Number(row.amount_abs ?? 0),
        cost_amount_abs: Number(row.cost_amount_abs ?? row.product_cost_snapshot_cents ?? 0),
        note: row.note ?? null,
      }));
  } catch (e: any) {
    console.error("[AdminComplimentaryReport]", e);
    error.value = e?.message || "Freigetränke-Report konnte nicht geladen werden.";
  } finally {
    loading.value = false;
  }
}

async function exportPdf() {
  await exportReportAsPdf("admin-complimentary-report", "Freigetraenke-Report");
}

onMounted(loadReport);
</script>

<template>
  <div class="space-y-6" data-report-id="admin-complimentary-report">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div>
        <h2 class="text-2xl font-bold text-primary">Freigetränke-Report</h2>
        <p class="text-sm text-gray-500">
          Als Freigetränke abgerechnete Produktbuchungen ohne Umsatz- und Gewinnwirkung.
        </p>
      </div>
      <button
        @click="exportPdf"
        class="button-outline-strong rounded-lg border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
      >
        PDF exportieren
      </button>
    </div>

    <div class="flex flex-wrap items-end gap-3 rounded-2xl border border-gray-200 bg-white p-4 shadow-sm">
      <div>
        <label class="mb-1 block text-sm font-medium text-gray-600">Start</label>
        <Datepicker v-model="startDate" locale="de" :enable-time-picker="false" format="dd.MM.yyyy" />
      </div>
      <div>
        <label class="mb-1 block text-sm font-medium text-gray-600">Ende</label>
        <Datepicker v-model="endDate" locale="de" :enable-time-picker="false" format="dd.MM.yyyy" />
      </div>
      <button
        @click="loadReport"
        class="button-outline-strong h-[38px] rounded-lg border-blue-800 bg-primary px-4 text-sm font-semibold text-white hover:bg-blue-800"
      >
        Aktualisieren
      </button>
      <div>
        <label class="mb-1 block text-sm font-medium text-gray-600">Gastkonto</label>
        <select v-model="selectedMemberId" class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3">
          <option value="">Alle Gäste</option>
          <option v-for="member in memberOptions" :key="member.id" :value="member.id">
            {{ member.name }}
          </option>
        </select>
      </div>
      <div>
        <label class="mb-1 block text-sm font-medium text-gray-600">Kategorie</label>
        <select v-model="selectedCategory" class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3">
          <option value="">Alle Kategorien</option>
          <option v-for="category in categoryOptions" :key="category" :value="category">
            {{ category }}
          </option>
        </select>
      </div>
    </div>

    <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
      <div class="rounded-xl border border-gray-200 bg-white p-4">
        <div class="text-xs uppercase text-gray-500">Buchungen</div>
        <div class="text-2xl font-semibold text-primary">{{ bookingCount }}</div>
      </div>
      <div class="rounded-xl border border-gray-200 bg-white p-4">
        <div class="text-xs uppercase text-gray-500">Stornos</div>
        <div class="text-2xl font-semibold text-primary">{{ cancellationCount }}</div>
      </div>
      <div class="rounded-xl border border-gray-200 bg-white p-4">
        <div class="text-xs uppercase text-gray-500">Ursprünglicher Preis</div>
        <div class="text-2xl font-semibold text-primary">{{ formatEuroFromCents(originalValueCents - canceledOriginalValueCents) }}</div>
      </div>
      <div class="rounded-xl border border-gray-200 bg-white p-4">
        <div class="text-xs uppercase text-gray-500">Warenwert</div>
        <div class="text-2xl font-semibold text-amber-700">{{ formatEuroFromCents(goodsCostCents - canceledGoodsCostCents) }}</div>
      </div>
    </div>

    <div v-if="loading" class="py-10 text-center text-gray-500">Freigetränke-Report wird geladen...</div>
    <div v-else-if="error" class="py-10 text-center text-red-600">{{ error }}</div>

    <div v-else class="space-y-6">
      <div class="overflow-x-auto rounded-2xl border border-gray-200 bg-white shadow">
        <h3 class="px-4 pt-4 font-semibold text-primary">Nach Produkt</h3>
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-primary/10 text-xs font-semibold uppercase text-primary">
            <tr>
              <th class="px-4 py-3 text-left">Kategorie</th>
              <th class="px-4 py-3 text-left">Produkt</th>
              <th class="px-4 py-3 text-right">Buchungen</th>
              <th class="px-4 py-3 text-right">Stornos</th>
              <th class="px-4 py-3 text-right">Netto-Menge</th>
              <th class="px-4 py-3 text-right">Urspr. Preis</th>
              <th class="px-4 py-3 text-right">Warenwert</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in productSummary" :key="row.key" class="border-t hover:bg-primary/5">
              <td class="px-4 py-2">{{ row.product_category }}</td>
              <td class="px-4 py-2">{{ row.product_name }}</td>
              <td class="px-4 py-2 text-right">{{ row.bookings }}</td>
              <td class="px-4 py-2 text-right">{{ row.cancellations }}</td>
              <td class="px-4 py-2 text-right font-semibold">{{ row.bookings - row.cancellations }}</td>
              <td class="px-4 py-2 text-right">{{ formatEuroFromCents(row.original_value - row.canceled_original_value) }}</td>
              <td class="px-4 py-2 text-right">{{ formatEuroFromCents(row.goods_cost - row.canceled_goods_cost) }}</td>
            </tr>
            <tr v-if="productSummary.length === 0">
              <td colspan="7" class="py-6 text-center text-gray-400">Keine Freigetränke im gewählten Zeitraum</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="overflow-x-auto rounded-2xl border border-gray-200 bg-white shadow">
        <h3 class="px-4 pt-4 font-semibold text-primary">Nach Gastkonto</h3>
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-primary/10 text-xs font-semibold uppercase text-primary">
            <tr>
              <th class="px-4 py-3 text-left">Gastkonto</th>
              <th class="px-4 py-3 text-right">Buchungen</th>
              <th class="px-4 py-3 text-right">Stornos</th>
              <th class="px-4 py-3 text-right">Urspr. Preis</th>
              <th class="px-4 py-3 text-right">Warenwert</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in memberSummary" :key="row.key" class="border-t hover:bg-primary/5">
              <td class="px-4 py-2">{{ row.member_name }}</td>
              <td class="px-4 py-2 text-right">{{ row.bookings }}</td>
              <td class="px-4 py-2 text-right">{{ row.cancellations }}</td>
              <td class="px-4 py-2 text-right">{{ formatEuroFromCents(row.original_value) }}</td>
              <td class="px-4 py-2 text-right">{{ formatEuroFromCents(row.goods_cost) }}</td>
            </tr>
            <tr v-if="memberSummary.length === 0">
              <td colspan="5" class="py-6 text-center text-gray-400">Keine Freigetränke im gewählten Zeitraum</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="overflow-x-auto rounded-2xl border border-gray-200 bg-white shadow">
        <h3 class="px-4 pt-4 font-semibold text-primary">Details</h3>
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-primary/10 text-xs font-semibold uppercase text-primary">
            <tr>
              <th class="px-4 py-3 text-left">Zeitpunkt</th>
              <th class="px-4 py-3 text-left">Tag</th>
              <th class="px-4 py-3 text-left">Gastkonto</th>
              <th class="px-4 py-3 text-left">Produkt</th>
              <th class="px-4 py-3 text-left">Kategorie</th>
              <th class="px-4 py-3 text-right">Urspr. Preis</th>
              <th class="px-4 py-3 text-right">Warenwert</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in filteredRows" :key="`${row.event_type}-${row.event_at}-${row.member_id}-${row.product_id}`" class="border-t hover:bg-primary/5">
              <td class="px-4 py-2">{{ new Date(row.event_at).toLocaleString("de-DE") }}</td>
              <td class="px-4 py-2">{{ formatDayKey(row.local_day) }}</td>
              <td class="px-4 py-2">{{ row.member_name }}</td>
              <td class="px-4 py-2">{{ row.product_name }}</td>
              <td class="px-4 py-2">{{ row.product_category }}</td>
              <td class="px-4 py-2 text-right">{{ formatEuroFromCents(row.amount_abs) }}</td>
              <td class="px-4 py-2 text-right">{{ formatEuroFromCents(row.cost_amount_abs) }}</td>
            </tr>
            <tr v-if="filteredRows.length === 0">
              <td colspan="7" class="py-6 text-center text-gray-400">Keine Freigetränke im gewählten Zeitraum</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>
