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

type SyncSample = {
  id: string;
  device_id: string;
  device_name: string;
  measured_at: string;
  duration_ms: number;
  attempted_count: number;
  success_count: number;
  failed_count: number;
  book_count: number;
  cancel_count: number;
  batch_count: number;
  avg_item_ms: number | null;
  error_message: string | null;
};

const loading = ref(false);
const pruning = ref(false);
const error = ref("");
const message = ref("");
const metrics = ref<MetricRow[]>([]);
const syncSamples = ref<SyncSample[]>([]);
const syncChartHours = ref(24);
const retentionDays = ref(180);

const chartWidth = 760;
const chartHeight = 260;
const plotLeft = 56;
const plotRight = 24;
const plotTop = 20;
const plotBottom = 42;

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

const syncChartRows = computed(() =>
  [...syncSamples.value].sort(
    (a, b) => new Date(a.measured_at).getTime() - new Date(b.measured_at).getTime()
  )
);

const syncChartStats = computed(() => {
  const rows = syncChartRows.value;
  const maxDuration = Math.max(1, ...rows.map((row) => row.duration_ms));
  const maxCount = Math.max(1, ...rows.map((row) => row.attempted_count));
  const avgDuration = rows.length
    ? Math.round(rows.reduce((sum, row) => sum + row.duration_ms, 0) / rows.length)
    : 0;
  return { maxDuration, maxCount, avgDuration };
});

const syncChartDomain = computed(() => {
  const rows = syncChartRows.value;
  const now = Date.now();
  const fallbackStart = now - syncChartHours.value * 60 * 60 * 1000;
  if (!rows.length) return { min: fallbackStart, max: now };

  const first = new Date(rows[0].measured_at).getTime();
  const last = new Date(rows[rows.length - 1].measured_at).getTime();
  const rawSpan = Math.max(0, last - first);
  const minVisibleSpan = 10 * 60 * 1000;
  const span = Math.max(rawSpan, minVisibleSpan);
  const padding = Math.max(span * 0.04, 60 * 1000);
  const midpoint = first + rawSpan / 2;

  if (rawSpan < minVisibleSpan) {
    return {
      min: midpoint - minVisibleSpan / 2 - padding,
      max: midpoint + minVisibleSpan / 2 + padding,
    };
  }

  return {
    min: first - padding,
    max: last + padding,
  };
});

const syncDurationPath = computed(() => {
  const points = syncChartPoints.value;
  if (!points.length) return "";
  return points.map((point, index) => `${index === 0 ? "M" : "L"} ${point.x} ${point.y}`).join(" ");
});

const syncChartPoints = computed(() =>
  syncChartRows.value.map((row) => ({
    ...row,
    x: chartX(new Date(row.measured_at).getTime()),
    y: chartY(row.duration_ms),
  }))
);

const syncChartBars = computed(() =>
  syncChartRows.value.map((row, index) => {
    const point = syncChartPoints.value[index];
    const plotHeight = chartHeight - plotTop - plotBottom;
    const barHeight = Math.max(2, (row.attempted_count / syncChartStats.value.maxCount) * plotHeight);
    return {
      ...row,
      x: point?.x ?? plotLeft,
      y: chartHeight - plotBottom - barHeight,
      height: barHeight,
    };
  })
);

const firstSyncLabel = computed(() => {
  const row = syncChartRows.value[0];
  return row ? formatShortDateTime(row.measured_at) : "";
});

const lastSyncLabel = computed(() => {
  const rows = syncChartRows.value;
  const row = rows[rows.length - 1];
  return row ? formatShortDateTime(row.measured_at) : "";
});

function chartX(timestamp: number) {
  const domain = syncChartDomain.value;
  const plotWidth = chartWidth - plotLeft - plotRight;
  const span = Math.max(1, domain.max - domain.min);
  return plotLeft + ((timestamp - domain.min) / span) * plotWidth;
}

function chartY(durationMs: number) {
  const plotHeight = chartHeight - plotTop - plotBottom;
  return plotTop + (1 - durationMs / syncChartStats.value.maxDuration) * plotHeight;
}

function formatValue(metric: MetricRow) {
  if (metric.value_text) return metric.value_text;
  const value = Number(metric.value_numeric ?? 0);
  return new Intl.NumberFormat("de-DE").format(value);
}

function formatDuration(ms: number | null | undefined) {
  const value = Number(ms ?? 0);
  if (value < 1000) return `${new Intl.NumberFormat("de-DE").format(Math.round(value))} ms`;
  return `${new Intl.NumberFormat("de-DE", { maximumFractionDigits: 2 }).format(value / 1000)} s`;
}

