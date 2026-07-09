<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { adminRpc } from "@/lib/adminApi";
import { fmt } from "@/utils/currency";
import { useToast } from "@/composables/useToast";

type OrderSuggestionRow = {
  product_id: string;
  name: string;
  category: string;
  package_size: number;
  current_stock: number;
  sold_14: number;
  sold_30: number;
  sold_90: number;
  mhd_90: number;
  mhd_share_percent: number;
  daily_demand: number;
  reach_days: number | null;
  target_stock: number;
  suggested_units: number;
  suggested_packages: number;
  estimated_cost_cents: number;
  last_purchase_price_cents: number;
  trend: "rising" | "falling" | "stable";
  stock_status: "no_demand" | "out_of_stock" | "low" | "ok";
  confidence: "hoch" | "mittel" | "niedrig";
  warnings: string[];
};

type Metrics = {
  productCount: number;
  suggestedProductsCount: number;
  outOfStockCount: number;
  lowStockCount: number;
  totalSuggestedUnits: number;
  totalEstimatedCostCents: number;
};

const { show: showToast } = useToast();

const loading = ref(false);
const error = ref<string | null>(null);
const horizonDays = ref(14);
const safetyPercent = ref(20);
const selectedCategory = ref("");
const showAll = ref(false);
const products = ref<OrderSuggestionRow[]>([]);
const metrics = ref<Metrics>({
  productCount: 0,
  suggestedProductsCount: 0,
  outOfStockCount: 0,
  lowStockCount: 0,
  totalSuggestedUnits: 0,
  totalEstimatedCostCents: 0,
});
const manualUnits = ref<Record<string, number>>({});

const categoryOptions = computed(() =>
  Array.from(new Set(products.value.map((p) => p.category || "Allgemein"))).sort((a, b) => a.localeCompare(b, "de"))
);

const visibleProducts = computed(() => {
  return products.value.filter((p) => {
    if (selectedCategory.value && p.category !== selectedCategory.value) return false;
    if (!showAll.value && p.suggested_units <= 0) return false;
    return true;
  });
});

const acceptedRows = computed(() =>
  visibleProducts.value
    .map((p) => ({
      ...p,
      effectiveUnits: effectiveUnits(p),
      effectivePackages: effectivePackages(p),
      effectiveCostCents: effectiveCostCents(p),
    }))
    .filter((p) => p.effectiveUnits > 0)
);

const acceptedUnits = computed(() => acceptedRows.value.reduce((sum, p) => sum + p.effectiveUnits, 0));
const acceptedCostCents = computed(() => acceptedRows.value.reduce((sum, p) => sum + p.effectiveCostCents, 0));
const acceptedProductCount = computed(() => acceptedRows.value.length);

function euro(cents: number) {
  return fmt(Number(cents ?? 0) / 100);
}

function clampInteger(value: unknown, min: number, max: number, fallback: number) {
  const n = Math.trunc(Number(value));
  return Number.isFinite(n) ? Math.max(min, Math.min(max, n)) : fallback;
}

function normalizeParams() {
  horizonDays.value = clampInteger(horizonDays.value, 1, 60, 14);
  safetyPercent.value = clampInteger(safetyPercent.value, 0, 100, 20);
}

function getManualUnits(productId: string) {
  const value = manualUnits.value[productId];
  return Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : null;
}

function effectiveUnits(row: OrderSuggestionRow) {
  return getManualUnits(row.product_id) ?? Number(row.suggested_units ?? 0);
}

function effectivePackages(row: OrderSuggestionRow) {
  const units = effectiveUnits(row);
  const packageSize = Math.max(1, Math.trunc(Number(row.package_size ?? 1)));
  return packageSize > 1 ? Math.ceil(units / packageSize) : units;
}

function effectiveCostCents(row: OrderSuggestionRow) {
  return effectiveUnits(row) * Number(row.last_purchase_price_cents ?? 0);
}

function updateManualUnits(row: OrderSuggestionRow, value: string) {
  const next = clampInteger(value, 0, 100000, row.suggested_units);
  manualUnits.value = {
    ...manualUnits.value,
    [row.product_id]: next,
  };
}

function onManualUnitsInput(row: OrderSuggestionRow, event: Event) {
  const target = event.target as HTMLInputElement | null;
  updateManualUnits(row, target?.value ?? "");
}

function resetManualUnits(row: OrderSuggestionRow) {
  const next = { ...manualUnits.value };
  delete next[row.product_id];
  manualUnits.value = next;
}

function statusLabel(row: OrderSuggestionRow) {
  if (row.stock_status === "out_of_stock") return "leer";
  if (row.stock_status === "low") return "niedrig";
  if (row.stock_status === "no_demand") return "ohne Bedarf";
  return "ok";
}

function trendLabel(value: OrderSuggestionRow["trend"]) {
  if (value === "rising") return "steigend";
  if (value === "falling") return "fallend";
  return "stabil";
}

