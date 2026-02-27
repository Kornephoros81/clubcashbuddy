<!-- src/views/StockRefillView.vue -->
<script setup lang="ts">
import { ref, computed, onMounted, watch, inject, type Ref } from "vue";
import { useCatalog } from "@/stores/useCatalog";
import { useDeviceAuthStore } from "@/stores/useDeviceAuthStore";
import DeviceAuthDialog from "@/components/DeviceAuthDialog.vue";

const toast = inject<Ref<{ show: (msg: string) => void } | null>>(
  "toast",
  null
);

const catalog = useCatalog();
const auth = useDeviceAuthStore();

const quantities = ref<Record<string, number>>({});
const stockInfo = ref<Record<string, { warehouse: number; fridge: number; total: number }>>({});
const lastRefillDate = ref<string | null>(null);
const refillerSearch = ref("");
const refillerId = ref<string | null>(null);
const refillerValidationError = ref("");

const refillMembers = computed(() =>
  catalog.members
    .filter((m) => m.active && !m.is_guest)
    .sort((a, b) => a.name.localeCompare(b.name, "de"))
);

const filteredRefillMembers = computed(() => {
  const q = refillerSearch.value.trim().toLowerCase();
  if (!q) return refillMembers.value.slice(0, 12);
  return refillMembers.value
    .filter((m) => m.name.toLowerCase().includes(q))
    .slice(0, 12);
});

const selectedRefillerName = computed(() => {
  if (!refillerId.value) return "";
  return refillMembers.value.find((m) => m.id === refillerId.value)?.name ?? "";
});

function selectRefiller(memberId: string) {
  refillerId.value = memberId;
  refillerSearch.value = "";
  refillerValidationError.value = "";
}

function clearRefillerSelection() {
  refillerId.value = null;
  refillerSearch.value = "";
}

watch(refillerSearch, () => {
  if (refillerValidationError.value && refillerSearch.value.trim().length > 0) {
    refillerValidationError.value = "";
  }
  if (refillerSearch.value.trim().length > 0) {
    refillerId.value = null;
  }
});

const groupedProducts = computed(() => {
  const grouped: Record<string, any[]> = {};
  catalog.products
    .filter((p) => p.active && (p as any).inventoried)
    .forEach((p) => {
      if (!grouped[p.category]) grouped[p.category] = [];
      grouped[p.category].push(p);
    });
  return grouped;
});

onMounted(async () => {
  if (auth.initializing) {
    await new Promise<void>((resolve) => {
      const stop = watch(
        () => auth.initializing,
        (v) => {
          if (!v) {
            stop();
            resolve();
          }
        }
      );
    });
  }

  if (!auth.authenticated) return;

  if (catalog.products.length === 0) await catalog.loadProducts();
  if (catalog.members.length === 0) await catalog.loadMembers();
  await loadStockInfo();
});

async function loadStockInfo() {
  try {
    const res = await fetch("/api/get-stock-info", {
      headers: { Authorization: `Bearer ${auth.token}` },
    });
    if (!res.ok) throw new Error(await res.text());

    const data = await res.json();
    data.forEach((p: any) => {
      stockInfo.value[p.product_id] = {
        warehouse: Number(p.warehouse_stock ?? 0),
        fridge: Number(p.fridge_stock ?? 0),
        total: Number(p.current_stock ?? 0),
      };
    });

    const last = data
      .map((p: any) => new Date(p.last_refill))
      .filter((d) => !isNaN(d.getTime()))
      .sort((a, b) => b.getTime() - a.getTime())[0];

    if (last) lastRefillDate.value = new Date(last).toLocaleDateString("de-DE");
  } catch {
    toast?.value?.show("Fehler beim Laden des Bestands");
  }
}

