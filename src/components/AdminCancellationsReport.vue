<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { onMounted } from "vue";
import { useRoute } from "vue-router";
import { useToast } from "@/composables/useToast";
import Datepicker from "@vuepic/vue-datepicker";
import "@vuepic/vue-datepicker/dist/main.css";
import { adminRpc } from "@/lib/adminApi";
import { exportReportAsPdf } from "@/utils/reportExport";

type CancellationRow = {
  canceled_at: string;
  local_day: string;
  original_transaction_id: string;
  transaction_created_at: string;
  member_id: string | null;
  member_name: string;
  product_id: string | null;
  product_name: string;
  device_name: string;
  amount: number;
  note: string | null;
};

const { show: showToast } = useToast();
const route = useRoute();

const loading = ref(false);
const error = ref<string | null>(null);
const rows = ref<CancellationRow[]>([]);

const selectedMemberId = ref<string>("");
const selectedProductId = ref<string>("");

const today = new Date();
const sevenDaysAgo = new Date();
sevenDaysAgo.setDate(today.getDate() - 7);
const startDate = ref<Date>(sevenDaysAgo);
const endDate = ref<Date>(today);
const suppressDateReload = ref(false);

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
  const qProduct = queryValue(route.query.product_id);

  if (qStart) {
    const d = new Date(qStart);
    if (!Number.isNaN(d.getTime())) startDate.value = d;
  }
  if (qEnd) {
    const d = new Date(qEnd);
    if (!Number.isNaN(d.getTime())) endDate.value = d;
  }
  if (qMember) selectedMemberId.value = qMember;
  if (qProduct) selectedProductId.value = qProduct;
}

const memberOptions = computed(() => {
  const map = new Map<string, string>();
  for (const row of rows.value) {
    if (!row.member_id) continue;
    if (!map.has(row.member_id)) map.set(row.member_id, row.member_name);
  }
  return Array.from(map.entries())
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name, "de"));
});

const productOptions = computed(() => {
  const map = new Map<string, string>();
  for (const row of rows.value) {
    if (!row.product_id) continue;
    if (!map.has(row.product_id)) map.set(row.product_id, row.product_name);
  }
  return Array.from(map.entries())
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name, "de"));
});

const filteredRows = computed(() =>
  rows.value.filter((row) => {
    const matchesMember = !selectedMemberId.value || row.member_id === selectedMemberId.value;
    const matchesProduct = !selectedProductId.value || row.product_id === selectedProductId.value;
    return matchesMember && matchesProduct;
  }),
);

const cancellationCount = computed(() => filteredRows.value.length);
const totalAmountEuro = computed(
  () => filteredRows.value.reduce((sum, row) => sum + Math.abs(Number(row.amount ?? 0)), 0) / 100,
);

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

    const data = await adminRpc("get_cancellations_report_period", {
      start: startISO,
      end: endISOExclusive.toISOString(),
    });

    rows.value = ((data as any[]) ?? []).map((row: any) => ({
      canceled_at: row.canceled_at,
      local_day: row.local_day,
      original_transaction_id: row.original_transaction_id,
      transaction_created_at: row.transaction_created_at,
      member_id: row.member_id ?? null,
      member_name: row.member_name ?? "Unbekanntes Mitglied",
      product_id: row.product_id ?? null,
      product_name: row.product_name ?? "Freier Betrag",
      device_name: row.device_name ?? "-",
      amount: Number(row.amount ?? 0),
      note: row.note ?? null,
    }));

    showToast("✅ Storno-Report geladen");
  } catch (err) {
    console.error("[AdminCancellationsReport]", err);
    error.value = "Fehler beim Laden des Storno-Reports";
    showToast("⚠️ Fehler beim Laden des Storno-Reports");
  } finally {
    loading.value = false;
  }
}

onMounted(async () => {
  suppressDateReload.value = true;
  applyQueryFilters();
  suppressDateReload.value = false;
  await loadReport();
});

watch([startDate, endDate], async () => {
  if (suppressDateReload.value) return;
  if (!startDate.value || !endDate.value) return;
  await loadReport();
});

async function exportPdf() {
  try {
    await exportReportAsPdf("admin-cancellations-report", "Storno-Report");
  } catch (err) {
    console.error("[AdminCancellationsReport.exportPdf]", err);
    showToast("⚠️ PDF-Export fehlgeschlagen");
  }
}
</script>

<template>
  <div class="space-y-6" data-report-id="admin-cancellations-report">
    <div class="flex justify-between items-center">
      <h2 class="text-xl font-semibold text-primary">↩️ Storno-Report</h2>
      <div class="flex items-center gap-3 no-print">
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

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 flex flex-wrap gap-4 items-end">
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
        <label class="block text-sm font-medium text-gray-600 mb-1">Produkt</label>
        <select
          v-model="selectedProductId"
          class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"
        >
          <option value="">Alle Produkte</option>
          <option v-for="product in productOptions" :key="product.id" :value="product.id">
            {{ product.name }}
          </option>
        </select>
      </div>

      <button
        @click="loadReport"
        class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition"
      >
        Bericht laden
      </button>
    </div>

    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Stornos</div>
        <div class="text-2xl font-semibold text-primary">{{ cancellationCount }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Stornierter Betrag</div>
        <div class="text-2xl font-semibold text-primary">{{ totalAmountEuro.toFixed(2) }} €</div>
      </div>
    </div>

    <div v-if="loading" class="text-center py-10 text-gray-500">
      ⏳ Storno-Report wird geladen...
    </div>
    <div v-else-if="error" class="text-center py-10 text-red-500">
      {{ error }}
    </div>

    <div v-else class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200">
      <table class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Storno-Zeitpunkt</th>
            <th class="px-4 py-3 text-left">Ursprungsbuchung</th>
            <th class="px-4 py-3 text-left">Mitglied</th>
            <th class="px-4 py-3 text-left">Produkt</th>
            <th class="px-4 py-3 text-left">Device</th>
            <th class="px-4 py-3 text-right">Betrag (€)</th>
            <th class="px-4 py-3 text-left">Notiz</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="row in filteredRows"
            :key="row.original_transaction_id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">{{ new Date(row.canceled_at).toLocaleString("de-DE") }}</td>
            <td class="px-4 py-2">{{ new Date(row.transaction_created_at).toLocaleString("de-DE") }}</td>
            <td class="px-4 py-2">{{ row.member_name }}</td>
            <td class="px-4 py-2">{{ row.product_name }}</td>
            <td class="px-4 py-2">{{ row.device_name }}</td>
            <td class="px-4 py-2 text-right font-semibold text-red-700">
              {{ (Math.abs(row.amount) / 100).toFixed(2) }}
            </td>
            <td class="px-4 py-2">{{ row.note || "-" }}</td>
          </tr>
          <tr v-if="filteredRows.length === 0">
            <td colspan="7" class="text-center py-6 text-gray-400 italic">
              Keine Stornos im gewählten Zeitraum
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
