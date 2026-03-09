<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useToast } from "@/composables/useToast";
import Datepicker from "@vuepic/vue-datepicker";
import "@vuepic/vue-datepicker/dist/main.css";
import { adminRpc } from "@/lib/adminApi";
import { exportReportAsPdf } from "@/utils/reportExport";

type AdjustmentRow = {
  created_at: string;
  local_day: string;
  product_id: string;
  product_name: string;
  product_category: string;
  active: boolean;
  location: "warehouse" | "fridge" | "unknown";
  delta: number;
  adjustment_kind: "fehlbestand" | "ueberbestand" | "neutral";
  reason: string;
  note: string | null;
  source: string;
};

const { show: showToast } = useToast();

const loading = ref(false);
const error = ref<string | null>(null);
const rows = ref<AdjustmentRow[]>([]);
const groupBy = ref<"product" | "day">("product");

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

function locationLabel(loc: string): string {
  if (loc === "warehouse") return "Lager";
  if (loc === "fridge") return "Kühlschrank";
  return "Unbekannt";
}

function reasonLabel(reason: string): string {
  if (reason === "count_adjustment") return "Inventurabgleich";
  if (reason === "shrinkage") return "Schwund";
  if (reason === "waste") return "Abfall";
  return reason;
}

function deltaClass(value: number): string {
  if (value < 0) return "text-red-700 font-semibold";
  if (value > 0) return "text-amber-700 font-semibold";
  return "text-green-700";
}

const groupedByProduct = computed(() => {
  const map = new Map<
    string,
    {
      product_id: string;
      product_name: string;
      product_category: string;
      fehlbestand: number;
      ueberbestand: number;
      fridge_delta: number;
      warehouse_delta: number;
      adjustments_count: number;
      last_adjustment_at: string;
    }
  >();

  for (const row of rows.value) {
    const key = row.product_id;
    const existing = map.get(key);
    if (!existing) {
      map.set(key, {
        product_id: row.product_id,
        product_name: row.product_name,
        product_category: row.product_category,
        fehlbestand: row.delta < 0 ? Math.abs(row.delta) : 0,
        ueberbestand: row.delta > 0 ? row.delta : 0,
        fridge_delta: row.location === "fridge" ? row.delta : 0,
        warehouse_delta: row.location === "warehouse" ? row.delta : 0,
        adjustments_count: 1,
        last_adjustment_at: row.created_at,
      });
      continue;
    }
    if (row.delta < 0) existing.fehlbestand += Math.abs(row.delta);
    if (row.delta > 0) existing.ueberbestand += row.delta;
    if (row.location === "fridge") existing.fridge_delta += row.delta;
    if (row.location === "warehouse") existing.warehouse_delta += row.delta;
    existing.adjustments_count += 1;
    if (new Date(row.created_at).getTime() > new Date(existing.last_adjustment_at).getTime()) {
      existing.last_adjustment_at = row.created_at;
    }
  }

  return [...map.values()].sort((a, b) => {
    const scoreA = a.fehlbestand + a.ueberbestand;
    const scoreB = b.fehlbestand + b.ueberbestand;
    if (scoreB !== scoreA) return scoreB - scoreA;
    return a.product_name.localeCompare(b.product_name, "de-DE");
  });
});