async function saveRefills() {
  const items = Object.entries(quantities.value)
    .filter(([_, q]) => q && q > 0)
    .map(([product_id, quantity]) => ({ product_id, quantity }));

  if (items.length === 0) {
    toast?.value?.show("Keine Nachfüllungen angegeben");
    return;
  }

  if (!refillerId.value) {
    refillerValidationError.value = "Bitte einen Auffüller auswählen, bevor du speicherst.";
    document
      .getElementById("refiller-section")
      ?.scrollIntoView({ behavior: "smooth", block: "center" });
    document.getElementById("refiller-input")?.focus();
    toast?.value?.show("Bitte Auffüller auswählen");
    return;
  }
  refillerValidationError.value = "";

  try {
    const res = await fetch("/api/adjust-stock-batch", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${auth.token}`,
      },
      body: JSON.stringify({ items, member_id: refillerId.value }),
    });
    if (!res.ok) throw new Error(await res.text());

    toast?.value?.show("Bestand aktualisiert");
    quantities.value = {};
    refillerId.value = null;
    refillerSearch.value = "";
    refillerValidationError.value = "";
    await loadStockInfo();
  } catch {
    toast?.value?.show("Fehler beim Speichern");
  }
}
</script>

<template>
  <DeviceAuthDialog v-if="!auth.authenticated && !auth.initializing" />

  <div v-else class="p-6 flex flex-col gap-6 mx-auto max-w-[1300px]">
    <div class="flex items-center gap-4">
      <RouterLink
        to="/"
        class="h-12 px-6 rounded-xl shadow font-semibold border border-blue-600 text-blue-600 bg-white hover:bg-blue-50 flex items-center"
      >
        ← Zurück
      </RouterLink>

      <h1 class="text-2xl font-bold text-primary">Bestand nachfüllen</h1>

      <div
        v-if="lastRefillDate"
        class="ml-auto bg-gray-100 border border-gray-300 px-3 py-1 rounded-md text-gray-700 text-sm"
      >
        Zuletzt: {{ lastRefillDate }}
      </div>
    </div>

    <div
      id="refiller-section"
      class="bg-white border border-gray-200 rounded-xl p-4"
      :class="refillerValidationError ? 'border-red-400 ring-2 ring-red-100' : ''"
    >
      <div class="text-sm font-semibold text-gray-700 mb-2">Wer hat aufgefüllt? *</div>
      <div
        v-if="refillerValidationError"
        class="mb-3 rounded-lg border border-red-300 bg-red-50 px-3 py-2 text-sm font-semibold text-red-800"
        role="alert"
      >
        {{ refillerValidationError }}
      </div>
      <div
        v-if="refillerId"
        class="mb-3 rounded-lg border border-emerald-300 bg-emerald-50 px-3 py-2 flex items-center justify-between gap-3"
      >
        <div class="text-sm text-emerald-900">
          <span class="font-semibold">Ausgewählt:</span>
          <span class="font-bold">{{ selectedRefillerName }}</span>
        </div>
        <button
          class="px-3 py-1.5 text-xs font-semibold rounded-md border border-emerald-400 text-emerald-800 bg-white hover:bg-emerald-100"
          @click="clearRefillerSelection"
        >
          Ändern
        </button>
      </div>
      <div class="relative">
        <input
          id="refiller-input"
          v-model="refillerSearch"
          type="text"
          :placeholder="refillerId ? 'Anderes Mitglied suchen ...' : 'Mitglied suchen ...'"
          class="h-11 w-full rounded-lg border px-3"
          :class="
            refillerValidationError
              ? 'border-red-400 bg-red-50'
              : refillerId
                ? 'border-emerald-400 bg-emerald-50'
                : 'border-gray-300'
          "
        />
        <div
          v-if="refillerSearch.trim().length > 0 && filteredRefillMembers.length > 0"
          class="absolute z-20 mt-1 w-full max-h-56 overflow-y-auto rounded-lg border border-gray-200 bg-white shadow"
        >
          <button
            v-for="m in filteredRefillMembers"
            :key="m.id"
            class="w-full px-3 py-2 text-left hover:bg-blue-50"
            @click="selectRefiller(m.id)"
          >
            {{ m.name }}
          </button>
        </div>
      </div>
    </div>

    <div
      v-for="(prods, cat) in groupedProducts"
      :key="cat"
      class="flex flex-col gap-4"
    >
      <h2
        class="text-xl font-bold text-primary mb-1 border-l-4 border-primary pl-3"
      >
        {{ cat }}
      </h2>

      <div
        class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5"
      >
        <div
          v-for="p in prods"
          :key="p.id"
          class="rounded-xl border border-gray-300 bg-white p-3 shadow-sm max-w-[240px] w-full mx-auto"
        >
          <div class="flex justify-between items-center mb-3">
            <div class="text-base font-semibold">{{ p.name }}</div>

            <div
              class="px-3 py-1 rounded-full text-gray-700 text-sm border"
              :class="{
                'bg-red-100 border-red-300': (stockInfo[p.id]?.fridge ?? 0) <= 2,
                'bg-amber-100 border-amber-300':
                  (stockInfo[p.id]?.fridge ?? 0) > 2 && (stockInfo[p.id]?.fridge ?? 0) < 9,
                'bg-emerald-100 border-emerald-300':
                  (stockInfo[p.id]?.fridge ?? 0) >= 9,
              }"
            >
              {{ stockInfo[p.id]?.fridge ?? 0 }}
            </div>
          </div>
          <div class="text-xs text-gray-500 mb-2">
            Lager: {{ stockInfo[p.id]?.warehouse ?? 0 }} | Gesamt: {{ stockInfo[p.id]?.total ?? 0 }}
          </div>

          <div class="bg-gray-50 border border-gray-200 rounded-lg p-3">
            <div class="text-sm text-gray-600 mb-1">Nachgefüllt</div>

            <input
              type="number"
              min="0"
              v-model.number="quantities[p.id]"
              class="h-10 w-20 rounded-lg border border-gray-300 text-center text-lg mx-auto"
            />
          </div>
        </div>
      </div>
    </div>

    <div
      class="sticky bottom-0 bg-white border-t border-gray-200 p-4 flex justify-end"
    >
      <button
        class="h-12 px-6 bg-blue-600 text-white rounded-xl shadow font-semibold"
        @click="saveRefills"
      >
        Speichern
      </button>
    </div>
  </div>
</template>

<style scoped>
::-webkit-scrollbar {
  width: 6px;
}
::-webkit-scrollbar-thumb {
  background: rgba(0, 0, 0, 0.25);
  border-radius: 3px;
}
</style>