function reachLabel(value: number | null) {
  if (value === null || value === undefined) return "-";
  if (value >= 999) return ">999";
  return Number(value).toFixed(1);
}

async function loadSuggestions() {
  normalizeParams();
  loading.value = true;
  error.value = null;
  try {
    const data = await adminRpc("get_order_suggestions", {
      horizon_days: horizonDays.value,
      safety_percent: safetyPercent.value,
    });
    products.value = Array.isArray(data?.products) ? data.products : [];
    metrics.value = { ...metrics.value, ...(data?.metrics ?? {}) };
    manualUnits.value = {};
  } catch (err) {
    console.error("[AdminOrderSuggestions]", err);
    error.value = err instanceof Error ? err.message : "Bestellvorschlag konnte nicht geladen werden";
    showToast("Bestellvorschlag konnte nicht geladen werden");
  } finally {
    loading.value = false;
  }
}

function copyOrderList() {
  const lines = acceptedRows.value.map((p) => {
    const packageText = p.package_size > 1 ? ` (${p.effectivePackages} x ${p.package_size})` : "";
    return `${p.name}: ${p.effectiveUnits} Stk.${packageText}`;
  });
  const text = lines.join("\n");
  void navigator.clipboard?.writeText(text);
  showToast("Bestellliste kopiert");
}

onMounted(loadSuggestions);
</script>

