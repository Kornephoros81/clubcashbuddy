<script setup lang="ts">
import { ref, watch, computed } from "vue";
import BaseModal from "@/components/BaseModal.vue";
import { useModal } from "@/composables/useModal";
import { fetchMemberBookingsCached } from "@/utils/memberBookingsCache";

const props = defineProps<{
  show: boolean;
  memberId: string;
  memberName: string;
}>();
const emit = defineEmits<{
  (e: "close"): void;
  (e: "confirm", payload?: { complimentaryProducts?: boolean }): void;
}>();

const loading = ref(false);
const error = ref<string | null>(null);
const complimentaryProducts = ref(false);
const { confirm: confirmModal } = useModal();

// rohe Einzeltransaktionen (ungrouped)
type RawTx = {
  id: string;
  amount: number;
  note?: string | null;
  created_at: string;
  product_id?: string | null;
  product_name?: string | null;
};
const rawItems = ref<RawTx[]>([]);

// Summe der heutigen Gesamtbeträge (aus Gruppen abgeleitet)
const total = computed(() =>
  groupedItems.value.reduce((s, g) => s + (g.amount || 0), 0)
);
const productBookingCount = computed(() =>
  rawItems.value.filter((tx) => !!tx.product_id).length
);
const nonProductTotal = computed(() =>
  rawItems.value
    .filter((tx) => !tx.product_id)
    .reduce((sum, tx) => sum + (tx.amount || 0), 0)
);
const payableTotal = computed(() =>
  complimentaryProducts.value ? nonProductTotal.value : total.value
);

// Gruppentyp
type Grouped = {
  key: string; // eindeutiger Schlüssel je Gruppe
  product_id: string | null; // ggf. null bei freien Buchungen
  name: string; // Produktname / Note / "frei"
  count: number; // Anzahl der Buchungen in der Gruppe
  amount: number; // Summe der Beträge der Gruppe (Cent)
};

// Alphabetisch sortierte Gruppen
const groupedItems = computed<Grouped[]>(() => {
  const map = new Map<string, Grouped>();

  for (const tx of rawItems.value) {
    const name = (tx.product_name ?? tx.note ?? "frei").toString();
    const key = tx.product_id ? `prod-${tx.product_id}` : `note-${name}`;

    if (!map.has(key)) {
      map.set(key, {
        key,
        product_id: tx.product_id ?? null,
        name,
        count: 1,
        amount: tx.amount || 0,
      });
    } else {
      const g = map.get(key)!;
      g.count += 1;
      g.amount += tx.amount || 0;
    }
  }

  // alphabetisch nach Name (de)
  return Array.from(map.values()).sort((a, b) =>
    a.name.localeCompare(b.name, "de")
  );
});

function displayGroupAmount(group: Grouped) {
  return complimentaryProducts.value && group.product_id ? 0 : group.amount;
}

async function loadAllBookings() {
  if (!props.show || !props.memberId) return;
  loading.value = true;
  error.value = null;
  complimentaryProducts.value = false;
  rawItems.value = [];
  try {
    const deviceToken = localStorage.getItem("device_token");
    if (!deviceToken) throw new Error("Kein Geräte-Token gefunden");

    // nutzt denselben API-Weg wie MemberBookings.vue
    const start = "1970-01-01T00:00:00.000Z";
    const end = new Date().toISOString();

    const result = await fetchMemberBookingsCached({
      token: deviceToken,
      memberId: props.memberId,
      start,
      end,
      excludeSettled: true,
    });

    // API liefert gruppiert nach local_day → flach ziehen
    const flat: any[] = result.flatMap((g: any) => g.items || []);

    // Normalisieren
    rawItems.value = flat.map((tx: any) => ({
      id: tx.id,
      amount: tx.amount,
      created_at: tx.created_at,
      note: tx.note ?? null,
      product_id: tx.product_id ?? null,
      product_name: tx.product_name ?? null,
    }));
  } catch (e: any) {
    console.error("[GuestSettlementModal] loadAllBookings", e);
    error.value = e?.message || "Fehler beim Laden";
  } finally {
    loading.value = false;
  }
}

async function confirmSettlement() {
  if (complimentaryProducts.value) {
    const ok = await confirmModal(
      "Freigetränke bestätigen?",
      `Alle Produktbuchungen dieser Abrechnung werden als Freigetränke gespeichert und nicht als Umsatz oder Gewinn gezählt.\n\nBetroffene Produktbuchungen: ${productBookingCount.value}`,
      { danger: true }
    );
    if (!ok) return;
  }

  emit("confirm", { complimentaryProducts: complimentaryProducts.value });
}

watch(() => props.show, loadAllBookings);
watch(() => props.memberId, loadAllBookings);
watch(productBookingCount, (count) => {
  if (count === 0) complimentaryProducts.value = false;
});
</script>

<template>
  <BaseModal
    :show="show"
    :title="`🧾 Gast abrechnen – ${memberName}`"
    :confirm-label="
      complimentaryProducts
        ? 'Freigetränke bestätigen - Gastkonto schließen'
        : 'Geld erhalten - Gastkonto schließen'
    "
    cancel-label="Abbrechen"
    :danger="true"
    @close="emit('close')"
    @confirm="confirmSettlement"
  >
    <div class="space-y-3">
      <p class="text-sm text-gray-600">
        Unten siehst du die Buchungen des Gastes. Der Abschluss übernimmt die
        aktuell gewählte Abrechnungsart.
      </p>

      <div v-if="loading" class="py-6 text-center text-gray-400">
        Lade Buchungen …
      </div>

      <div v-else-if="error" class="py-3 text-red-600 text-sm">
        {{ error }}
      </div>

      <div v-else>
        <label
          class="mb-3 flex items-center justify-between gap-3 rounded-2xl border border-amber-200 bg-amber-50 px-3 py-2.5 text-sm"
        >
          <span>
            <span class="block font-semibold text-amber-900">Als Freigetränke abrechnen</span>
            <span class="block text-xs text-amber-800">
              Produktbuchungen werden nicht umsatz- oder gewinnrelevant.
            </span>
          </span>
          <input
            v-model="complimentaryProducts"
            type="checkbox"
            :disabled="productBookingCount === 0"
            class="h-5 w-5 accent-amber-600"
          />
        </label>

        <ul
          v-if="groupedItems.length"
          class="divide-y divide-gray-100 max-h-80 overflow-y-auto"
        >
          <li
            v-for="g in groupedItems"
            :key="g.key"
            class="flex items-center justify-between py-2 text-sm"
          >
            <div class="pr-3">
              <div class="font-medium">
                {{ g.name }}
                <span v-if="g.count > 1" class="text-gray-500 ml-1"
                  >×{{ g.count }}</span
                >
              </div>
            </div>
            <div
              class="font-mono"
              :class="displayGroupAmount(g) < 0 ? 'text-red-600' : 'text-green-600'"
            >
              {{ (Math.abs(displayGroupAmount(g)) / 100).toFixed(2) }} €
            </div>
          </li>
        </ul>

        <p v-else class="py-3 text-gray-500 text-sm">
          Keine Buchungen vorhanden.
        </p>

        <div
          class="mt-3 pt-3 border-t text-right font-semibold"
          :class="payableTotal < 0 ? 'text-red-600' : 'text-green-600'"
        >
          Zu zahlen: {{ (Math.abs(payableTotal) / 100).toFixed(2) }} €
        </div>
      </div>
    </div>
  </BaseModal>
</template>
