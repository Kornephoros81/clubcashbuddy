<script setup lang="ts">
import { computed, ref } from "vue";
import { useToast } from "@/composables/useToast";
import { adminRpc } from "@/lib/adminApi";
import { exportReportAsPdf } from "@/utils/reportExport";

type InventorySnapshotRow = {
  product_id: string;
  name: string;
  category: string;
  active: boolean;
  soll_warehouse_stock: number;
  soll_fridge_stock: number;
  soll_total_stock: number;
};

type CountInput = {
  ist_warehouse_stock: number;
  ist_fridge_stock: number;
};

const { show: showToast } = useToast();

const loading = ref(false);
const saving = ref(false);
const error = ref<string | null>(null);
const report = ref<InventorySnapshotRow[]>([]);
const showInactive = ref(false);
const note = ref("");
const counts = ref<Record<string, CountInput>>({});

const filteredReport = computed(() => {
  if (showInactive.value) return report.value;
  return report.value.filter((p) => p.active);
});

function getCount(productId: string): CountInput {
  const existing = counts.value[productId];
  if (existing) return existing;
  return { ist_warehouse_stock: 0, ist_fridge_stock: 0 };
}

function getDeltaWarehouse(row: InventorySnapshotRow): number {
  return getCount(row.product_id).ist_warehouse_stock - Number(row.soll_warehouse_stock ?? 0);
}

function getDeltaFridge(row: InventorySnapshotRow): number {
  return getCount(row.product_id).ist_fridge_stock - Number(row.soll_fridge_stock ?? 0);
}

function getDeltaTotal(row: InventorySnapshotRow): number {
  return getDeltaWarehouse(row) + getDeltaFridge(row);
}

function deltaClass(delta: number): string {
  if (delta === 0) return "text-green-700";
  if (delta < 0) return "text-red-700 font-semibold";
  return "text-amber-700 font-semibold";
}

const changedRows = computed(() =>
  filteredReport.value.filter((row) => {
    const c = getCount(row.product_id);
    return (
      c.ist_warehouse_stock !== Number(row.soll_warehouse_stock ?? 0) ||
      c.ist_fridge_stock !== Number(row.soll_fridge_stock ?? 0)
    );
  }),
);

const inventoryTotals = computed(() => {
  return filteredReport.value.reduce(
    (acc, row) => {
      acc.deltaWarehouse += getDeltaWarehouse(row);
      acc.deltaFridge += getDeltaFridge(row);
      acc.deltaTotal += getDeltaTotal(row);
      return acc;
    },
    {
      deltaWarehouse: 0,
      deltaFridge: 0,
      deltaTotal: 0,
    },
  );
});

function resetCountsToSoll() {
  const next: Record<string, CountInput> = {};
  for (const row of report.value) {
    next[row.product_id] = {
      ist_warehouse_stock: Number(row.soll_warehouse_stock ?? 0),
      ist_fridge_stock: Number(row.soll_fridge_stock ?? 0),
    };
  }
  counts.value = next;
}

async function loadSnapshot() {
  loading.value = true;
  error.value = null;
  report.value = [];
  try {
    const data = await adminRpc("get_inventory_snapshot");
    report.value = ((data as any[]) ?? []).map((row: any) => ({
      product_id: row.product_id,
      name: row.name,
      category: row.category,
      active: Boolean(row.active),
      soll_warehouse_stock: Number(row.soll_warehouse_stock ?? 0),
      soll_fridge_stock: Number(row.soll_fridge_stock ?? 0),
      soll_total_stock: Number(row.soll_total_stock ?? 0),
    }));
    resetCountsToSoll();
  } catch (err) {
    console.error("[AdminInventoryReport]", err);
    error.value = "Fehler beim Laden der Inventurdaten";
    showToast("⚠️ Inventurdaten konnten nicht geladen werden");
  } finally {
    loading.value = false;
  }
}

async function applyInventoryCount() {
  const rowsToSave = changedRows.value;
  if (!rowsToSave.length) {
    showToast("⚠️ Keine Änderungen zum Buchen");
    return;
  }

  saving.value = true;
  try {
    const payload = rowsToSave.map((row) => ({
      product_id: row.product_id,
      ist_warehouse_stock: getCount(row.product_id).ist_warehouse_stock,
      ist_fridge_stock: getCount(row.product_id).ist_fridge_stock,
    }));

    await adminRpc("apply_inventory_count", {
      items: payload,
      note: note.value.trim() || null,
    });

    showToast(`✅ Inventurabgleich gebucht (${payload.length} Artikel)`);
    note.value = "";
    await loadSnapshot();
  } catch (err) {
    console.error("[AdminInventoryReport.applyInventoryCount]", err);
    showToast("⚠️ Inventurabgleich konnte nicht gebucht werden");
  } finally {
    saving.value = false;
  }
}

loadSnapshot();

async function exportPdf() {
  try {
    await exportReportAsPdf("admin-inventory-report", "Inventurabgleich");
  } catch (err) {
    console.error("[AdminInventoryReport.exportPdf]", err);
    showToast("⚠️ PDF-Export fehlgeschlagen");
  }
}
</script>

