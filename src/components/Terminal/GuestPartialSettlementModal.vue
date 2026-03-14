<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useModal } from "@/composables/useModal";
import {
  clearMemberBookingsCache,
  fetchMemberBookingsCached,
} from "@/utils/memberBookingsCache";

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

type Group = {
  key: string;
  name: string;
  txs: any[];
  total: number;
};

const grouped = computed<Group[]>(() => {
  const map = new Map<string, Group>();

  for (const tx of transactions.value) {
    const name = tx.product_name ?? tx.note ?? "Freier Betrag";
    const key = tx.product_id ? `prod-${tx.product_id}` : `note-${name}`;
    const current = map.get(key);
    if (current) {
      current.txs.push(tx);
      current.total += tx.amount;
      continue;
    }
    map.set(key, {
      key,
      name,
      txs: [tx],
      total: tx.amount,
    });
  }

  for (const group of map.values()) {
    group.txs.sort((a, b) => {
      const aTime = new Date(a.created_at ?? 0).getTime();
      const bTime = new Date(b.created_at ?? 0).getTime();
      return aTime - bTime || String(a.id).localeCompare(String(b.id), "de");
    });
  }

  return Array.from(map.values()).sort((a, b) => a.name.localeCompare(b.name, "de"));
});

const totalSelected = computed(() =>
  transactions.value
    .filter((tx) => selected.value.has(tx.id))
    .reduce((sum, tx) => sum + tx.amount, 0)
);

const selectedCount = computed(() => selected.value.size);

function selectedCountForGroup(group: Group) {
  return group.txs.filter((tx) => selected.value.has(tx.id)).length;
}

function amountForSelection(group: Group, count: number) {
  return group.txs.slice(0, count).reduce((sum, tx) => sum + tx.amount, 0);
}

function setGroupSelection(group: Group, count: number) {
  const limitedCount = Math.max(0, Math.min(count, group.txs.length));
  const nextSelected = new Set(selected.value);

  group.txs.forEach((tx, index) => {
    if (index < limitedCount) nextSelected.add(tx.id);
    else nextSelected.delete(tx.id);
  });

  selected.value = nextSelected;
}

function changeGroupSelection(group: Group, delta: number) {
  setGroupSelection(group, selectedCountForGroup(group) + delta);
}

async function loadTransactions() {
  if (!props.show || !props.memberId) return;
  loading.value = true;
  error.value = null;
  selected.value = new Set();

  try {
    const token = localStorage.getItem("device_token");
    if (!token) throw new Error("Kein Geräte-Token gefunden");
    const result = await fetchMemberBookingsCached({
      token,
      memberId: props.memberId,
      start: "1970-01-01T00:00:00.000Z",
      end: new Date().toISOString(),
      excludeSettled: true,
    });
    transactions.value = result.flatMap((g: any) => g.items || []);
  } catch (e: any) {
    error.value = e.message || "Transaktionen konnten nicht geladen werden";
    transactions.value = [];
  } finally {
    loading.value = false;
  }
}