const groupedByDay = computed(() => {
  const map = new Map<
    string,
    {
      day: string;
      fehlbestand: number;
      ueberbestand: number;
      fridge_delta: number;
      warehouse_delta: number;
      adjustments_count: number;
      products_count: number;
    }
  >();
  const dayProducts = new Map<string, Set<string>>();

  for (const row of rows.value) {
    const day = row.local_day;
    if (!dayProducts.has(day)) dayProducts.set(day, new Set<string>());
    dayProducts.get(day)?.add(row.product_id);

    const existing = map.get(day);
    if (!existing) {
      map.set(day, {
        day,
        fehlbestand: row.delta < 0 ? Math.abs(row.delta) : 0,
        ueberbestand: row.delta > 0 ? row.delta : 0,
        fridge_delta: row.location === "fridge" ? row.delta : 0,
        warehouse_delta: row.location === "warehouse" ? row.delta : 0,
        adjustments_count: 1,
        products_count: 0,
      });
      continue;
    }
    if (row.delta < 0) existing.fehlbestand += Math.abs(row.delta);
    if (row.delta > 0) existing.ueberbestand += row.delta;
    if (row.location === "fridge") existing.fridge_delta += row.delta;
    if (row.location === "warehouse") existing.warehouse_delta += row.delta;
    existing.adjustments_count += 1;
  }

  for (const [day, set] of dayProducts.entries()) {
    const existing = map.get(day);
    if (existing) existing.products_count = set.size;
  }

  return [...map.values()].sort((a, b) => b.day.localeCompare(a.day));
});

const totalsByProduct = computed(() => {
  return groupedByProduct.value.reduce(
    (acc, row) => {
      acc.adjustments_count += row.adjustments_count;
      acc.fehlbestand += row.fehlbestand;
      acc.ueberbestand += row.ueberbestand;
      acc.fridge_delta += row.fridge_delta;
      acc.warehouse_delta += row.warehouse_delta;
      return acc;
    },
    {
      adjustments_count: 0,
      fehlbestand: 0,
      ueberbestand: 0,
      fridge_delta: 0,
      warehouse_delta: 0,
    },
  );
});

const totalsByDay = computed(() => {
  return groupedByDay.value.reduce(
    (acc, row) => {
      acc.adjustments_count += row.adjustments_count;
      acc.products_count += row.products_count;
      acc.fehlbestand += row.fehlbestand;
      acc.ueberbestand += row.ueberbestand;
      acc.fridge_delta += row.fridge_delta;
      acc.warehouse_delta += row.warehouse_delta;
      return acc;
    },
    {
      adjustments_count: 0,
      products_count: 0,
      fehlbestand: 0,
      ueberbestand: 0,
      fridge_delta: 0,
      warehouse_delta: 0,
    },
  );
});

const drilldownProductToDays = computed(() => {
  const root = new Map<
    string,
    Map<string, { day: string; fehlbestand: number; ueberbestand: number; adjustments_count: number }>
  >();

  for (const row of rows.value) {
    if (!root.has(row.product_id)) root.set(row.product_id, new Map());
    const dayMap = root.get(row.product_id)!;
    const existing = dayMap.get(row.local_day);
    if (!existing) {
      dayMap.set(row.local_day, {
        day: row.local_day,
        fehlbestand: row.delta < 0 ? Math.abs(row.delta) : 0,
        ueberbestand: row.delta > 0 ? row.delta : 0,
        adjustments_count: 1,
      });
      continue;
    }
    if (row.delta < 0) existing.fehlbestand += Math.abs(row.delta);
    if (row.delta > 0) existing.ueberbestand += row.delta;
    existing.adjustments_count += 1;
  }

  const result: Record<string, { day: string; fehlbestand: number; ueberbestand: number; adjustments_count: number }[]> = {};
  for (const [productId, dayMap] of root.entries()) {
    result[productId] = [...dayMap.values()].sort((a, b) => b.day.localeCompare(a.day));
  }
  return result;
});

