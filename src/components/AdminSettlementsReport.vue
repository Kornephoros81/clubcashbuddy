<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import Datepicker from "@vuepic/vue-datepicker";
import "@vuepic/vue-datepicker/dist/main.css";
import { useToast } from "@/composables/useToast";
import { adminRpc } from "@/lib/adminApi";
import { fmt } from "@/utils/currency";
import { exportReportAsPdf } from "@/utils/reportExport";

type SettlementRow = {
  settled_at: string;
  local_day: string;
  settlement_id: string;
  member_id: string | null;
  member_name: string;
  user_id: string | null;
  user_name: string;
  amount: number;
};

const { show: showToast } = useToast();

const loading = ref(false);
const error = ref<string | null>(null);
const rows = ref<SettlementRow[]>([]);

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

const totalSettledCents = computed(() =>
  rows.value.reduce((sum, row) => sum + Number(row.amount ?? 0), 0),
);
const settlementsCount = computed(() => rows.value.length);

async function loadReport() {
  if (!startDate.value || !endDate.value) return;

  loading.value = true;
  error.value = null;
  rows.value = [];

  try {
    const startISO = getLocalDayRange(startDate.value, false);
    const endISOExclusive = new Date(getLocalDayRange(endDate.value, true));
    endISOExclusive.setMilliseconds(endISOExclusive.getMilliseconds() + 1);

    const data = await adminRpc("get_settlements_report_period", {
      start: startISO,
      end: endISOExclusive.toISOString(),
    });

    rows.value = ((data as any[]) ?? []).map((row: any) => ({
      settled_at: row.settled_at,
      local_day: row.local_day,
      settlement_id: row.settlement_id,
      member_id: row.member_id ?? null,
      member_name: row.member_name ?? "[Unbekanntes Mitglied]",
      user_id: row.user_id ?? null,
      user_name: row.user_name ?? "[Unbekannter Benutzer]",
      amount: Number(row.amount ?? 0),
    }));

    showToast("✅ Abrechnungsprotokoll geladen");
  } catch (err) {
    console.error("[AdminSettlementsReport]", err);
    error.value = "Fehler beim Laden des Abrechnungsprotokolls";
    showToast("⚠️ Fehler beim Laden des Abrechnungsprotokolls");
  } finally {
    loading.value = false;
  }
}

onMounted(loadReport);

watch([startDate, endDate], async () => {
  if (!startDate.value || !endDate.value) return;
  await loadReport();
});

async function exportPdf() {
  try {
    await exportReportAsPdf("admin-settlements-report", "Abrechnungsprotokoll");
  } catch (err) {
    console.error("[AdminSettlementsReport.exportPdf]", err);
    showToast("⚠️ PDF-Export fehlgeschlagen");
  }
}
</script>

<template>
  <div class="space-y-6" data-report-id="admin-settlements-report">
    <div class="flex flex-col lg:flex-row justify-between items-start lg:items-center gap-3">
      <h2 class="text-xl font-semibold text-primary">📒 Abrechnungsprotokoll</h2>
      <div class="flex flex-col sm:flex-row items-stretch sm:items-center gap-3 no-print w-full lg:w-auto">
        <button
          @click="exportPdf"
          class="text-sm px-3 py-2 rounded-lg border border-gray-300 text-gray-700 hover:bg-gray-50 transition"
        >
          Drucken
        </button>
        <RouterLink to="/admin/dashboard" class="text-sm text-gray-500 hover:text-primary underline">
          ← Zurück zum Dashboard
        </RouterLink>
      </div>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 grid grid-cols-1 md:grid-cols-2 gap-4 items-end">
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
    </div>

    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Abrechnungen</div>
        <div class="text-2xl font-semibold text-primary">{{ settlementsCount }}</div>
      </div>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <div class="text-xs uppercase text-gray-500">Abgerechneter Betrag</div>
        <div class="text-2xl font-semibold text-primary">{{ fmt(totalSettledCents / 100) }}</div>
      </div>
    </div>

    <div v-if="loading" class="text-center py-10 text-gray-500">
      ⏳ Abrechnungsprotokoll wird geladen...
    </div>
    <div v-else-if="error" class="text-center py-10 text-red-500">
      {{ error }}
    </div>

    <div v-else class="space-y-4">
      <div class="lg:hidden space-y-3">
        <div
          v-for="row in rows"
          :key="row.settlement_id"
          class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <div class="text-base font-semibold text-gray-900">{{ row.member_name }}</div>
              <div class="text-sm text-gray-500 mt-1">{{ row.user_name }}</div>
            </div>
            <div class="text-sm font-semibold text-gray-900">{{ (row.amount / 100).toFixed(2) }} €</div>
          </div>
          <div class="text-sm text-gray-600">
            {{ new Date(row.settled_at).toLocaleString("de-DE") }}
          </div>
        </div>
        <div v-if="rows.length === 0" class="bg-white rounded-2xl shadow border border-gray-200 p-6 text-center text-gray-400 italic">
          Keine Abrechnungen im gewählten Zeitraum
        </div>
      </div>

      <div class="hidden lg:block bg-white rounded-2xl shadow overflow-x-auto border border-gray-200">
      <table class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Zeitpunkt</th>
            <th class="px-4 py-3 text-left">Mitglied</th>
            <th class="px-4 py-3 text-left">Durchgeführt von</th>
            <th class="px-4 py-3 text-right">Betrag (€)</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="row in rows"
            :key="row.settlement_id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">{{ new Date(row.settled_at).toLocaleString("de-DE") }}</td>
            <td class="px-4 py-2">{{ row.member_name }}</td>
            <td class="px-4 py-2">{{ row.user_name }}</td>
            <td class="px-4 py-2 text-right font-semibold">{{ (row.amount / 100).toFixed(2) }}</td>
          </tr>
          <tr v-if="rows.length === 0">
            <td colspan="4" class="text-center py-6 text-gray-400 italic">
              Keine Abrechnungen im gewählten Zeitraum
            </td>
          </tr>
        </tbody>
        <tfoot v-if="rows.length > 0">
          <tr class="border-t bg-gray-50 font-semibold text-gray-800">
            <td class="px-4 py-2" colspan="3">Summe</td>
            <td class="px-4 py-2 text-right">{{ (totalSettledCents / 100).toFixed(2) }}</td>
          </tr>
        </tfoot>
      </table>
      </div>
    </div>
  </div>
</template>