<template>
  <div class="space-y-6" data-report-id="admin-order-suggestions">
    <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
      <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <h2 class="text-xl font-semibold text-primary">Bestellvorschlag</h2>
          <p class="mt-1 text-sm text-slate-600">
            Automatische Vorschläge aus Absatz, Bestand, Reichweite und Packungsgröße.
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            class="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-50"
            :disabled="!acceptedRows.length"
            @click="copyOrderList"
          >
            Liste kopieren
          </button>
          <button
            type="button"
            class="rounded-xl bg-primary px-4 py-2 text-sm font-semibold text-white hover:bg-primary/90 disabled:opacity-50"
            :disabled="loading"
            @click="loadSuggestions"
          >
            {{ loading ? "Lädt..." : "Neu berechnen" }}
          </button>
        </div>
      </div>

      <div class="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-[1fr_1fr_auto] xl:items-end">
        <label class="block">
          <span class="mb-1 block text-xs font-semibold uppercase text-slate-500">Bestellhorizont</span>
          <div class="flex items-center gap-2">
            <input v-model.number="horizonDays" type="number" min="1" max="60" class="h-10 w-full rounded-xl border border-slate-300 px-3 text-sm" />
            <span class="text-sm text-slate-500">Tage</span>
          </div>
        </label>
        <label class="block">
          <span class="mb-1 block text-xs font-semibold uppercase text-slate-500">Sicherheitsaufschlag</span>
          <div class="flex items-center gap-2">
            <input v-model.number="safetyPercent" type="number" min="0" max="100" class="h-10 w-full rounded-xl border border-slate-300 px-3 text-sm" />
            <span class="text-sm text-slate-500">%</span>
          </div>
        </label>
        <button type="button" class="h-10 rounded-xl border border-primary bg-white px-4 text-sm font-semibold text-primary hover:bg-primary/5" @click="loadSuggestions">
          Anwenden
        </button>
      </div>
    </section>

    <p v-if="error" class="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm font-semibold text-red-700">{{ error }}</p>

    <section class="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">Artikel geprüft</div>
        <div class="mt-1 text-2xl font-semibold text-primary">{{ metrics.productCount }}</div>
        <div class="text-xs text-slate-500">{{ metrics.suggestedProductsCount }} mit Vorschlag</div>
      </div>
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">Niedrige Reichweite</div>
        <div class="mt-1 text-2xl font-semibold text-amber-700">{{ metrics.lowStockCount }}</div>
        <div class="text-xs text-slate-500">{{ metrics.outOfStockCount }} leer</div>
      </div>
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">Vorschlag System</div>
        <div class="mt-1 text-2xl font-semibold text-primary">{{ metrics.totalSuggestedUnits }}</div>
        <div class="text-xs text-slate-500">{{ euro(metrics.totalEstimatedCostCents) }}</div>
      </div>
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">Aktuelle Liste</div>
        <div class="mt-1 text-2xl font-semibold text-emerald-700">{{ acceptedUnits }}</div>
        <div class="text-xs text-slate-500">{{ acceptedProductCount }} Artikel</div>
      </div>
      <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div class="text-xs font-semibold uppercase text-slate-500">Kosten geschätzt</div>
        <div class="mt-1 text-2xl font-semibold text-slate-900">{{ euro(acceptedCostCents) }}</div>
        <div class="text-xs text-slate-500">auf Basis letzter EK</div>
      </div>
    </section>

    <section class="rounded-xl border border-slate-200 bg-white shadow-sm">
      <div class="flex flex-col gap-3 border-b border-slate-200 p-4 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h3 class="font-semibold text-primary">Vorschläge</h3>
          <p class="text-xs text-slate-500">Menge kann vor dem Kopieren überschrieben werden.</p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <select v-model="selectedCategory" class="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
            <option value="">Alle Kategorien</option>
            <option v-for="category in categoryOptions" :key="category" :value="category">{{ category }}</option>
          </select>
          <label class="flex items-center gap-2 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-700">
            <input v-model="showAll" type="checkbox" class="accent-primary" />
            Alle Artikel
          </label>
        </div>
      </div>

      <div v-if="loading" class="p-8 text-center text-slate-500">Bestellvorschlag wird berechnet...</div>
      <div v-else class="overflow-x-auto">
        <table class="min-w-full text-sm">
          <thead class="bg-slate-100 text-xs uppercase text-primary">
            <tr>
              <th class="px-4 py-3 text-left">Artikel</th>
              <th class="px-4 py-3 text-right">Bestand</th>
              <th class="px-4 py-3 text-right">Absatz 14/30/90</th>
              <th class="px-4 py-3 text-right">Reichweite</th>
              <th class="px-4 py-3 text-right">Ziel</th>
              <th class="px-4 py-3 text-right">System</th>
              <th class="px-4 py-3 text-right">Bestellen</th>
              <th class="px-4 py-3 text-right">Kosten</th>
              <th class="px-4 py-3 text-left">Hinweis</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-slate-100">
            <tr v-for="p in visibleProducts" :key="p.product_id" class="hover:bg-slate-50">
              <td class="px-4 py-3">
                <div class="font-semibold text-slate-900">{{ p.name }}</div>
                <div class="mt-1 flex flex-wrap gap-1 text-xs">
                  <span class="rounded-full bg-slate-100 px-2 py-0.5 text-slate-600">{{ p.category }}</span>
                  <span class="rounded-full px-2 py-0.5" :class="p.stock_status === 'out_of_stock' ? 'bg-red-100 text-red-700' : p.stock_status === 'low' ? 'bg-amber-100 text-amber-700' : 'bg-emerald-100 text-emerald-700'">
                    {{ statusLabel(p) }}
                  </span>
                  <span class="rounded-full bg-blue-50 px-2 py-0.5 text-blue-700">{{ trendLabel(p.trend) }}</span>
                </div>
              </td>
              <td class="px-4 py-3 text-right tabular-nums">{{ p.current_stock }}</td>
              <td class="px-4 py-3 text-right tabular-nums">
                {{ p.sold_14 }} / {{ p.sold_30 }} / {{ p.sold_90 }}
                <div v-if="p.mhd_90 > 0" class="text-xs text-amber-700">MHD {{ p.mhd_share_percent }}%</div>
              </td>
              <td class="px-4 py-3 text-right tabular-nums">{{ reachLabel(p.reach_days) }} Tage</td>
              <td class="px-4 py-3 text-right tabular-nums">{{ p.target_stock }}</td>
              <td class="px-4 py-3 text-right tabular-nums">
                {{ p.suggested_units }}
                <div v-if="p.package_size > 1" class="text-xs text-slate-500">{{ p.suggested_packages }} x {{ p.package_size }}</div>
              </td>
              <td class="px-4 py-3 text-right">
                <div class="flex items-center justify-end gap-2">
                  <input
                    type="number"
                    min="0"
                    class="h-9 w-24 rounded-xl border border-slate-300 px-2 text-right tabular-nums"
                    :value="effectiveUnits(p)"
                    @input="onManualUnitsInput(p, $event)"
                  />
                  <button
                    type="button"
                    class="rounded-lg border border-slate-300 px-2 py-1 text-xs font-semibold text-slate-600 hover:bg-slate-50"
                    @click="resetManualUnits(p)"
                  >
                    Reset
                  </button>
                </div>
                <div v-if="p.package_size > 1" class="mt-1 text-xs text-slate-500">{{ effectivePackages(p) }} Pack.</div>
              </td>
              <td class="px-4 py-3 text-right tabular-nums">{{ euro(effectiveCostCents(p)) }}</td>
              <td class="px-4 py-3">
                <div class="text-xs font-semibold" :class="p.confidence === 'hoch' ? 'text-emerald-700' : p.confidence === 'mittel' ? 'text-amber-700' : 'text-red-700'">
                  Konfidenz {{ p.confidence }}
                </div>
                <div v-if="p.warnings?.length" class="mt-1 max-w-[260px] text-xs text-slate-600">
                  {{ p.warnings.join(", ") }}
                </div>
              </td>
            </tr>
          </tbody>
        </table>
        <div v-if="!visibleProducts.length" class="p-8 text-center text-slate-500">
          Keine Bestellvorschläge für die aktuelle Auswahl.
        </div>
      </div>
    </section>
  </div>
</template>
