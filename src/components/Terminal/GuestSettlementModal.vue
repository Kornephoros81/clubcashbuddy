<script setup lang="ts">
import { ref, watch, computed } from "vue";
import BaseModal from "@/components/BaseModal.vue";

const props = defineProps<{
  show: boolean;
  memberId: string;
  memberName: string;
}>();
const emit = defineEmits<{
  (e: "close"): void;
  (e: "confirm"): void;
}>();

const loading = ref(false);
const error = ref<string | null>(null);

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

async function loadAllBookings() {
  if (!props.show || !props.memberId) return;
  loading.value = true;
  error.value = null;
  rawItems.value = [];
  try {
    const deviceToken = localStorage.getItem("device_token");
    if (!deviceToken) throw new Error("Kein Geräte-Token gefunden");

    // nutzt denselben API-Weg wie MemberBookings.vue
    const start = "1970-01-01T00:00:00.000Z";
    const end = new Date().toISOString();

    const res = await fetch("/api/get-member-bookings", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${deviceToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        member_id: props.memberId,
        start,
        end,
        exclude_settled: true, // ⬅️ Alle Transaktionen
      }),
    });

    const result = await res.json();
    if (!res.ok || result.error)
      throw new Error(result.error || "Abruf fehlgeschlagen");

    // API liefert gruppiert nach local_day → flach ziehen
    const flat: any[] = (result.data || []).flatMap((g: any) => g.items || []);

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

watch(() => props.show, loadAllBookings);
watch(() => props.memberId, loadAllBookings);
</script>

<template>
  <BaseModal
    :show="show"
    :title="`🧾 Gast abrechnen – ${memberName}`"
    confirm-label="Geld erhalten - Gastkonto schließen"
    cancel-label="Abbrechen"
    :danger="true"
    @close="emit('close')"
    @confirm="emit('confirm')"
  >
    <div class="space-y-3">
      <p class="text-sm text-gray-600">
        Unten siehst du die Buchungen des Gastes. Mit
        <strong>„Geld erhalten - Gastkonto schließen“</strong> bestätigst du die
        Abrechnung.
      </p>

      <div v-if="loading" class="py-6 text-center text-gray-400">
        Lade Buchungen …
      </div>

      <div v-else-if="error" class="py-3 text-red-600 text-sm">
        {{ error }}
      </div>

      <div v-else>
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
              :class="g.amount < 0 ? 'text-red-600' : 'text-green-600'"
            >
              {{ (Math.abs(g.amount) / 100).toFixed(2) }} €
            </div>
          </li>
        </ul>

        <p v-else class="py-3 text-gray-500 text-sm">
          Keine Buchungen vorhanden.
        </p>

        <div
          class="mt-3 pt-3 border-t text-right font-semibold"
          :class="total < 0 ? 'text-red-600' : 'text-green-600'"
        >
          Zu zahlen: {{ (Math.abs(total) / 100).toFixed(2) }} €
        </div>
      </div>
    </div>
  </BaseModal>
</template>
