<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useToast } from "@/composables/useToast";
import Datepicker from "@vuepic/vue-datepicker";
import "@vuepic/vue-datepicker/dist/main.css";
import { adminRpc } from "@/lib/adminApi";
import { exportReportAsPdf } from "@/utils/reportExport";

type FridgeRefillRow = {
  created_at: string;
  local_day: string;
  stock_adjustment_id: string;
  product_id: string | null;
  product_name: string;
  product_category: string;
  quantity: number;
  member_id: string | null;
  member_name: string;
  device_id: string | null;
  device_name: string | null;
  note: string | null;
};

const { show: showToast } = useToast();

const loading = ref(false);
const error = ref<string | null>(null);
const rows = ref<FridgeRefillRow[]>([]);

const today = new Date();
const sevenDaysAgo = new Date();
sevenDaysAgo.setDate(today.getDate() - 7);
const startDate = ref<Date>(sevenDaysAgo);
const endDate = ref<Date>(today);

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

const totalQty = computed(() =>
  rows.value.reduce((sum, row) => sum + Number(row.quantity ?? 0), 0)
);

const refillCount = computed(() => rows.value.length);

const uniqueProducts = computed(() => {
  const s = new Set(rows.value.map((r) => r.product_id ?? r.product_name));
  return s.size;
});

const uniqueRefillers = computed(() => {
  const s = new Set(rows.value.map((r) => r.member_id ?? r.member_name));
  return s.size;
});

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

    const data = await adminRpc("get_fridge_refills_period", {
      start: startISO,
      end: endISOExclusive.toISOString(),
    });

    rows.value = ((data as any[]) ?? []).map((row: any) => ({
      created_at: row.created_at,
      local_day: row.local_day,
      stock_adjustment_id: row.stock_adjustment_id,
      product_id: row.product_id ?? null,
      product_name: row.product_name ?? "Unbekanntes Produkt",
      product_category: row.product_category ?? "-",
      quantity: Number(row.quantity ?? 0),
      member_id: row.member_id ?? null,
      member_name: row.member_name ?? "Unbekannt",
      device_id: row.device_id ?? null,
      device_name: row.device_name ?? null,
      note: row.note ?? null,
    }));

    showToast("✅ Auffüllbericht geladen");
  } catch (err) {
    console.error("[AdminFridgeRefillsReport]", err);
    error.value = "Fehler beim Laden des Auffüllberichts";
    showToast("⚠️ Fehler beim Laden des Berichts");
  } finally {
    loading.value = false;
  }
}

loadReport();

watch([startDate, endDate], async () => {
  if (!startDate.value || !endDate.value) return;
  await loadReport();
});

async function exportPdf() {
  try {
    await exportReportAsPdf("admin-fridge-refills-report", "Kuehlschrank-Auffuellungen");
  } catch (err) {
    console.error("[AdminFridgeRefillsReport.exportPdf]", err);
    showToast("⚠️ PDF-Export fehlgeschlagen");
  }
}
</script>

<template>
  <div class="space-y-6" data-report-id="admin-fridge-refills-report">
    <div class="flex flex-col lg:flex-row justify-between items-start lg:items-center gap-3">
      <h2 class="text-xl font-semibold text-primary">🧊 Kühlschrank-Auffüllungen</h2>
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

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4 items-end">
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

      <div class="xl:self-end">
        <button
          @click="loadReport"
          class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition w-full"
        >
          Bericht laden
        </button>
      </div>
    </div>

    <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Auffüllvorgänge</div>
        <div class="text-2xl font-semibold text-primary">{{ refillCount }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Gesamt Stück</div>
        <div class="text-2xl font-semibold text-primary">{{ totalQty }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Produkte</div>
        <div class="text-2xl font-semibold text-primary">{{ uniqueProducts }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Auffüller</div>
        <div class="text-2xl font-semibold text-primary">{{ uniqueRefillers }}</div>
      </div>
    </div>

    <div v-if="loading" class="text-center py-10 text-gray-500">
      ⏳ Bericht wird geladen...
    </div>
    <div v-else-if="error" class="text-center py-10 text-red-500">
      {{ error }}
    </div>

    <div v-else class="space-y-4">
      <div class="lg:hidden space-y-3">
        <div
          v-for="row in rows"
          :key="row.stock_adjustment_id"
          class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <div class="text-base font-semibold text-gray-900">{{ row.product_name }}</div>
              <div class="text-sm text-gray-500 mt-1">{{ row.product_category }}</div>
            </div>
            <div class="text-sm font-semibold text-emerald-700">+{{ row.quantity }}</div>
          </div>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 text-sm text-gray-600">
            <div>{{ new Date(row.created_at).toLocaleString("de-DE") }}</div>
            <div>{{ formatDayKey(row.local_day) }}</div>
            <div>Auffüller: {{ row.member_name }}</div>
            <div>Gerät: {{ row.device_name || "-" }}</div>
            <div class="sm:col-span-2">Notiz: {{ row.note || "-" }}</div>
          </div>
        </div>
        <div v-if="rows.length === 0" class="bg-white rounded-2xl shadow border border-gray-200 p-6 text-center text-gray-400 italic">
          Keine Kühlschrank-Auffüllungen im gewählten Zeitraum
        </div>
      </div>

      <div class="hidden lg:block bg-white rounded-2xl shadow overflow-x-auto border border-gray-200">
      <table class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Zeitpunkt</th>
            <th class="px-4 py-3 text-left">Tag</th>
            <th class="px-4 py-3 text-left">Produkt</th>
            <th class="px-4 py-3 text-left">Kategorie</th>
            <th class="px-4 py-3 text-right">Menge</th>
            <th class="px-4 py-3 text-left">Auffüller</th>
            <th class="px-4 py-3 text-left">Gerät</th>
            <th class="px-4 py-3 text-left">Notiz</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="row in rows"
            :key="row.stock_adjustment_id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">{{ new Date(row.created_at).toLocaleString("de-DE") }}</td>
            <td class="px-4 py-2">{{ formatDayKey(row.local_day) }}</td>
            <td class="px-4 py-2">{{ row.product_name }}</td>
            <td class="px-4 py-2">{{ row.product_category }}</td>
            <td class="px-4 py-2 text-right font-semibold text-emerald-700">+{{ row.quantity }}</td>
            <td class="px-4 py-2">{{ row.member_name }}</td>
            <td class="px-4 py-2">{{ row.device_name || "-" }}</td>
            <td class="px-4 py-2">{{ row.note || "-" }}</td>
          </tr>
          <tr v-if="rows.length === 0">
            <td colspan="8" class="text-center py-6 text-gray-400 italic">
              Keine Kühlschrank-Auffüllungen im gewählten Zeitraum
            </td>
          </tr>
        </tbody>
      </table>
      </div>
    </div>
  </div>
</template>