const drilldownDayToProducts = computed(() => {
  const root = new Map<
    string,
    Map<string, { product_id: string; product_name: string; fehlbestand: number; ueberbestand: number; adjustments_count: number }>
  >();

  for (const row of rows.value) {
    if (!root.has(row.local_day)) root.set(row.local_day, new Map());
    const productMap = root.get(row.local_day)!;
    const existing = productMap.get(row.product_id);
    if (!existing) {
      productMap.set(row.product_id, {
        product_id: row.product_id,
        product_name: row.product_name,
        fehlbestand: row.delta < 0 ? Math.abs(row.delta) : 0,
        ueberbestand: row.delta > 0 ? row.delta : 0,
        adjustments_count: 1,
      });
      continue;
    }
    if (row.delta < 0) existing.fehlbestand += Math.abs(row.delta);
    if (row.delta > 0) existing.ueberbestand += row.delta;
    existing.adjustments_count += 1;
  }

  const result: Record<
    string,
    { product_id: string; product_name: string; fehlbestand: number; ueberbestand: number; adjustments_count: number }[]
  > = {};
  for (const [day, productMap] of root.entries()) {
    result[day] = [...productMap.values()].sort((a, b) => {
      const scoreA = a.fehlbestand + a.ueberbestand;
      const scoreB = b.fehlbestand + b.ueberbestand;
      if (scoreB !== scoreA) return scoreB - scoreA;
      return a.product_name.localeCompare(b.product_name, "de-DE");
    });
  }
  return result;
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

    const data = await adminRpc("get_inventory_adjustments_period", {
      start: startISO,
      end: endISOExclusive.toISOString(),
    });

    rows.value = ((data as any[]) ?? []).map((row: any) => ({
      created_at: row.created_at,
      local_day: row.local_day,
      product_id: row.product_id,
      product_name: row.product_name,
      product_category: row.product_category,
      active: Boolean(row.active),
      location: row.location,
      delta: Number(row.delta ?? 0),
      adjustment_kind: row.adjustment_kind,
      reason: row.reason,
      note: row.note ?? null,
      source: row.source ?? "unknown",
    }));
    showToast("✅ Bericht erfolgreich geladen");
  } catch (err) {
    console.error("[AdminStockAdjustmentsReport]", err);
    error.value = "Fehler beim Laden des Anpassungsberichts";
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
    await exportReportAsPdf("admin-stock-adjustments-report", "Fehlbestaende-und-Anpassungen");
  } catch (err) {
    console.error("[AdminStockAdjustmentsReport.exportPdf]", err);
    showToast("⚠️ PDF-Export fehlgeschlagen");
  }
}
</script>

