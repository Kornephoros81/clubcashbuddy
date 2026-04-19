<!-- src/components/AdminStorageView.vue -->
<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useAdminProductsStore } from "@/stores/useAdminProductsStore";
import { useToast } from "@/composables/useToast";

const store = useAdminProductsStore();
const { show: showToast } = useToast();
const loading = ref(false);

onMounted(async () => {
  await store.loadProductsWithStorage();
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
    showToast("✅ Lagerbestände aktualisiert");
    await delay();
  } catch (err) {
    console.error("[saveAllStorage]", err);
    showToast("⚠️ Fehler beim Aktualisieren der Lagerbestände");
  }
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
  </div>
</template>