async function confirmPartialSettlement() {
  try {
    const token = localStorage.getItem("device_token");
    if (!token) throw new Error("Kein Geräte-Token gefunden");

    const ids = Array.from(selected.value);
    if (ids.length === 0) {
      error.value = "Bitte mindestens eine Buchung auswählen";
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

    const result = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(result.error || "Fehler beim Abrechnen");
    clearMemberBookingsCache(props.memberId);

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
        const settleResult = await settleRes.json().catch(() => ({}));
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
    error.value = e.message || "Fehler bei der Teilabrechnung";
  }
}

watch(() => props.show, loadTransactions);
</script>

<template>
  <transition name="fade">
    <div
      v-if="show"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/45 p-3 backdrop-blur-sm"
    >
      <div
        class="glass-panel-strong flex w-full max-w-3xl flex-col overflow-hidden rounded-[30px]"
      >
        <div class="border-b border-slate-200 px-5 py-4">
          <div class="text-[0.72rem] font-bold uppercase tracking-[0.18em] text-emerald-600">
            Teilabrechnung
          </div>
          <h3 class="mt-1 text-xl font-semibold text-primary">
            Gast: {{ memberName }}
          </h3>
        </div>

        <div class="soft-scrollbar touch-scroll max-h-[65vh] overflow-y-auto px-4 py-4">
          <div v-if="loading" class="py-10 text-center text-gray-400">
            Lade Transaktionen …
          </div>

          <div
            v-else-if="error"
            class="rounded-2xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
          >
            {{ error }}
          </div>

          <div v-else-if="!grouped.length" class="py-10 text-center text-gray-400">
            Keine offenen Buchungen vorhanden.
          </div>

          <div v-else class="space-y-3">
            <section
              v-for="group in grouped"
              :key="group.key"
              class="rounded-[22px] border border-slate-200 bg-white px-4 py-3 shadow-[0_10px_28px_rgba(15,23,42,0.05)]"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0 flex-1">
                  <div class="text-[1.02rem] font-semibold text-slate-900 leading-tight">
                    {{ group.name }}
                  </div>
                </div>
                <div
                  class="shrink-0 rounded-full px-3 py-1 text-sm font-semibold"
                  :class="
                    selectedCountForGroup(group) > 0
                      ? 'bg-emerald-100 text-emerald-700'
                      : 'bg-slate-100 text-slate-600'
                  "
                >
                  {{ (Math.abs(amountForSelection(group, selectedCountForGroup(group))) / 100).toFixed(2) }} €
                </div>
              </div>

              <div class="mt-2 flex items-center gap-2">
                <button
                  @click="changeGroupSelection(group, -1)"
                  :disabled="selectedCountForGroup(group) === 0"
                  class="button-outline-strong flex h-10 w-10 items-center justify-center rounded-2xl border-slate-300 bg-white text-lg font-semibold text-slate-700 disabled:opacity-40"
                >
                  −
                </button>

                <div class="flex min-w-0 flex-1 items-center gap-2 overflow-x-auto pb-1">
                  <button
                    v-for="count in group.txs.length + 1"
                    :key="`${group.key}-${count - 1}`"
                    @click="setGroupSelection(group, count - 1)"
                    class="min-w-[3.75rem] rounded-2xl border px-3 py-1.5 text-sm font-semibold transition"
                    :class="
                      selectedCountForGroup(group) === count - 1
                        ? 'border-blue-700 bg-primary text-white shadow-sm'
                        : 'border-slate-300 bg-white text-slate-700 hover:border-blue-300 hover:bg-blue-50'
                    "
                  >
                    {{ count - 1 }}
                  </button>
                </div>

                <button
                  @click="changeGroupSelection(group, 1)"
                  :disabled="selectedCountForGroup(group) === group.txs.length"
                  class="button-outline-strong flex h-10 w-10 items-center justify-center rounded-2xl border-slate-300 bg-white text-lg font-semibold text-slate-700 disabled:opacity-40"
                >
                  +
                </button>
              </div>

              <div class="mt-2 text-sm text-slate-600">
                Auswahl:
                <span class="font-semibold text-slate-900">{{ selectedCountForGroup(group) }}</span>
                / {{ group.txs.length }}
              </div>
            </section>
          </div>
        </div>

        <div class="border-t border-slate-200 bg-white px-4 py-4">
          <div class="mb-3 flex items-center justify-between gap-3 rounded-[22px] bg-slate-50 px-4 py-3">
            <div>
              <div class="text-xs font-bold uppercase tracking-[0.16em] text-slate-500">
                Auswahl
              </div>
              <div class="text-sm text-slate-600">
                {{ selectedCount }} Buchung<span v-if="selectedCount !== 1">en</span> ausgewählt
              </div>
            </div>
            <div
              class="text-xl font-semibold"
              :class="selectedCount > 0 ? 'text-emerald-700' : 'text-slate-500'"
            >
              {{ (Math.abs(totalSelected) / 100).toFixed(2) }} €
            </div>
          </div>

          <div class="flex justify-end gap-3">
            <button
              @click="emit('close')"
              class="button-outline-strong rounded-2xl border-slate-300 bg-white px-5 py-3 text-base font-medium text-slate-700 hover:bg-slate-50"
            >
              Abbrechen
            </button>
            <button
              @click="confirmPartialSettlement"
              :disabled="selectedCount === 0"
              class="button-outline-strong rounded-2xl border-red-800 bg-red-600 px-5 py-3 text-base font-semibold text-white hover:bg-red-700 disabled:opacity-50"
            >
              Teil abrechnen
            </button>
          </div>
        </div>
      </div>
    </div>
  </transition>
</template>

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.25s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}
</style>
