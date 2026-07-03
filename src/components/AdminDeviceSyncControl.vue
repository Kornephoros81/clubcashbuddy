<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { adminRpc } from "@/lib/adminApi";

type DeviceSyncStatusRow = {
  device_id: string;
  device_name: string;
  active: boolean;
  device_last_seen_at: string | null;
  pending_count: number;
  failed_count: number;
  total_count: number;
  fatal_failed_count: number;
  retryable_failed_count: number;
  last_queue_report_at: string | null;
  last_sync_started_at: string | null;
  last_sync_finished_at: string | null;
  last_sync_processed_count: number | null;
  last_error: string | null;
  pending_command_count: number;
  last_command_id: string | null;
  last_command_status: string | null;
  last_command_requested_at: string | null;
  last_command_completed_at: string | null;
};

const rows = ref<DeviceSyncStatusRow[]>([]);
const loading = ref(false);
const error = ref("");
const message = ref("");
const actionKey = ref("");

const totalPending = computed(() =>
  rows.value.reduce((sum, row) => sum + row.pending_count, 0)
);
const totalFailed = computed(() =>
  rows.value.reduce((sum, row) => sum + row.failed_count, 0)
);
const activeDevices = computed(() => rows.value.filter((row) => row.active).length);
const devicesWithPendingCommands = computed(() =>
  rows.value.filter((row) => row.pending_command_count > 0).length
);

function mapRow(row: any): DeviceSyncStatusRow {
  return {
    device_id: String(row.device_id),
    device_name: String(row.device_name ?? row.device_id ?? "-"),
    active: Boolean(row.active),
    device_last_seen_at: row.device_last_seen_at ?? null,
    pending_count: Number(row.pending_count ?? 0),
    failed_count: Number(row.failed_count ?? 0),
    total_count: Number(row.total_count ?? 0),
    fatal_failed_count: Number(row.fatal_failed_count ?? 0),
    retryable_failed_count: Number(row.retryable_failed_count ?? 0),
    last_queue_report_at: row.last_queue_report_at ?? null,
    last_sync_started_at: row.last_sync_started_at ?? null,
    last_sync_finished_at: row.last_sync_finished_at ?? null,
    last_sync_processed_count:
      row.last_sync_processed_count == null ? null : Number(row.last_sync_processed_count),
    last_error: row.last_error ?? null,
    pending_command_count: Number(row.pending_command_count ?? 0),
    last_command_id: row.last_command_id ?? null,
    last_command_status: row.last_command_status ?? null,
    last_command_requested_at: row.last_command_requested_at ?? null,
    last_command_completed_at: row.last_command_completed_at ?? null,
  };
}

function formatDate(value?: string | null) {
  if (!value) return "-";
  return new Intl.DateTimeFormat("de-DE", {
    dateStyle: "short",
    timeStyle: "medium",
  }).format(new Date(value));
}

function commandLabel(value?: string | null) {
  if (value === "pending") return "Wartet";
  if (value === "claimed") return "Aufgenommen";
  if (value === "done") return "Erledigt";
  if (value === "failed") return "Fehlgeschlagen";
  return "-";
}

function statusClass(row: DeviceSyncStatusRow) {
  if (!row.active) return "bg-gray-100 text-gray-600";
  if (row.failed_count > 0 || row.last_error) return "bg-red-50 text-red-700";
  if (row.pending_count > 0 || row.pending_command_count > 0) return "bg-amber-50 text-amber-700";
  return "bg-emerald-50 text-emerald-700";
}

function statusLabel(row: DeviceSyncStatusRow) {
  if (!row.active) return "Inaktiv";
  if (row.failed_count > 0 || row.last_error) return "Fehler";
  if (row.pending_command_count > 0) return "Command offen";
  if (row.pending_count > 0) return "Queue offen";
  return "OK";
}

async function loadRows() {
  loading.value = true;
  error.value = "";
  try {
    const data = await adminRpc("list_device_sync_status");
    rows.value = ((data as any[]) ?? []).map(mapRow);
  } catch (err: any) {
    console.error("[AdminDeviceSyncControl.loadRows]", err);
    error.value = err?.message || "Geräte-Sync-Status konnte nicht geladen werden";
  } finally {
    loading.value = false;
  }
}

async function enqueueSync(deviceId: string | null) {
  const key = deviceId ?? "all";
  actionKey.value = key;
  error.value = "";
  message.value = "";
  try {
    const data = await adminRpc("enqueue_device_sync_command", {
      device_id: deviceId,
    });
    const inserted = Array.isArray(data) ? data.length : 0;
    message.value = inserted > 0
      ? `${inserted} Sync-Command${inserted === 1 ? "" : "s"} angefordert.`
      : "Es war bereits ein offener Sync-Command vorhanden.";
    await loadRows();
  } catch (err: any) {
    console.error("[AdminDeviceSyncControl.enqueueSync]", err);
    error.value = err?.message || "Sync-Command konnte nicht angefordert werden";
  } finally {
    actionKey.value = "";
  }
}

onMounted(loadRows);
</script>

