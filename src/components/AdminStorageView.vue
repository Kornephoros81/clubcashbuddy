<!-- src/components/AdminStorageView.vue -->
<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useAdminProductsStore } from "@/stores/useAdminProductsStore";
import { useToast } from "@/composables/useToast";

const store = useAdminProductsStore();
const { show: showToast } = useToast();
const savingLotById = ref<Record<string, boolean>>({});
const lotState = ref<"active" | "closed" | "all">("active");

onMounted(async () => {
  await store.loadProductsWithStorage();
  await store.loadPurchaseLots(null, lotState.value);
});

async function delay(ms = 800) {
  return new Promise((r) => setTimeout(r, ms));
}

/* 💾 Speichert alle geänderten Lagerbestände */
async function saveAll() {
  try {
    const changed = store.products.filter((p) => p.delta && p.delta !== 0);
    if (!changed.length) {
      showToast("⚠️ Keine Änderungen vorgenommen");
      return;
    }

    showToast("💾 Änderungen werden gespeichert …");
    await store.updateStorageChanges();
    await store.loadPurchaseLots(null, lotState.value);
    showToast("✅ Lagerbestände aktualisiert");
    await delay();
  } catch (err) {
    console.error("[saveAllStorage]", err);
    showToast("⚠️ Fehler beim Aktualisieren der Lagerbestände");
  }
}

function setLotSaving(lotId: string, saving: boolean) {
  savingLotById.value = {
    ...savingLotById.value,
    [lotId]: saving,
  };
}

function isLotSaving(lotId: string) {
  return Boolean(savingLotById.value[lotId]);
}

async function saveLot(lot: any) {
  try {
    setLotSaving(lot.id, true);
    await store.updatePurchaseLot(lot);
    await store.loadPurchaseLots(null, lotState.value);
    showToast(`✅ EK für ${lot.product_name} aktualisiert`);
  } catch (err) {
    console.error("[savePurchaseLot]", err);
    showToast("⚠️ Fehler beim Aktualisieren des EK");
  } finally {
    setLotSaving(lot.id, false);
  }
}

async function changeLotState(nextState: "active" | "closed" | "all") {
  lotState.value = nextState;
  await store.loadPurchaseLots(null, lotState.value);
}

function lotSourceLabel(lot: any) {
  if (lot.source_reason === "sale_fallback") return "Fallback";
  if (lot.source_reason === "purchase") return "Einlagerung";
  if (lot.source_reason === "opening_balance") return "Startbestand";
  if (lot.source_reason === "count_adjustment") return "Inventur";
  if (lot.source_reason === "migration_initial") return "Migration";
  return lot.source_reason ?? "-";
}
</script>

