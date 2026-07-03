<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { syncQueue } from "@/pwa/offlineSync";
import { useDeviceAuthStore } from "@/stores/useDeviceAuthStore";
import {
  deleteQueueEntry,
  getCachedMembers,
  getCachedProducts,
  getQueueEntries,
  resetFailedQueueRetries,
  resetQueueEntryRetry,
  type QueueEntry,
} from "@/utils/offlineDB";

type QueueRow = QueueEntry & {
  id: number;
  operation: string;
  memberName: string;
  productName: string;
};

const deviceAuth = useDeviceAuthStore();
const loading = ref(false);
const syncing = ref(false);
const message = ref("");
const queueEntries = ref<QueueEntry[]>([]);
const productsById = ref<Record<string, any>>({});
const membersById = ref<Record<string, any>>({});

const rows = computed<QueueRow[]>(() =>
  queueEntries.value
    .filter((entry) => entry.status === "pending" || entry.status === "failed")
    .map((entry) => {
      const payload = entry.payload ?? {};
      const id = Number(entry.id ?? 0);
      const isCancel = Object.prototype.hasOwnProperty.call(payload, "cancel_tx_id");
      const product = payload.product_id ? productsById.value[payload.product_id] : null;
      const member = payload.member_id ? membersById.value[payload.member_id] : null;

      return {
        ...entry,
        id,
        operation: isCancel ? "Storno" : payload.product_id ? "Artikelbuchung" : "Freier Betrag",
        memberName: member?.name ?? payload.member_id ?? "-",
        productName: product?.name ?? payload.note ?? payload.product_id ?? "-",
      };
    })
    .filter((entry) => entry.id > 0)
    .sort((a, b) => a.id - b.id)
);

const pendingCount = computed(
  () => rows.value.filter((entry) => entry.status === "pending").length
);
const failedCount = computed(
  () => rows.value.filter((entry) => entry.status === "failed").length
);

async function loadQueue() {
  loading.value = true;
  message.value = "";
  try {
    const [queue, products, members] = await Promise.all([
      getQueueEntries(),
      getCachedProducts(),
      getCachedMembers(),
    ]);

    queueEntries.value = queue;
    productsById.value = Object.fromEntries(
      products.map((product: any) => [product.id, product])
    );
    membersById.value = Object.fromEntries(
      members.map((member: any) => [member.id, member])
    );
  } catch (err) {
    console.error("[AdminSyncQueue.loadQueue]", err);
    message.value = "⚠️ Queue konnte nicht geladen werden";
  } finally {
    loading.value = false;
  }
}

function formatDate(value?: number) {
  if (!value) return "-";
  return new Intl.DateTimeFormat("de-DE", {
    dateStyle: "short",
    timeStyle: "medium",
  }).format(new Date(value));
}

function retryLabel(entry: QueueRow) {
  if (entry.status !== "failed") return "bereit";
  if (entry.retryClass === "fatal") return "gesperrt";
  const nextRetryAt = Number(entry.nextRetryAt ?? 0);
  if (nextRetryAt > Date.now()) return "wartet";
  return "faellig";
}

async function resetOne(entry: QueueRow) {
  try {
    await resetQueueEntryRetry(entry.id);
    message.value = `Queue-Eintrag ${entry.id} fuer Retry freigegeben`;
    await loadQueue();
  } catch (err) {
    console.error("[AdminSyncQueue.resetOne]", err);
    message.value = "⚠️ Retry-Freigabe fehlgeschlagen";
  }
}

async function deleteOne(entry: QueueRow) {
  const ok = window.confirm(
    `Queue-Eintrag ${entry.id} wirklich löschen?\n\n` +
      "Diese lokale Buchung wird danach nicht mehr synchronisiert."
  );
  if (!ok) return;

  try {
    await deleteQueueEntry(entry.id);
    message.value = `Queue-Eintrag ${entry.id} gelöscht`;
    await loadQueue();
    window.dispatchEvent(
      new CustomEvent("queue-synced", {
        detail: { deleted_queue_id: entry.id },
      })
    );
  } catch (err) {
    console.error("[AdminSyncQueue.deleteOne]", err);
    message.value = "⚠️ Queue-Eintrag konnte nicht gelöscht werden";
  }
}

async function resetAllFailed() {
  try {
    const count = await resetFailedQueueRetries();
    message.value = `${count} fehlgeschlagene Eintraege fuer Retry freigegeben`;
    await loadQueue();
  } catch (err) {
    console.error("[AdminSyncQueue.resetAllFailed]", err);
    message.value = "⚠️ Retry-Freigabe fehlgeschlagen";
  }
}

async function runSyncNow() {
  if (syncing.value) return;
  await deviceAuth.initFromStorage();
  if (!deviceAuth.token) {
    message.value = "Dieses Geraet ist nicht als Terminal authentifiziert.";
    return;
  }
  if (!navigator.onLine) {
    message.value = "Offline - Sync kann erst online laufen.";
    return;
  }

  syncing.value = true;
  try {
    const processed = await syncQueue(deviceAuth.token);
    if (processed > 0) {
      window.dispatchEvent(new CustomEvent("queue-synced", { detail: { processed } }));
    }
    message.value = `${processed} Eintraege synchronisiert`;
    await loadQueue();
  } catch (err) {
    console.error("[AdminSyncQueue.runSyncNow]", err);
    message.value = "⚠️ Sync fehlgeschlagen";
  } finally {
    syncing.value = false;
  }
}

