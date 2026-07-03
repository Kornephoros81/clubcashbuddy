<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { adminRpc } from "@/lib/adminApi";

type MetricRow = {
  metric_key: string;
  metric_label: string;
  metric_group: string;
  value_numeric: number | null;
  value_text: string | null;
  detail: Record<string, unknown>;
};

const loading = ref(false);
const pruning = ref(false);
const error = ref("");
const message = ref("");
const metrics = ref<MetricRow[]>([]);
const retentionDays = ref(180);

const groups = computed(() => {
  const grouped = new Map<string, MetricRow[]>();
  for (const metric of metrics.value) {
    const group = metric.metric_group || "misc";
    grouped.set(group, [...(grouped.get(group) ?? []), metric]);
  }
  return Array.from(grouped.entries()).map(([key, rows]) => ({
    key,
    label: groupLabel(key),
    rows,
  }));
});

function groupLabel(group: string) {
  if (group === "terminal_hot_path") return "Terminal Hot Path";
  if (group === "terminal_payload") return "Terminal Payload";
  if (group === "sync") return "Sync";
  if (group === "table_size") return "Tabellen";
  if (group === "recent_activity") return "Aktivität";
  if (group === "storage") return "Speicher";
  return group;
}

function formatValue(metric: MetricRow) {
  if (metric.value_text) return metric.value_text;
  const value = Number(metric.value_numeric ?? 0);
  return new Intl.NumberFormat("de-DE").format(value);
}

function formatDetail(detail: Record<string, unknown>) {
  const entries = Object.entries(detail ?? {});
  if (!entries.length) return "";
  return entries
    .map(([key, value]) => `${key}: ${formatDetailValue(value)}`)
    .join(" | ");
}

function formatDetailValue(value: unknown) {
  if (value == null) return "-";
  if (typeof value === "number") return new Intl.NumberFormat("de-DE").format(value);
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}T/.test(value)) {
    return new Intl.DateTimeFormat("de-DE", {
      dateStyle: "short",
      timeStyle: "medium",
    }).format(new Date(value));
  }
  return String(value);
}

async function loadMetrics() {
  loading.value = true;
  error.value = "";
  message.value = "";
  try {
    const data = await adminRpc("get_performance_metrics");
    metrics.value = ((data as any[]) ?? []).map((row: any) => ({
      metric_key: String(row.metric_key ?? ""),
      metric_label: String(row.metric_label ?? row.metric_key ?? ""),
      metric_group: String(row.metric_group ?? "misc"),
      value_numeric: row.value_numeric == null ? null : Number(row.value_numeric),
      value_text: row.value_text == null ? null : String(row.value_text),
      detail: row.detail ?? {},
    }));
  } catch (err: any) {
    console.error("[AdminPerformanceMetrics.loadMetrics]", err);
    error.value = err?.message || "Metriken konnten nicht geladen werden";
  } finally {
    loading.value = false;
  }
}

async function pruneSyncErrors() {
  pruning.value = true;
  error.value = "";
  message.value = "";
  try {
    const deleted = await adminRpc("prune_device_sync_errors", {
      days: retentionDays.value,
    });
    message.value = `${Number(deleted ?? 0)} alte Sync-Fehler gelöscht`;
    await loadMetrics();
  } catch (err: any) {
    console.error("[AdminPerformanceMetrics.pruneSyncErrors]", err);
    error.value = err?.message || "Sync-Fehler konnten nicht bereinigt werden";
  } finally {
    pruning.value = false;
  }
}

onMounted(loadMetrics);
</script>

<template>
  <div class="space-y-6">
    <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
      <div>
        <h2 class="text-2xl font-semibold text-gray-900">Performance-Metriken</h2>
        <p class="mt-1 text-sm text-gray-600">
          Überblick über Terminal-Hot-Paths, Sync-Fehler und relevante Tabellengrößen.
        </p>
      </div>
      <button
        class="rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50"
        :disabled="loading"
        @click="loadMetrics"
      >
        Aktualisieren
      </button>
    </div>

    <div v-if="error" class="rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
      {{ error }}
    </div>
    <div v-if="message" class="rounded-md border border-blue-200 bg-blue-50 px-4 py-3 text-sm text-blue-900">
      {{ message }}
    </div>

    <div class="rounded-lg border border-gray-200 bg-white p-4">
      <div class="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <h3 class="text-base font-semibold text-gray-900">Sync-Fehlerlog bereinigen</h3>
          <p class="mt-1 text-sm text-gray-600">
            Diagnose-Logs sind kein Kassenbuch und können nach einer Haltefrist gelöscht werden.
          </p>
        </div>
        <div class="flex flex-col gap-2 sm:flex-row sm:items-end">
          <label class="block">
            <span class="text-sm font-medium text-gray-700">Haltefrist Tage</span>
            <input
              v-model.number="retentionDays"
              type="number"
              min="7"
              max="3650"
              class="mt-1 w-36 rounded-md border border-gray-300 px-3 py-2 text-sm"
            />
          </label>
          <button
            class="rounded-md border border-amber-700 bg-amber-600 px-4 py-2 text-sm font-medium text-white hover:bg-amber-700 disabled:opacity-50"
            :disabled="pruning"
            @click="pruneSyncErrors"
          >
            {{ pruning ? "Bereinigt..." : "Alte Logs löschen" }}
          </button>
        </div>
      </div>
    </div>

    <div v-if="loading" class="rounded-lg border border-gray-200 bg-white px-4 py-8 text-center text-gray-500">
      Metriken werden geladen...
    </div>

    <div v-else class="space-y-5">
      <section
        v-for="group in groups"
        :key="group.key"
        class="rounded-lg border border-gray-200 bg-white"
      >
        <div class="border-b border-gray-200 px-4 py-3">
          <h3 class="text-base font-semibold text-gray-900">{{ group.label }}</h3>
        </div>
        <div class="grid gap-0 md:grid-cols-2 xl:grid-cols-3">
          <div
            v-for="metric in group.rows"
            :key="metric.metric_key"
            class="border-b border-gray-100 p-4 xl:border-r"
          >
            <div class="text-sm text-gray-500">{{ metric.metric_label }}</div>
            <div class="mt-1 text-2xl font-semibold text-gray-900">{{ formatValue(metric) }}</div>
            <div v-if="formatDetail(metric.detail)" class="mt-2 text-xs text-gray-500">
              {{ formatDetail(metric.detail) }}
            </div>
          </div>
        </div>
      </section>
    </div>
  </div>
</template>