function formatShortDateTime(value: string) {
  return new Intl.DateTimeFormat("de-DE", {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
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
    try {
      const samples = await adminRpc("list_sync_performance_samples", {
        hours: syncChartHours.value,
        limit: 300,
      });
      syncSamples.value = ((samples as any[]) ?? []).map((row: any) => ({
        id: String(row.id ?? ""),
        device_id: String(row.device_id ?? ""),
        device_name: String(row.device_name ?? "Unbekanntes Gerät"),
        measured_at: String(row.measured_at ?? ""),
        duration_ms: Number(row.duration_ms ?? 0),
        attempted_count: Number(row.attempted_count ?? 0),
        success_count: Number(row.success_count ?? 0),
        failed_count: Number(row.failed_count ?? 0),
        book_count: Number(row.book_count ?? 0),
        cancel_count: Number(row.cancel_count ?? 0),
        batch_count: Number(row.batch_count ?? 0),
        avg_item_ms: row.avg_item_ms == null ? null : Number(row.avg_item_ms),
        error_message: row.error_message == null ? null : String(row.error_message),
      }));
    } catch (sampleErr) {
      console.warn("[AdminPerformanceMetrics.loadSyncSamples]", sampleErr);
      syncSamples.value = [];
    }
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
          Überblick über Terminal-Hot-Paths, Buchungs-Sync, Sync-Fehler und relevante Tabellengrößen.
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

    <section class="rounded-lg border border-gray-200 bg-white">
      <div class="flex flex-col gap-3 border-b border-gray-200 px-4 py-3 md:flex-row md:items-center md:justify-between">
        <div>
          <h3 class="text-base font-semibold text-gray-900">Sync-Performance</h3>
          <p class="mt-1 text-sm text-gray-600">
            Dauer je Sync-Lauf und Anzahl verarbeiteter Queue-Einträge.
          </p>
        </div>
        <label class="flex items-center gap-2 text-sm text-gray-700">
          Zeitraum
          <select
            v-model.number="syncChartHours"
            class="rounded-md border border-gray-300 bg-white px-3 py-2 text-sm"
            :disabled="loading"
            @change="loadMetrics"
          >
            <option :value="24">24 Stunden</option>
            <option :value="72">3 Tage</option>
            <option :value="168">7 Tage</option>
            <option :value="720">30 Tage</option>
          </select>
        </label>
      </div>

      <div v-if="!syncChartRows.length && !loading" class="px-4 py-8 text-center text-sm text-gray-500">
        Noch keine Sync-Messpunkte vorhanden. Es werden nur Syncs mit verarbeiteten Queue-Einträgen aufgezeichnet.
      </div>

      <div v-else-if="loading && !syncChartRows.length" class="px-4 py-8 text-center text-sm text-gray-500">
        Sync-Diagramm wird geladen...
      </div>

      <div v-else class="p-4">
        <div class="mb-3 grid gap-3 text-sm md:grid-cols-3">
          <div class="rounded-md border border-gray-200 px-3 py-2">
            <div class="text-gray-500">Messpunkte</div>
            <div class="text-lg font-semibold text-gray-900">{{ syncChartRows.length }}</div>
          </div>
          <div class="rounded-md border border-gray-200 px-3 py-2">
            <div class="text-gray-500">Ø Dauer</div>
            <div class="text-lg font-semibold text-gray-900">{{ formatDuration(syncChartStats.avgDuration) }}</div>
          </div>
          <div class="rounded-md border border-gray-200 px-3 py-2">
            <div class="text-gray-500">Max. Dauer</div>
            <div class="text-lg font-semibold text-gray-900">{{ formatDuration(syncChartStats.maxDuration) }}</div>
          </div>
        </div>

        <div class="overflow-x-auto">
          <svg
            class="min-w-[760px] w-full"
            :viewBox="`0 0 ${chartWidth} ${chartHeight}`"
            role="img"
            aria-label="Sync-Performance-Diagramm"
          >
            <line :x1="plotLeft" :y1="plotTop" :x2="plotLeft" :y2="chartHeight - plotBottom" stroke="#d1d5db" />
            <line :x1="plotLeft" :y1="chartHeight - plotBottom" :x2="chartWidth - plotRight" :y2="chartHeight - plotBottom" stroke="#d1d5db" />
            <line :x1="plotLeft" :y1="plotTop" :x2="chartWidth - plotRight" :y2="plotTop" stroke="#f3f4f6" />
            <line :x1="plotLeft" :y1="(chartHeight - plotBottom + plotTop) / 2" :x2="chartWidth - plotRight" :y2="(chartHeight - plotBottom + plotTop) / 2" stroke="#f3f4f6" />

            <text x="8" :y="plotTop + 4" class="fill-gray-500 text-[11px]">{{ formatDuration(syncChartStats.maxDuration) }}</text>
            <text x="8" :y="chartHeight - plotBottom + 4" class="fill-gray-500 text-[11px]">0 ms</text>

            <rect
              v-for="bar in syncChartBars"
              :key="`${bar.id}-bar`"
              :x="bar.x - 5"
              :y="bar.y"
              width="10"
              :height="bar.height"
              rx="2"
              fill="#93c5fd"
              opacity="0.55"
            >
              <title>{{ `${formatShortDateTime(bar.measured_at)} | ${bar.attempted_count} Einträge` }}</title>
            </rect>

            <path
              v-if="syncDurationPath"
              :d="syncDurationPath"
              fill="none"
              stroke="#2563eb"
              stroke-width="3"
              stroke-linecap="round"
              stroke-linejoin="round"
            />

            <circle
              v-for="point in syncChartPoints"
              :key="`${point.id}-point`"
              :cx="point.x"
              :cy="point.y"
              r="4"
              fill="#1d4ed8"
              stroke="white"
              stroke-width="2"
            >
              <title>
                {{ `${formatShortDateTime(point.measured_at)} | ${point.device_name} | ${formatDuration(point.duration_ms)} | ${point.success_count}/${point.attempted_count} erfolgreich` }}
              </title>
            </circle>

            <text :x="plotLeft" :y="chartHeight - 14" class="fill-gray-500 text-[11px]">{{ firstSyncLabel }}</text>
            <text :x="chartWidth - plotRight" :y="chartHeight - 14" text-anchor="end" class="fill-gray-500 text-[11px]">{{ lastSyncLabel }}</text>
          </svg>
        </div>

        <div class="mt-3 flex flex-wrap gap-4 text-xs text-gray-600">
          <span class="inline-flex items-center gap-1">
            <span class="h-2 w-5 rounded-full bg-blue-600"></span>
            Sync-Dauer
          </span>
          <span class="inline-flex items-center gap-1">
            <span class="h-3 w-3 rounded-sm bg-blue-300"></span>
            Queue-Einträge
          </span>
        </div>
      </div>
    </section>

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