async function resetAllAndSync() {
  await resetAllFailed();
  await runSyncNow();
}

onMounted(async () => {
  try {
    await deviceAuth.initFromStorage();
  } catch (err) {
    console.error("[AdminSyncQueue.onMounted]", err);
  }
  await loadQueue();
});
</script>

<template>
  <div class="space-y-6">
    <div class="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
      <div>
        <h2 class="text-2xl font-semibold text-gray-900">Sync-Queue</h2>
        <p class="mt-1 text-sm text-gray-600">
          Lokale Pending- und Failed-Buchungen dieses Browsers.
        </p>
      </div>
      <div class="flex flex-wrap gap-2">
        <button
          class="rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          :disabled="loading || syncing"
          @click="loadQueue"
        >
          Aktualisieren
        </button>
        <button
          class="rounded-md border border-blue-700 bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          :disabled="loading || syncing"
          @click="runSyncNow"
        >
          {{ syncing ? "Synchronisiert..." : "Sync jetzt starten" }}
        </button>
        <button
          class="rounded-md border border-amber-700 bg-amber-600 px-4 py-2 text-sm font-medium text-white hover:bg-amber-700 disabled:opacity-50"
          :disabled="loading || syncing || failedCount === 0"
          @click="resetAllAndSync"
        >
          Faileds freigeben & syncen
        </button>
      </div>
    </div>

    <div class="grid gap-3 sm:grid-cols-3">
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Pending</div>
        <div class="mt-1 text-2xl font-semibold text-gray-900">{{ pendingCount }}</div>
      </div>
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Failed</div>
        <div class="mt-1 text-2xl font-semibold text-red-700">{{ failedCount }}</div>
      </div>
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Gesamt</div>
        <div class="mt-1 text-2xl font-semibold text-gray-900">{{ rows.length }}</div>
      </div>
    </div>

    <div v-if="message" class="rounded-md border border-blue-200 bg-blue-50 px-4 py-3 text-sm text-blue-900">
      {{ message }}
    </div>

    <div class="overflow-x-auto rounded-lg border border-gray-200 bg-white">
      <table class="min-w-full divide-y divide-gray-200 text-sm">
        <thead class="bg-gray-50 text-left text-xs font-semibold uppercase tracking-wide text-gray-500">
          <tr>
            <th class="px-4 py-3">ID</th>
            <th class="px-4 py-3">Status</th>
            <th class="px-4 py-3">Retries</th>
            <th class="px-4 py-3">Naechster Retry</th>
            <th class="px-4 py-3">Typ</th>
            <th class="px-4 py-3">Mitglied</th>
            <th class="px-4 py-3">Buchung</th>
            <th class="px-4 py-3">Fehler</th>
            <th class="px-4 py-3 text-right">Aktion</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-100">
          <tr v-if="loading">
            <td colspan="9" class="px-4 py-8 text-center text-gray-500">
              Queue wird geladen...
            </td>
          </tr>
          <tr v-else-if="rows.length === 0">
            <td colspan="9" class="px-4 py-8 text-center text-gray-500">
              Keine lokalen Queue-Eintraege vorhanden.
            </td>
          </tr>
          <template v-else>
            <tr v-for="entry in rows" :key="entry.id" class="hover:bg-gray-50">
              <td class="px-4 py-3 font-mono text-xs text-gray-600">{{ entry.id }}</td>
              <td class="px-4 py-3">
                <span
                  class="rounded-full px-2 py-1 text-xs font-semibold"
                  :class="entry.status === 'failed' ? 'bg-red-100 text-red-700' : 'bg-amber-100 text-amber-800'"
                >
                  {{ entry.status }} / {{ retryLabel(entry) }}
                </span>
              </td>
              <td class="px-4 py-3 text-right tabular-nums">{{ entry.attempts ?? 0 }}</td>
              <td class="px-4 py-3 whitespace-nowrap">{{ formatDate(entry.nextRetryAt) }}</td>
              <td class="px-4 py-3">{{ entry.operation }}</td>
              <td class="px-4 py-3">{{ entry.memberName }}</td>
              <td class="px-4 py-3">{{ entry.productName }}</td>
              <td class="max-w-[24rem] px-4 py-3">
                <div class="truncate" :title="entry.lastError || ''">
                  {{ entry.lastError || "-" }}
                </div>
              </td>
              <td class="px-4 py-3 text-right">
                <div class="flex justify-end gap-2">
                  <button
                    class="rounded-md border border-gray-300 bg-white px-3 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50"
                    :disabled="syncing"
                    @click="resetOne(entry)"
                  >
                    Retry freigeben
                  </button>
                  <button
                    class="rounded-md border border-red-700 bg-red-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-red-700 disabled:opacity-50"
                    :disabled="syncing"
                    @click="deleteOne(entry)"
                  >
                    Löschen
                  </button>
                </div>
              </td>
            </tr>
          </template>
        </tbody>
      </table>
    </div>
  </div>
</template>
