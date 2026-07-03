<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { adminRpc } from "@/lib/adminApi";

type KioskDevice = {
  id: string;
  name: string;
  active: boolean;
  last_seen_at: string | null;
};

type SyncErrorRow = {
  id: string;
  created_at: string;
  device_id: string;
  device_name: string;
  client_queue_id: number | null;
  client_tx_id: string | null;
  operation: string;
  member_name: string | null;
  product_name: string | null;
  amount: number | null;
  transaction_type: string | null;
  note: string | null;
  error_message: string;
  retry_class: string | null;
  attempts: number;
  next_retry_at: string | null;
  payload: Record<string, unknown>;
};

const loading = ref(false);
const error = ref("");
const rows = ref<SyncErrorRow[]>([]);
const devices = ref<KioskDevice[]>([]);
const selectedDeviceId = ref("");
const sincePreset = ref("7d");
const limit = ref(200);

const failedCount = computed(() => rows.value.length);
const fatalCount = computed(
  () => rows.value.filter((row) => row.retry_class === "fatal").length
);
const retryableCount = computed(
  () => rows.value.filter((row) => row.retry_class === "retryable").length
);

function sinceValue() {
  const now = Date.now();
  if (sincePreset.value === "24h") return new Date(now - 24 * 60 * 60 * 1000).toISOString();
  if (sincePreset.value === "7d") return new Date(now - 7 * 24 * 60 * 60 * 1000).toISOString();
  if (sincePreset.value === "30d") return new Date(now - 30 * 24 * 60 * 60 * 1000).toISOString();
  return null;
}

function formatDate(value?: string | null) {
  if (!value) return "-";
  return new Intl.DateTimeFormat("de-DE", {
    dateStyle: "short",
    timeStyle: "medium",
  }).format(new Date(value));
}

function formatAmount(value: number | null) {
  if (value == null) return "-";
  return `${(value / 100).toFixed(2)} €`;
}

function operationLabel(value: string) {
  if (value === "cancel") return "Storno";
  if (value === "book") return "Buchung";
  return "Unbekannt";
}

function payloadPreview(row: SyncErrorRow) {
  try {
    return JSON.stringify(row.payload ?? {}, null, 2);
  } catch {
    return "{}";
  }
}

async function loadDevices() {
  const data = await adminRpc("list_kiosk_devices");
  devices.value = ((data as any[]) ?? []).map((device: any) => ({
    id: String(device.id),
    name: String(device.name ?? ""),
    active: Boolean(device.active),
    last_seen_at: device.last_seen_at ?? null,
  }));
}

async function loadErrors() {
  loading.value = true;
  error.value = "";
  try {
    const data = await adminRpc("list_device_sync_errors", {
      limit: limit.value,
      device_id: selectedDeviceId.value || null,
      since: sinceValue(),
    });
    rows.value = ((data as any[]) ?? []).map((row: any) => ({
      id: String(row.id),
      created_at: String(row.created_at),
      device_id: String(row.device_id),
      device_name: String(row.device_name ?? row.device_id ?? "-"),
      client_queue_id: row.client_queue_id ?? null,
      client_tx_id: row.client_tx_id ?? null,
      operation: String(row.operation ?? "unknown"),
      member_name: row.member_name || null,
      product_name: row.product_name || null,
      amount: row.amount == null ? null : Number(row.amount),
      transaction_type: row.transaction_type ?? null,
      note: row.note ?? null,
      error_message: String(row.error_message ?? ""),
      retry_class: row.retry_class ?? null,
      attempts: Number(row.attempts ?? 0),
      next_retry_at: row.next_retry_at ?? null,
      payload: row.payload ?? {},
    }));
  } catch (err: any) {
    console.error("[AdminSyncErrors.loadErrors]", err);
    error.value = err?.message || "Sync-Fehlerlog konnte nicht geladen werden";
  } finally {
    loading.value = false;
  }
}

async function refresh() {
  await Promise.all([loadDevices(), loadErrors()]);
}

onMounted(refresh);
</script>