<template>
  <div class="space-y-6" data-report-id="admin-inventory-report">
    <div class="flex justify-between items-center">
      <h2 class="text-xl font-semibold text-primary">📦 Inventurabgleich</h2>
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

    <div
      class="bg-white rounded-2xl shadow border border-gray-200 p-4 flex flex-wrap gap-4 items-end"
    >
      <label class="inline-flex items-center gap-2 text-sm text-gray-700">
        <input v-model="showInactive" type="checkbox" class="accent-primary" />
        Inaktive anzeigen
      </label>

      <div class="flex-1 min-w-[280px]">
        <label class="block text-sm font-medium text-gray-600 mb-1">
          Notiz für den Abgleich (optional)
        </label>
        <input
          v-model="note"
          type="text"
          class="w-full border rounded-md px-3 py-2 text-sm"
          placeholder="z. B. Inventur 15.02"
        />
      </div>

      <button
        @click="resetCountsToSoll"
        class="px-4 py-2 rounded-lg border border-gray-300 text-gray-700 hover:bg-gray-50 transition"
      >
        Ist = Soll
      </button>

      <button
        @click="applyInventoryCount"
        :disabled="saving"
        class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition disabled:opacity-60"
      >
        {{ saving ? "Bucht..." : `Abgleich buchen (${changedRows.length})` }}
      </button>
    </div>

    <div v-if="loading" class="text-center py-10 text-gray-500">
      ⏳ Inventurdaten werden geladen...
    </div>

    <div v-else-if="error" class="text-center py-10 text-red-500">
      {{ error }}
    </div>

    <div
      v-else
      class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200"
    >
      <table class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Kategorie</th>
            <th class="px-4 py-3 text-left">Produkt</th>
            <th class="px-4 py-3 text-center">Status</th>
            <th class="px-4 py-3 text-right">Soll Lager</th>
            <th class="px-4 py-3 text-right">Ist Lager</th>
            <th class="px-4 py-3 text-right">Abw. Lager</th>
            <th class="px-4 py-3 text-right">Soll Kühlschrank</th>
            <th class="px-4 py-3 text-right">Ist Kühlschrank</th>
            <th class="px-4 py-3 text-right">Abw. Kühlschrank</th>
            <th class="px-4 py-3 text-right">Soll gesamt</th>
            <th class="px-4 py-3 text-right">Abw. gesamt</th>
          </tr>
        </thead>
        <tbody>
          <template v-if="filteredReport.length">
            <tr
              v-for="p in filteredReport"
              :key="p.product_id"
              class="border-t transition-colors"
              :class="p.active ? 'hover:bg-primary/5' : 'bg-gray-50 text-gray-500'"
            >
              <td class="px-4 py-2">{{ p.category }}</td>
              <td class="px-4 py-2">{{ p.name }}</td>
              <td class="px-4 py-2 text-center">
                <span
                  class="px-2 py-1 rounded-full text-xs font-semibold"
                  :class="p.active ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600'"
                >
                  {{ p.active ? "Aktiv" : "Inaktiv" }}
                </span>
              </td>
              <td class="px-4 py-2 text-right">{{ p.soll_warehouse_stock }}</td>
              <td class="px-4 py-2 text-right">
                <input
                  v-model.number="counts[p.product_id].ist_warehouse_stock"
                  type="number"
                  min="0"
                  class="w-20 text-right border rounded-md px-2 py-1 text-sm focus:ring-1 focus:ring-primary"
                />
              </td>
              <td class="px-4 py-2 text-right" :class="deltaClass(getDeltaWarehouse(p))">
                {{ getDeltaWarehouse(p) }}
              </td>
              <td class="px-4 py-2 text-right">{{ p.soll_fridge_stock }}</td>
              <td class="px-4 py-2 text-right">
                <input
                  v-model.number="counts[p.product_id].ist_fridge_stock"
                  type="number"
                  min="0"
                  class="w-20 text-right border rounded-md px-2 py-1 text-sm focus:ring-1 focus:ring-primary"
                />
              </td>
              <td class="px-4 py-2 text-right" :class="deltaClass(getDeltaFridge(p))">
                {{ getDeltaFridge(p) }}
              </td>
              <td class="px-4 py-2 text-right">{{ p.soll_total_stock }}</td>
              <td class="px-4 py-2 text-right" :class="deltaClass(getDeltaTotal(p))">
                {{ getDeltaTotal(p) }}
              </td>
            </tr>
          </template>
          <tr v-else>
            <td colspan="11" class="text-center py-6 text-gray-400 italic">
              Keine inventarisierten Artikel vorhanden
            </td>
          </tr>
        </tbody>
        <tfoot v-if="filteredReport.length" class="bg-gray-50 border-t-2 border-gray-300">
          <tr class="font-semibold">
            <td class="px-4 py-3" colspan="5">Gesamt</td>
            <td class="px-4 py-3 text-right" :class="deltaClass(inventoryTotals.deltaWarehouse)">
              {{ inventoryTotals.deltaWarehouse }}
            </td>
            <td class="px-4 py-3 text-right">-</td>
            <td class="px-4 py-3 text-right">-</td>
            <td class="px-4 py-3 text-right" :class="deltaClass(inventoryTotals.deltaFridge)">
              {{ inventoryTotals.deltaFridge }}
            </td>
            <td class="px-4 py-3 text-right">-</td>
            <td class="px-4 py-3 text-right" :class="deltaClass(inventoryTotals.deltaTotal)">
              {{ inventoryTotals.deltaTotal }}
            </td>
          </tr>
        </tfoot>
      </table>
    </div>
  </div>
</template>

<style scoped>
table {
  border-collapse: collapse;
}
</style>