<template>
  <div class="space-y-6" data-report-id="admin-stock-adjustments-report">
    <div class="flex flex-col lg:flex-row justify-between items-start lg:items-center gap-3">
      <h2 class="text-xl font-semibold text-primary">📉 Fehlbestände & Anpassungen</h2>
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

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4 items-end">
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
        <label class="block text-sm font-medium text-gray-600 mb-1">Gruppierung</label>
        <select v-model="groupBy" class="border rounded-md px-3 py-2 text-sm bg-white">
          <option value="product">Nach Produkt</option>
          <option value="day">Nach Tag</option>
        </select>
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

    <div v-if="loading" class="text-center py-10 text-gray-500">
      ⏳ Bericht wird geladen...
    </div>
    <div v-else-if="error" class="text-center py-10 text-red-500">
      {{ error }}
    </div>

    <div v-else class="space-y-4">
      <div v-if="groupBy === 'product'" class="lg:hidden space-y-3">
        <div
          v-for="row in groupedByProduct"
          :key="row.product_id"
          class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <div class="text-sm text-gray-500">{{ row.product_category }}</div>
              <div class="text-base font-semibold text-gray-900">{{ row.product_name }}</div>
            </div>
            <div class="text-right text-xs text-gray-500">
              <div>Anpassungen</div>
              <div class="text-sm font-semibold text-gray-900">{{ row.adjustments_count }}</div>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-3 text-sm">
            <div>
              <div class="text-xs uppercase text-gray-500">Fehlbestand</div>
              <div class="text-red-700 font-semibold">{{ row.fehlbestand }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Überbestand</div>
              <div class="text-amber-700 font-semibold">{{ row.ueberbestand }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Abw. Kühlschrank</div>
              <div :class="deltaClass(row.fridge_delta)">{{ row.fridge_delta }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Abw. Lager</div>
              <div :class="deltaClass(row.warehouse_delta)">{{ row.warehouse_delta }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Netto</div>
              <div :class="deltaClass(row.fridge_delta + row.warehouse_delta)">
                {{ row.fridge_delta + row.warehouse_delta }}
              </div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Letzte Anpassung</div>
              <div>{{ new Date(row.last_adjustment_at).toLocaleString("de-DE") }}</div>
            </div>
          </div>
          <details class="rounded-xl bg-gray-50 p-3">
            <summary class="cursor-pointer text-sm font-medium text-primary">
              Tage ({{ drilldownProductToDays[row.product_id]?.length ?? 0 }})
            </summary>
            <div class="mt-2 space-y-2 text-sm text-gray-600">
              <div
                v-for="dayRow in drilldownProductToDays[row.product_id] ?? []"
                :key="`${row.product_id}-${dayRow.day}`"
                class="flex items-start justify-between gap-4"
              >
                <span>{{ formatDayKey(dayRow.day) }}</span>
                <span class="text-right">
                  F: {{ dayRow.fehlbestand }} | Ü: {{ dayRow.ueberbestand }} ({{ dayRow.adjustments_count }}x)
                </span>
              </div>
            </div>
          </details>
        </div>
        <div
          v-if="groupedByProduct.length === 0"
          class="bg-white rounded-2xl shadow border border-dashed border-gray-300 p-6 text-center text-sm text-gray-500"
        >
          Keine Anpassungen im gewählten Zeitraum
        </div>
      </div>

      <div v-else class="lg:hidden space-y-3">
        <div
          v-for="row in groupedByDay"
          :key="row.day"
          class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <div class="text-sm text-gray-500">Tag</div>
              <div class="text-base font-semibold text-gray-900">{{ formatDayKey(row.day) }}</div>
            </div>
            <div class="text-right text-xs text-gray-500">
              <div>Anpassungen</div>
              <div class="text-sm font-semibold text-gray-900">{{ row.adjustments_count }}</div>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-3 text-sm">
            <div>
              <div class="text-xs uppercase text-gray-500">Produkte</div>
              <div>{{ row.products_count }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Fehlbestand</div>
              <div class="text-red-700 font-semibold">{{ row.fehlbestand }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Überbestand</div>
              <div class="text-amber-700 font-semibold">{{ row.ueberbestand }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Abw. Kühlschrank</div>
              <div :class="deltaClass(row.fridge_delta)">{{ row.fridge_delta }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Abw. Lager</div>
              <div :class="deltaClass(row.warehouse_delta)">{{ row.warehouse_delta }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Netto</div>
              <div :class="deltaClass(row.fridge_delta + row.warehouse_delta)">
                {{ row.fridge_delta + row.warehouse_delta }}
              </div>
            </div>
          </div>
          <details class="rounded-xl bg-gray-50 p-3">
            <summary class="cursor-pointer text-sm font-medium text-primary">
              Produkte ({{ drilldownDayToProducts[row.day]?.length ?? 0 }})
            </summary>
            <div class="mt-2 space-y-2 text-sm text-gray-600">
              <div
                v-for="productRow in drilldownDayToProducts[row.day] ?? []"
                :key="`${row.day}-${productRow.product_id}`"
                class="flex items-start justify-between gap-4"
              >
                <span>{{ productRow.product_name }}</span>
                <span class="text-right">
                  F: {{ productRow.fehlbestand }} | Ü: {{ productRow.ueberbestand }} ({{ productRow.adjustments_count }}x)
                </span>
              </div>
            </div>
          </details>
        </div>
        <div
          v-if="groupedByDay.length === 0"
          class="bg-white rounded-2xl shadow border border-dashed border-gray-300 p-6 text-center text-sm text-gray-500"
        >
          Keine Anpassungen im gewählten Zeitraum
        </div>
      </div>

      <div class="hidden lg:block bg-white rounded-2xl shadow overflow-x-auto border border-gray-200">
      <table v-if="groupBy === 'product'" class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Kategorie</th>
            <th class="px-4 py-3 text-left">Produkt</th>
            <th class="px-4 py-3 text-right">Anpassungen</th>
            <th class="px-4 py-3 text-right">Fehlbestand</th>
            <th class="px-4 py-3 text-right">Überbestand</th>
            <th class="px-4 py-3 text-right">Abw. Kühlschrank</th>
            <th class="px-4 py-3 text-right">Abw. Lager</th>
            <th class="px-4 py-3 text-right">Netto-Abweichung</th>
            <th class="px-4 py-3 text-left">Letzte Anpassung</th>
            <th class="px-4 py-3 text-left">Drilldown (Tage)</th>
          </tr>
        </thead>
        <tbody>
          <template v-if="groupedByProduct.length">
            <tr
              v-for="row in groupedByProduct"
              :key="row.product_id"
              class="border-t hover:bg-primary/5 transition-colors"
            >
              <td class="px-4 py-2">{{ row.product_category }}</td>
              <td class="px-4 py-2">{{ row.product_name }}</td>
              <td class="px-4 py-2 text-right">{{ row.adjustments_count }}</td>
              <td class="px-4 py-2 text-right text-red-700 font-semibold">{{ row.fehlbestand }}</td>
              <td class="px-4 py-2 text-right text-amber-700 font-semibold">{{ row.ueberbestand }}</td>
              <td class="px-4 py-2 text-right" :class="deltaClass(row.fridge_delta)">{{ row.fridge_delta }}</td>
              <td class="px-4 py-2 text-right" :class="deltaClass(row.warehouse_delta)">{{ row.warehouse_delta }}</td>
              <td class="px-4 py-2 text-right" :class="deltaClass(row.fridge_delta + row.warehouse_delta)">
                {{ row.fridge_delta + row.warehouse_delta }}
              </td>
              <td class="px-4 py-2">{{ new Date(row.last_adjustment_at).toLocaleString("de-DE") }}</td>
              <td class="px-4 py-2">
                <details>
                  <summary class="cursor-pointer text-primary">
                    Tage ({{ drilldownProductToDays[row.product_id]?.length ?? 0 }})
                  </summary>
                  <div class="mt-2 space-y-1 text-xs text-gray-600">
                    <div
                      v-for="dayRow in drilldownProductToDays[row.product_id] ?? []"
                      :key="`${row.product_id}-${dayRow.day}`"
                      class="flex justify-between gap-4"
                    >
                      <span>{{ formatDayKey(dayRow.day) }}</span>
                      <span>
                        F: {{ dayRow.fehlbestand }} | Ü: {{ dayRow.ueberbestand }} ({{ dayRow.adjustments_count }}x)
                      </span>
                    </div>
                  </div>
                </details>
              </td>
            </tr>
          </template>
          <tr v-else>
            <td colspan="10" class="text-center py-6 text-gray-400 italic">
              Keine Anpassungen im gewählten Zeitraum
            </td>
          </tr>
        </tbody>
        <tfoot v-if="groupedByProduct.length" class="bg-gray-50 border-t-2 border-gray-300">
          <tr class="font-semibold">
            <td class="px-4 py-3" colspan="2">Gesamt</td>
            <td class="px-4 py-3 text-right">{{ totalsByProduct.adjustments_count }}</td>
            <td class="px-4 py-3 text-right text-red-700">{{ totalsByProduct.fehlbestand }}</td>
            <td class="px-4 py-3 text-right text-amber-700">{{ totalsByProduct.ueberbestand }}</td>
            <td class="px-4 py-3 text-right" :class="deltaClass(totalsByProduct.fridge_delta)">
              {{ totalsByProduct.fridge_delta }}
            </td>
            <td class="px-4 py-3 text-right" :class="deltaClass(totalsByProduct.warehouse_delta)">
              {{ totalsByProduct.warehouse_delta }}
            </td>
            <td
              class="px-4 py-3 text-right"
              :class="deltaClass(totalsByProduct.fridge_delta + totalsByProduct.warehouse_delta)"
            >
              {{ totalsByProduct.fridge_delta + totalsByProduct.warehouse_delta }}
            </td>
            <td class="px-4 py-3 text-left">-</td>
            <td class="px-4 py-3 text-left">-</td>
          </tr>
        </tfoot>
      </table>

      <table v-else class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Tag</th>
            <th class="px-4 py-3 text-right">Anpassungen</th>
            <th class="px-4 py-3 text-right">Produkte</th>
            <th class="px-4 py-3 text-right">Fehlbestand</th>
            <th class="px-4 py-3 text-right">Überbestand</th>
            <th class="px-4 py-3 text-right">Abw. Kühlschrank</th>
            <th class="px-4 py-3 text-right">Abw. Lager</th>
            <th class="px-4 py-3 text-right">Netto-Abweichung</th>
            <th class="px-4 py-3 text-left">Drilldown (Produkte)</th>
          </tr>
        </thead>
        <tbody>
          <template v-if="groupedByDay.length">
            <tr
              v-for="row in groupedByDay"
              :key="row.day"
              class="border-t hover:bg-primary/5 transition-colors"
            >
              <td class="px-4 py-2">{{ formatDayKey(row.day) }}</td>
              <td class="px-4 py-2 text-right">{{ row.adjustments_count }}</td>
              <td class="px-4 py-2 text-right">{{ row.products_count }}</td>
              <td class="px-4 py-2 text-right text-red-700 font-semibold">{{ row.fehlbestand }}</td>
              <td class="px-4 py-2 text-right text-amber-700 font-semibold">{{ row.ueberbestand }}</td>
              <td class="px-4 py-2 text-right" :class="deltaClass(row.fridge_delta)">{{ row.fridge_delta }}</td>
              <td class="px-4 py-2 text-right" :class="deltaClass(row.warehouse_delta)">{{ row.warehouse_delta }}</td>
              <td class="px-4 py-2 text-right" :class="deltaClass(row.fridge_delta + row.warehouse_delta)">
                {{ row.fridge_delta + row.warehouse_delta }}
              </td>
              <td class="px-4 py-2">
                <details>
                  <summary class="cursor-pointer text-primary">
                    Produkte ({{ drilldownDayToProducts[row.day]?.length ?? 0 }})
                  </summary>
                  <div class="mt-2 space-y-1 text-xs text-gray-600">
                    <div
                      v-for="productRow in drilldownDayToProducts[row.day] ?? []"
                      :key="`${row.day}-${productRow.product_id}`"
                      class="flex justify-between gap-4"
                    >
                      <span>{{ productRow.product_name }}</span>
                      <span>
                        F: {{ productRow.fehlbestand }} | Ü: {{ productRow.ueberbestand }} ({{ productRow.adjustments_count }}x)
                      </span>
                    </div>
                  </div>
                </details>
              </td>
            </tr>
          </template>
          <tr v-else>
            <td colspan="9" class="text-center py-6 text-gray-400 italic">
              Keine Anpassungen im gewählten Zeitraum
            </td>
          </tr>
        </tbody>
        <tfoot v-if="groupedByDay.length" class="bg-gray-50 border-t-2 border-gray-300">
          <tr class="font-semibold">
            <td class="px-4 py-3">Gesamt</td>
            <td class="px-4 py-3 text-right">{{ totalsByDay.adjustments_count }}</td>
            <td class="px-4 py-3 text-right">{{ totalsByDay.products_count }}</td>
            <td class="px-4 py-3 text-right text-red-700">{{ totalsByDay.fehlbestand }}</td>
            <td class="px-4 py-3 text-right text-amber-700">{{ totalsByDay.ueberbestand }}</td>
            <td class="px-4 py-3 text-right" :class="deltaClass(totalsByDay.fridge_delta)">
              {{ totalsByDay.fridge_delta }}
            </td>
            <td class="px-4 py-3 text-right" :class="deltaClass(totalsByDay.warehouse_delta)">
              {{ totalsByDay.warehouse_delta }}
            </td>
            <td
              class="px-4 py-3 text-right"
              :class="deltaClass(totalsByDay.fridge_delta + totalsByDay.warehouse_delta)"
            >
              {{ totalsByDay.fridge_delta + totalsByDay.warehouse_delta }}
            </td>
            <td class="px-4 py-3 text-left">-</td>
          </tr>
        </tfoot>
      </table>
    </div>

      </div>

      <div class="lg:hidden space-y-3">
        <div
          v-for="row in rows"
          :key="`${row.created_at}-${row.product_id}-${row.location}-${row.delta}`"
          class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <div class="text-sm text-gray-500">{{ new Date(row.created_at).toLocaleString("de-DE") }}</div>
              <div class="text-base font-semibold text-gray-900">{{ row.product_name }}</div>
            </div>
            <div class="text-right">
              <div class="text-xs uppercase text-gray-500">Delta</div>
              <div
                class="text-sm font-semibold"
                :class="row.delta < 0 ? 'text-red-700' : row.delta > 0 ? 'text-amber-700' : 'text-green-700'"
              >
                {{ row.delta }}
              </div>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-3 text-sm">
            <div>
              <div class="text-xs uppercase text-gray-500">Ort</div>
              <div>{{ locationLabel(row.location) }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Typ</div>
              <div>{{ row.adjustment_kind }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Grund</div>
              <div>{{ reasonLabel(row.reason) }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Notiz</div>
              <div>{{ row.note || "-" }}</div>
            </div>
          </div>
        </div>
        <div
          v-if="rows.length === 0"
          class="bg-white rounded-2xl shadow border border-dashed border-gray-300 p-6 text-center text-sm text-gray-500"
        >
          Keine Detaildaten im gewählten Zeitraum
        </div>
      </div>

      <div class="hidden lg:block bg-white rounded-2xl shadow border border-gray-200 overflow-x-auto">
      <table class="min-w-full text-sm text-gray-700">
        <thead class="bg-gray-100 text-gray-700 uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Zeitpunkt</th>
            <th class="px-4 py-3 text-left">Produkt</th>
            <th class="px-4 py-3 text-left">Ort</th>
            <th class="px-4 py-3 text-right">Delta</th>
            <th class="px-4 py-3 text-left">Typ</th>
            <th class="px-4 py-3 text-left">Grund</th>
            <th class="px-4 py-3 text-left">Notiz</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="row in rows" :key="`${row.created_at}-${row.product_id}-${row.location}-${row.delta}`" class="border-t">
            <td class="px-4 py-2">{{ new Date(row.created_at).toLocaleString("de-DE") }}</td>
            <td class="px-4 py-2">{{ row.product_name }}</td>
            <td class="px-4 py-2">{{ locationLabel(row.location) }}</td>
            <td class="px-4 py-2 text-right" :class="row.delta < 0 ? 'text-red-700 font-semibold' : row.delta > 0 ? 'text-amber-700 font-semibold' : 'text-green-700'">
              {{ row.delta }}
            </td>
            <td class="px-4 py-2">{{ row.adjustment_kind }}</td>
            <td class="px-4 py-2">{{ reasonLabel(row.reason) }}</td>
            <td class="px-4 py-2">{{ row.note || "-" }}</td>
          </tr>
          <tr v-if="rows.length === 0">
            <td colspan="7" class="text-center py-6 text-gray-400 italic">
              Keine Detaildaten im gewählten Zeitraum
            </td>
          </tr>
        </tbody>
      </table>
      </div>
    </div>
  </div>
</template>
