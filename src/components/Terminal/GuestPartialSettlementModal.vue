<script setup lang="ts">
import { ref, computed, watch } from "vue";
import BaseModal from "@/components/BaseModal.vue";
import { useModal } from "@/composables/useModal";

const props = defineProps<{
  show: boolean;
  memberId: string;
  memberName: string;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "confirm", payload?: { guestEnded?: boolean }): void;
}>();

const loading = ref(false);
const error = ref<string | null>(null);
const transactions = ref<any[]>([]);
const selected = ref<Set<string>>(new Set());
const { confirm: confirmModal } = useModal();

// 🔹 Gruppierung nach Produkt oder Notiz
type Group = {
  key: string;
  name: string;
  txs: any[];
  total: number;
};

const grouped = computed<Group[]>(() => {
  const map = new Map<string, Group>();

  for (const tx of transactions.value) {
    const name = tx.product_name ?? tx.note ?? "frei";
    const key = tx.product_id ? `prod-${tx.product_id}` : `note-${name}`;
    if (!map.has(key)) {
      map.set(key, { key, name, txs: [tx], total: tx.amount });
    } else {
      const g = map.get(key)!;
      g.txs.push(tx);
      g.total += tx.amount;
    }
  }

  return Array.from(map.values()).sort((a, b) =>
    a.name.localeCompare(b.name, "de")
  );
});

// 💰 Teilsumme der Auswahl
const totalSelected = computed(() =>
  transactions.value
    .filter((tx) => selected.value.has(tx.id))
    .reduce((sum, tx) => sum + tx.amount, 0)
);

// Auswahlsteuerung
function toggleTx(id: string) {
  if (selected.value.has(id)) selected.value.delete(id);
  else selected.value.add(id);
}

function toggleGroup(g: Group) {
  const allSelected = g.txs.every((tx) => selected.value.has(tx.id));
  g.txs.forEach((tx) =>
    allSelected ? selected.value.delete(tx.id) : selected.value.add(tx.id)
  );
}

function isGroupFullySelected(g: Group) {
  return g.txs.length > 0 && g.txs.every((tx) => selected.value.has(tx.id));
}

// 🧾 Daten laden (nur offene Transaktionen)
async function loadTransactions() {
  if (!props.show || !props.memberId) return;
  loading.value = true;
  error.value = null;
  selected.value.clear();

  try {
    const token = localStorage.getItem("device_token");
    const res = await fetch("/api/get-member-bookings", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        member_id: props.memberId,
        start: "1970-01-01T00:00:00.000Z",
        end: new Date().toISOString(),
        exclude_settled: true, // ✅ jetzt NUR offene Transaktionen laden
      }),
    });

    const result = await res.json();
    if (!res.ok) throw new Error(result.error || "Fehler beim Laden");

    const flat: any[] = (result.data || []).flatMap((g: any) => g.items || []);
    transactions.value = flat;
  } catch (e: any) {
    error.value = e.message;
  } finally {
    loading.value = false;
  }
}

// ✅ Teilabrechnung bestätigen
async function confirmPartialSettlement() {
  try {
    const token = localStorage.getItem("device_token");
    const ids = Array.from(selected.value);
    if (ids.length === 0) {
      error.value = "Keine Transaktionen ausgewählt";
      return;
    }

    const res = await fetch("/api/device-settle-guest-partial", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        member_id: props.memberId,
        transaction_ids: ids,
      }),
    });

    const result = await res.json();
    if (!res.ok) throw new Error(result.error || "Fehler beim Abrechnen");

    let guestEnded = false;
    const remainingOpen = Number(result.remaining_open_transactions ?? -1);

    if (remainingOpen === 0) {
      const shouldEndGuest = await confirmModal(
        "Gast beenden?",
        `Danach sind keine offenen Buchungen mehr vorhanden.\nSoll ${props.memberName} als beendet markiert werden?`,
        { danger: true }
      );

      if (shouldEndGuest) {
        const settleRes = await fetch("/api/device-settle-guest", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ member_id: props.memberId }),
        });
        const settleResult = await settleRes.json();
        if (!settleRes.ok) {
          throw new Error(
            settleResult.error || "Teilabrechnung ok, Gast konnte nicht beendet werden"
          );
        }
        guestEnded = true;
      }
    }

    emit("confirm", { guestEnded });
  } catch (e: any) {
    error.value = e.message;
  }
}

watch(() => props.show, loadTransactions);
</script>

<template>
  <BaseModal
    :show="show"
    :title="`💶 Teilabrechnung – ${memberName}`"
    confirm-label="Teil abrechnen"
    cancel-label="Abbrechen"
    :danger="true"
    @close="emit('close')"
    @confirm="confirmPartialSettlement"
  >
    <!-- Ladezustände -->
    <div v-if="loading" class="py-6 text-center text-gray-400">
      Lade Transaktionen …
    </div>

    <div v-else-if="error" class="text-red-600 text-sm py-3">{{ error }}</div>

    <!-- Gruppierte offene Transaktionen -->
    <ul
      v-else
      class="divide-y divide-gray-100 max-h-96 overflow-y-auto text-sm mt-2"
    >
      <li
        v-for="g in grouped"
        :key="g.key"
        class="py-2 space-y-1 group hover:bg-gray-50 rounded-xl transition-colors duration-150 px-2"
      >
        <!-- Gruppenüberschrift -->
        <div
          class="flex justify-between items-center cursor-pointer"
          @click="g.txs.length > 1 && toggleGroup(g)"
        >
          <label class="flex items-center gap-2 font-medium cursor-pointer">
            <input
              type="checkbox"
              :checked="isGroupFullySelected(g)"
              @change="toggleGroup(g)"
            />
            <span>
              {{ g.name }}
              <span v-if="g.txs.length > 1" class="text-gray-500">
                ×{{ g.txs.length }}
              </span>
            </span>
          </label>
          <span
            class="font-mono"
            :class="
              isGroupFullySelected(g) ? 'text-green-600' : 'text-gray-700'
            "
          >
            {{ (g.total / 100).toFixed(2) }} €
          </span>
        </div>

        <!-- Einzeltransaktionen -->
        <ul
          v-if="g.txs.length > 1"
          class="ml-6 mt-1 space-y-1 border-l border-gray-200 pl-3"
        >
          <li
            v-for="tx in g.txs"
            :key="tx.id"
            class="flex justify-between items-center hover:bg-gray-100 rounded-md px-2 py-1 transition"
          >
            <label class="flex items-center gap-2">
              <input
                type="checkbox"
                :checked="selected.has(tx.id)"
                @change="toggleTx(tx.id)"
              />
              <span>Eintrag</span>
            </label>
            <span
              class="font-mono"
              :class="selected.has(tx.id) ? 'text-green-600' : 'text-gray-600'"
            >
              {{ (tx.amount / 100).toFixed(2) }} €
            </span>
          </li>
        </ul>
      </li>
    </ul>

    <!-- Gesamtsumme unten -->
    <div
      class="mt-3 pt-3 border-t text-right font-semibold"
      :class="totalSelected < 0 ? 'text-red-600' : 'text-green-600'"
    >
      Auswahl: {{ (totalSelected / 100).toFixed(2) }} €
    </div>
  </BaseModal>
</template>

<style scoped>
ul::-webkit-scrollbar {
  width: 6px;
}
ul::-webkit-scrollbar-thumb {
  background: #cbd5e1;
  border-radius: 3px;
}
ul::-webkit-scrollbar-thumb:hover {
  background: #94a3b8;
}
.group:hover {
  box-shadow: inset 0 0 0 1px #e2e8f0;
}
</style>