<template>
  <div class="space-y-6">
    <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
      <div>
        <h2 class="text-2xl font-semibold text-gray-900">Globales Sync-Fehlerlog</h2>
        <p class="mt-1 text-sm text-gray-600">
          Zentral gemeldete Fehler aus den Terminal-Syncs aller Geräte.
        </p>
      </div>
      <button
        class="rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50"
        :disabled="loading"
        @click="refresh"
      >
        Aktualisieren
      </button>
    </div>

    <div class="grid gap-3 sm:grid-cols-3">
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Fehler im Filter</div>
        <div class="mt-1 text-2xl font-semibold text-gray-900">{{ failedCount }}</div>
      </div>
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Retryable</div>
        <div class="mt-1 text-2xl font-semibold text-amber-700">{{ retryableCount }}</div>
      </div>
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Fatal</div>
        <div class="mt-1 text-2xl font-semibold text-red-700">{{ fatalCount }}</div>
      </div>
    </div>

    <div class="rounded-lg border border-gray-200 bg-white p-4">
      <div class="grid gap-3 md:grid-cols-4">
        <label class="block">
          <span class="text-sm font-medium text-gray-700">Zeitraum</span>
          <select v-model="sincePreset" class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm">
            <option value="24h">Letzte 24 Stunden</option>
            <option value="7d">Letzte 7 Tage</option>
            <option value="30d">Letzte 30 Tage</option>
            <option value="all">Alle</option>
          </select>
        </label>
        <label class="block">
          <span class="text-sm font-medium text-gray-700">Gerät</span>
          <select v-model="selectedDeviceId" class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm">
            <option value="">Alle Geräte</option>
            <option v-for="device in devices" :key="device.id" :value="device.id">
              {{ device.name }}
            </option>
          </select>
        </label>
        <label class="block">
          <span class="text-sm font-medium text-gray-700">Limit</span>
          <input
            v-model.number="limit"
            type="number"
            min="1"
            max="1000"
            class="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
        </label>
        <div class="flex items-end">
          <button
            class="w-full rounded-md border border-blue-700 bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
            :disabled="loading"
            @click="loadErrors"
          >
            Anwenden
          </button>
        </div>
      </div>
    </div>

    <div v-if="error" class="rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
      {{ error }}
    </div>

    <div class="overflow-x-auto rounded-lg border border-gray-200 bg-white">
      <table class="min-w-full divide-y divide-gray-200 text-sm">
        <thead class="bg-gray-50 text-left text-xs font-semibold uppercase tracking-wide text-gray-500">
          <tr>
            <th class="px-4 py-3">Zeit</th>
            <th class="px-4 py-3">Gerät</th>
            <th class="px-4 py-3">Queue</th>
            <th class="px-4 py-3">Typ</th>
            <th class="px-4 py-3">Mitglied</th>
            <th class="px-4 py-3">Buchung</th>
            <th class="px-4 py-3">Retry</th>
            <th class="px-4 py-3">Fehler</th>
            <th class="px-4 py-3">Payload</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-100">
          <tr v-if="loading">
            <td colspan="9" class="px-4 py-8 text-center text-gray-500">
              Fehlerlog wird geladen...
            </td>
          </tr>
          <tr v-else-if="rows.length === 0">
            <td colspan="9" class="px-4 py-8 text-center text-gray-500">
              Keine globalen Sync-Fehler im gewählten Filter.
            </td>
          </tr>
          <template v-else>
            <tr v-for="row in rows" :key="row.id" class="align-top hover:bg-gray-50">
              <td class="whitespace-nowrap px-4 py-3">{{ formatDate(row.created_at) }}</td>
              <td class="px-4 py-3">{{ row.device_name }}</td>
              <td class="px-4 py-3">
                <div class="font-mono text-xs text-gray-700">{{ row.client_queue_id ?? "-" }}</div>
                <div v-if="row.client_tx_id" class="mt-1 max-w-[10rem] truncate font-mono text-xs text-gray-500">
                  {{ row.client_tx_id }}
                </div>
              </td>
              <td class="px-4 py-3">{{ operationLabel(row.operation) }}</td>
              <td class="px-4 py-3">{{ row.member_name || "-" }}</td>
              <td class="px-4 py-3">
                <div>{{ row.product_name || row.note || "-" }}</div>
                <div class="mt-1 text-xs text-gray-500">
                  {{ formatAmount(row.amount) }}
                  <span v-if="row.transaction_type"> · {{ row.transaction_type }}</span>
                </div>
              </td>
              <td class="px-4 py-3">
                <span
                  class="rounded-full px-2 py-1 text-xs font-semibold"
                  :class="row.retry_class === 'fatal' ? 'bg-red-100 text-red-700' : 'bg-amber-100 text-amber-800'"
                >
                  {{ row.retry_class || "unknown" }} · {{ row.attempts }}
                </span>
                <div class="mt-1 text-xs text-gray-500">{{ formatDate(row.next_retry_at) }}</div>
              </td>
              <td class="max-w-[26rem] px-4 py-3">
                <div class="whitespace-pre-wrap break-words text-red-800">{{ row.error_message }}</div>
              </td>
              <td class="px-4 py-3">
                <details>
                  <summary class="cursor-pointer text-blue-700 hover:underline">Ansehen</summary>
                  <pre class="mt-2 max-w-[28rem] overflow-auto rounded-md bg-gray-900 p-3 text-xs text-gray-100">{{ payloadPreview(row) }}</pre>
                </details>
              </td>
            </tr>
          </template>
        </tbody>
      </table>
    </div>
  </div>
</template>