<template>
  <div class="space-y-6">
    <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
      <div>
        <h2 class="text-2xl font-semibold text-gray-900">Geräte-Sync</h2>
        <p class="mt-1 text-sm text-gray-600">
          Zentrale Queue-Größen und Remote-Trigger für Terminal-Syncs.
        </p>
      </div>
      <div class="flex flex-wrap gap-2">
        <button
          class="rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          :disabled="loading || Boolean(actionKey)"
          @click="loadRows"
        >
          Aktualisieren
        </button>
        <button
          class="rounded-md border border-blue-700 bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          :disabled="loading || Boolean(actionKey) || activeDevices === 0"
          @click="enqueueSync(null)"
        >
          {{ actionKey === "all" ? "Wird angefordert..." : "Alle aktiven Geräte syncen" }}
        </button>
      </div>
    </div>

    <div class="grid gap-3 sm:grid-cols-4">
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Aktive Geräte</div>
        <div class="mt-1 text-2xl font-semibold text-gray-900">{{ activeDevices }}</div>
      </div>
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Pending gesamt</div>
        <div class="mt-1 text-2xl font-semibold text-amber-700">{{ totalPending }}</div>
      </div>
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Failed gesamt</div>
        <div class="mt-1 text-2xl font-semibold text-red-700">{{ totalFailed }}</div>
      </div>
      <div class="rounded-lg border border-gray-200 bg-white p-4">
        <div class="text-sm text-gray-500">Offene Commands</div>
        <div class="mt-1 text-2xl font-semibold text-blue-700">{{ devicesWithPendingCommands }}</div>
      </div>
    </div>

    <div v-if="message" class="rounded-md border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-800">
      {{ message }}
    </div>
    <div v-if="error" class="rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
      {{ error }}
    </div>

    <div class="overflow-x-auto rounded-lg border border-gray-200 bg-white">
      <table class="min-w-full divide-y divide-gray-200 text-sm">
        <thead class="bg-gray-50 text-left text-xs font-semibold uppercase tracking-wide text-gray-500">
          <tr>
            <th class="px-4 py-3">Gerät</th>
            <th class="px-4 py-3">Status</th>
            <th class="px-4 py-3">Queue</th>
            <th class="px-4 py-3">Letzte Meldung</th>
            <th class="px-4 py-3">Letzter Sync</th>
            <th class="px-4 py-3">Letzter Command</th>
            <th class="px-4 py-3">Fehler</th>
            <th class="px-4 py-3"></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-100">
          <tr v-if="loading">
            <td colspan="8" class="px-4 py-8 text-center text-gray-500">
              Geräte-Sync-Status wird geladen...
            </td>
          </tr>
          <tr v-else-if="rows.length === 0">
            <td colspan="8" class="px-4 py-8 text-center text-gray-500">
              Keine Geräte vorhanden.
            </td>
          </tr>
          <template v-else>
            <tr v-for="row in rows" :key="row.device_id" class="align-top hover:bg-gray-50">
              <td class="px-4 py-3">
                <div class="font-medium text-gray-900">{{ row.device_name }}</div>
                <div class="mt-1 font-mono text-xs text-gray-500">{{ row.device_id }}</div>
              </td>
              <td class="px-4 py-3">
                <span class="inline-flex rounded-full px-2 py-1 text-xs font-medium" :class="statusClass(row)">
                  {{ statusLabel(row) }}
                </span>
                <div class="mt-2 text-xs text-gray-500">
                  Last seen: {{ formatDate(row.device_last_seen_at) }}
                </div>
              </td>
              <td class="px-4 py-3">
                <div class="font-medium text-gray-900">
                  {{ row.total_count }} total
                </div>
                <div class="mt-1 text-xs text-gray-600">
                  {{ row.pending_count }} pending · {{ row.failed_count }} failed
                </div>
                <div v-if="row.failed_count > 0" class="mt-1 text-xs text-gray-500">
                  {{ row.retryable_failed_count }} retryable · {{ row.fatal_failed_count }} fatal
                </div>
              </td>
              <td class="whitespace-nowrap px-4 py-3">
                {{ formatDate(row.last_queue_report_at) }}
              </td>
              <td class="px-4 py-3">
                <div class="whitespace-nowrap">
                  Start: {{ formatDate(row.last_sync_started_at) }}
                </div>
                <div class="mt-1 whitespace-nowrap text-xs text-gray-500">
                  Ende: {{ formatDate(row.last_sync_finished_at) }}
                </div>
                <div class="mt-1 text-xs text-gray-500">
                  Verarbeitet: {{ row.last_sync_processed_count ?? "-" }}
                </div>
              </td>
              <td class="px-4 py-3">
                <div>{{ commandLabel(row.last_command_status) }}</div>
                <div class="mt-1 whitespace-nowrap text-xs text-gray-500">
                  {{ formatDate(row.last_command_requested_at) }}
                </div>
                <div v-if="row.pending_command_count > 0" class="mt-1 text-xs font-medium text-amber-700">
                  {{ row.pending_command_count }} offen
                </div>
              </td>
              <td class="max-w-md px-4 py-3">
                <div v-if="row.last_error" class="break-words text-red-700">
                  {{ row.last_error }}
                </div>
                <div v-else class="text-gray-400">-</div>
              </td>
              <td class="whitespace-nowrap px-4 py-3 text-right">
                <button
                  class="rounded-md border border-blue-700 bg-blue-600 px-3 py-2 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50"
                  :disabled="!row.active || row.pending_command_count > 0 || Boolean(actionKey)"
                  @click="enqueueSync(row.device_id)"
                >
                  {{ actionKey === row.device_id ? "Wird angefordert..." : "Sync starten" }}
                </button>
              </td>
            </tr>
          </template>
        </tbody>
      </table>
    </div>
  </div>
</template>