<template>
  <div class="space-y-6">
    <!-- Header -->
    <div class="flex justify-between items-center">
      <h2 class="text-xl font-semibold text-primary">Lagerverwaltung</h2>

      <div class="flex gap-2">
        <button
          @click="saveAll"
          class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition"
        >
          💾 Änderungen speichern
        </button>
      </div>
    </div>

    <div v-if="store.loading" class="text-center py-10 text-gray-500">
      ⏳ Lagerdaten werden geladen...
    </div>

    <div
      v-else
      class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200"
    >
      <table class="min-w-full text-sm text-gray-700">
        <thead
          class="bg-primary/10 text-primary uppercase text-xs font-semibold"
        >
          <tr>
            <th class="px-4 py-3 text-left">Produkt</th>
            <th class="px-4 py-3 text-right">Letzter EK</th>
            <th class="px-4 py-3 text-right">Lager</th>
            <th class="px-4 py-3 text-right">Kühlschrank</th>
            <th class="px-4 py-3 text-right">Gesamt</th>
            <th class="px-4 py-3 text-right">Einlagerung</th>
            <th class="px-4 py-3 text-right">EK neu</th>
            <th class="px-4 py-3 text-right">Bestandswert</th>
            <th class="px-4 py-3 text-left">Letzte Änderung</th>
          </tr>
        </thead>

        <tbody>
          <tr
            v-for="p in store.products"
            :key="p.id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">{{ p.name }}</td>

            <td class="px-4 py-2 text-right">
              {{ Number(p.lastPurchasePriceEuro ?? 0).toFixed(2) }} €
            </td>

            <td class="px-4 py-2 text-right">{{ p.warehouse_stock ?? 0 }}</td>
            <td class="px-4 py-2 text-right">{{ p.fridge_stock ?? 0 }}</td>
            <td class="px-4 py-2 text-right">
              {{ p.total_stock ?? ((p.warehouse_stock ?? 0) + (p.fridge_stock ?? 0)) }}
            </td>

            <td class="px-4 py-2 text-right">
              <input
                v-model.number="p.delta"
                type="number"
                class="w-20 text-right border rounded-md px-2 py-1 text-sm focus:ring-1 focus:ring-primary"
              />
            </td>

            <td class="px-4 py-2 text-right">
              <input
                v-model.number="p.purchasePriceEuro"
                type="number"
                min="0"
                step="0.01"
                class="w-24 text-right border rounded-md px-2 py-1 text-sm focus:ring-1 focus:ring-primary"
                :disabled="!(Number(p.delta ?? 0) > 0)"
              />
            </td>

            <td class="px-4 py-2 text-right">
              {{ Number(p.inventoryValueEuro ?? 0).toFixed(2) }} €
            </td>

            <td class="px-4 py-2">
              {{
                p.last_restocked_at
                  ? new Date(p.last_restocked_at).toLocaleString()
                  : "-"
              }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200">
      <div class="px-4 py-3 border-b border-gray-200 flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h3 class="text-sm font-semibold text-primary">Einlagerungen / Lots</h3>
          <p class="mt-1 text-xs text-gray-500">
            Fallback-Lots sammeln Verkäufe ohne gepflegtes Einkaufslos. EK-Korrekturen pflegen offene Kosten nach.
          </p>
        </div>
        <div class="inline-flex max-w-full rounded-lg border border-gray-200 overflow-hidden">
          <button
            type="button"
            class="px-3 py-1.5 text-sm font-medium"
            :class="lotState === 'active' ? 'bg-primary text-white' : 'bg-white text-gray-700 hover:bg-gray-50'"
            @click="changeLotState('active')"
          >
            Aktiv
          </button>
          <button
            type="button"
            class="border-l border-gray-200 px-3 py-1.5 text-sm font-medium"
            :class="lotState === 'closed' ? 'bg-primary text-white' : 'bg-white text-gray-700 hover:bg-gray-50'"
            @click="changeLotState('closed')"
          >
            Geschlossen
          </button>
          <button
            type="button"
            class="border-l border-gray-200 px-3 py-1.5 text-sm font-medium"
            :class="lotState === 'all' ? 'bg-primary text-white' : 'bg-white text-gray-700 hover:bg-gray-50'"
            @click="changeLotState('all')"
          >
            Alle
          </button>
        </div>
      </div>

      <table class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Produkt</th>
            <th class="px-4 py-3 text-left">Quelle</th>
            <th class="px-4 py-3 text-left">Status</th>
            <th class="px-4 py-3 text-right">Menge</th>
            <th class="px-4 py-3 text-right">Rest</th>
            <th class="px-4 py-3 text-right">EK</th>
            <th class="px-4 py-3 text-right">Vorher</th>
            <th class="px-4 py-3 text-right">Offen</th>
            <th class="px-4 py-3 text-left">Datum</th>
            <th class="px-4 py-3 text-left">Notiz</th>
            <th class="px-4 py-3 text-right">Aktion</th>
          </tr>
        </thead>

        <tbody>
          <tr v-if="!store.purchaseLots.length">
            <td colspan="11" class="px-4 py-6 text-center text-gray-500">
              Keine Lots für diesen Filter vorhanden.
            </td>
          </tr>

          <tr
            v-for="lot in store.purchaseLots"
            :key="lot.id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">{{ lot.product_name }}</td>
            <td class="px-4 py-2">
              <span
                class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium"
                :class="lot.isFallback ? 'bg-amber-100 text-amber-800' : 'bg-blue-50 text-blue-700'"
              >
                {{ lotSourceLabel(lot) }}
              </span>
            </td>
            <td class="px-4 py-2">
              <span
                class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium"
                :class="lot.isClosed ? 'bg-gray-100 text-gray-700' : 'bg-emerald-100 text-emerald-800'"
              >
                {{ lot.isClosed ? "Geschlossen" : "Aktiv" }}
              </span>
            </td>
            <td class="px-4 py-2 text-right">{{ lot.purchased_quantity ?? 0 }}</td>
            <td class="px-4 py-2 text-right">{{ lot.remaining_quantity ?? 0 }}</td>
            <td class="px-4 py-2 text-right">
              <input
                v-model.number="lot.unitCostEuro"
                type="number"
                min="0"
                step="0.01"
                class="w-24 text-right border rounded-md px-2 py-1 text-sm focus:ring-1 focus:ring-primary"
              />
            </td>
            <td class="px-4 py-2 text-right">
              {{
                lot.correctedFromPriceEuro === null || lot.correctedFromPriceEuro === undefined
                  ? "-"
                : `${Number(lot.correctedFromPriceEuro).toFixed(2)} €`
              }}
            </td>
            <td class="px-4 py-2 text-right">
              <span v-if="lot.costPending || lot.pendingAllocationCount > 0" class="font-medium text-amber-700">
                {{ lot.pendingAllocationCount ?? 0 }}
              </span>
              <span v-else class="text-gray-400">-</span>
            </td>
            <td class="px-4 py-2">
              <div>{{ lot.created_at ? new Date(lot.created_at).toLocaleString() : "-" }}</div>
              <div v-if="lot.closed_at" class="text-xs text-gray-500">
                geschlossen {{ new Date(lot.closed_at).toLocaleString() }}
              </div>
            </td>
            <td class="px-4 py-2">
              <input
                v-model="lot.note"
                type="text"
                class="w-56 border rounded-md px-2 py-1 text-sm focus:ring-1 focus:ring-primary"
                placeholder="Korrekturgrund"
              />
            </td>
            <td class="px-4 py-2 text-right">
              <button
                @click="saveLot(lot)"
                class="bg-primary text-white px-3 py-1.5 rounded-lg shadow hover:bg-primary/90 transition disabled:opacity-50"
                :disabled="isLotSaving(lot.id)"
              >
                {{ isLotSaving(lot.id) ? "..." : "Speichern" }}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
