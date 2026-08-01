<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import {
  changeTypeLabels,
  themeLabels,
  type ReleaseNoteArchiveGroup,
  type ReleaseNoteChangeType,
} from "@/data/releaseNotes";
import { filterReleaseNotesArchive } from "@/utils/releaseNotesFilter";

const props = defineProps<{
  archive: ReleaseNoteArchiveGroup[];
}>();

const changeTypes: ReleaseNoteChangeType[] = ["new", "improved", "fixed", "operations"];
const searchParam = "releaseSearch";
const typeParam = "releaseType";
const query = ref("");
const selectedTypes = ref<Set<ReleaseNoteChangeType>>(new Set());
const urlReady = ref(false);

const filteredArchive = computed(() =>
  filterReleaseNotesArchive(props.archive, query.value, selectedTypes.value)
);
const totalCount = computed(() =>
  props.archive.reduce((count, group) => count + group.entries.length, 0)
);
const visibleCount = computed(() =>
  filteredArchive.value.reduce((count, group) => count + group.entries.length, 0)
);
const filtering = computed(() => query.value.trim().length > 0 || selectedTypes.value.size > 0);
const filterKey = computed(() =>
  `${query.value.trim()}-${changeTypes.filter((type) => selectedTypes.value.has(type)).join("-")}`
);

const typeStyles: Record<ReleaseNoteChangeType, string> = {
  new: "border-emerald-200 bg-emerald-50 text-emerald-700",
  improved: "border-blue-200 bg-blue-50 text-blue-700",
  fixed: "border-amber-200 bg-amber-50 text-amber-700",
  operations: "border-violet-200 bg-violet-50 text-violet-700",
};

function readUrlFilters() {
  const params = new URLSearchParams(window.location.search);
  query.value = params.get(searchParam) ?? "";
  selectedTypes.value = new Set(
    params
      .getAll(typeParam)
      .filter((value): value is ReleaseNoteChangeType =>
        changeTypes.includes(value as ReleaseNoteChangeType)
      )
  );
  urlReady.value = true;
}

function syncUrlFilters() {
  if (!urlReady.value) return;
  const url = new URL(window.location.href);
  const normalizedQuery = query.value.trim();
  if (normalizedQuery) url.searchParams.set(searchParam, normalizedQuery);
  else url.searchParams.delete(searchParam);
  url.searchParams.delete(typeParam);
  for (const type of changeTypes) {
    if (selectedTypes.value.has(type)) url.searchParams.append(typeParam, type);
  }
  window.history.replaceState(null, "", `${url.pathname}${url.search}${url.hash}`);
}

function toggleType(type: ReleaseNoteChangeType) {
  const next = new Set(selectedTypes.value);
  if (next.has(type)) next.delete(type);
  else next.add(type);
  selectedTypes.value = next;
}

function resetFilters() {
  query.value = "";
  selectedTypes.value = new Set();
}

function keepFilteredGroupOpen(event: Event) {
  const details = event.currentTarget as HTMLDetailsElement | null;
  if (filtering.value && details && !details.open) details.open = true;
}

watch([query, selectedTypes], syncUrlFilters, { deep: true });
onMounted(() => {
  readUrlFilters();
  window.addEventListener("popstate", readUrlFilters);
});
onBeforeUnmount(() => window.removeEventListener("popstate", readUrlFilters));
</script>

<template>
  <section class="overflow-hidden rounded-2xl border border-gray-200 bg-white shadow-sm">
    <div class="border-b border-gray-200 bg-gradient-to-br from-slate-50 to-blue-50/70 p-5 sm:p-7">
      <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-primary">Vollständige Historie</p>
          <h2 class="mt-2 text-2xl font-bold text-gray-900">Alle Änderungen</h2>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-gray-600">
            Dieses Archiv wird dauerhaft fortgeführt. Neue Einträge stehen immer oben.
          </p>
        </div>
        <div class="shrink-0 rounded-2xl border border-gray-200 bg-white/80 px-4 py-3 text-center">
          <div class="text-2xl font-bold tabular-nums text-gray-900">
            {{ filtering ? visibleCount : totalCount }}
          </div>
          <div class="text-xs text-gray-500">
            {{ filtering ? `${visibleCount} von ${totalCount} Änderungen` : "dokumentierte Änderungen" }}
          </div>
        </div>
      </div>

      <div class="mt-6 grid gap-4 border-t border-gray-200 pt-5 lg:grid-cols-[minmax(16rem,1fr)_auto] lg:items-end">
        <label class="block">
          <span class="mb-2 block text-xs font-semibold uppercase tracking-wide text-gray-500">Suche</span>
          <span class="relative block">
            <span class="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">⌕</span>
            <input
              v-model="query"
              type="search"
              placeholder="Änderungen durchsuchen …"
              class="min-h-11 w-full rounded-xl border border-gray-300 bg-white pl-10 pr-4 text-sm text-gray-900 outline-none transition placeholder:text-gray-400 focus:border-primary focus:ring-2 focus:ring-primary/20"
            />
          </span>
        </label>

        <div>
          <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-gray-500">Art der Änderung</div>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="type in changeTypes"
              :key="type"
              type="button"
              :aria-pressed="selectedTypes.has(type)"
              class="min-h-11 rounded-full border px-3.5 text-sm font-semibold transition focus-visible:ring-2 focus-visible:ring-primary/30"
              :class="selectedTypes.has(type) ? typeStyles[type] : 'border-gray-200 bg-white text-gray-600 hover:bg-gray-50'"
              @click="toggleType(type)"
            >
              {{ changeTypeLabels[type] }}
            </button>
            <button
              v-if="filtering"
              type="button"
              class="min-h-11 rounded-full border border-gray-300 bg-white px-3.5 text-sm font-semibold text-gray-700 transition hover:bg-gray-50"
              @click="resetFilters"
            >
              Zurücksetzen
            </button>
          </div>
        </div>
      </div>
    </div>

    <div v-if="filteredArchive.length">
      <details
        v-for="(group, index) in filteredArchive"
        :key="`${group.date}-${filterKey}`"
        :open="filtering || index === 0"
        class="group border-b border-gray-200 last:border-b-0"
        @toggle="keepFilteredGroupOpen"
      >
        <summary class="flex cursor-pointer list-none items-center justify-between gap-4 px-5 py-4 transition hover:bg-gray-50 sm:px-7 [&::-webkit-details-marker]:hidden">
          <div class="flex min-w-0 items-center gap-3">
            <span class="h-2.5 w-2.5 shrink-0 rounded-full bg-primary shadow-[0_0_12px_rgba(30,58,138,0.35)]" aria-hidden="true" />
            <span class="font-semibold text-gray-900">{{ group.dateLabel }}</span>
            <span class="rounded-full border border-gray-200 bg-gray-50 px-2 py-0.5 text-xs tabular-nums text-gray-500">{{ group.entries.length }}</span>
          </div>
          <span class="text-gray-400 transition-transform group-open:rotate-180" aria-hidden="true">⌄</span>
        </summary>

        <ol class="border-t border-gray-200 bg-slate-50/60 px-5 py-2 sm:px-7">
          <li
            v-for="(entry, entryIndex) in group.entries"
            :key="entry.id"
            class="relative flex gap-4 border-b border-gray-200 py-4 last:border-b-0"
          >
            <div class="relative flex w-8 shrink-0 justify-center pt-1">
              <span v-if="entryIndex < group.entries.length - 1" class="absolute bottom-[-1rem] top-6 w-px bg-gray-200" aria-hidden="true" />
              <span class="z-10 flex h-8 w-8 items-center justify-center rounded-xl border border-gray-200 bg-white text-sm" :title="themeLabels[entry.theme].label">
                {{ themeLabels[entry.theme].icon }}
              </span>
            </div>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <span class="rounded-full border px-2 py-0.5 text-xs font-semibold" :class="typeStyles[entry.type]">
                  {{ changeTypeLabels[entry.type] }}
                </span>
                <span class="text-xs text-gray-500">{{ themeLabels[entry.theme].label }}</span>
              </div>
              <p class="mt-2 text-sm leading-6 text-gray-700">{{ entry.title }}</p>
            </div>
          </li>
        </ol>
      </details>
    </div>

    <div v-else class="px-5 py-12 text-center sm:px-7">
      <div class="text-3xl" aria-hidden="true">🔎</div>
      <h3 class="mt-3 font-semibold text-gray-900">Keine Änderungen gefunden</h3>
      <p class="mt-1 text-sm text-gray-500">Passe den Suchbegriff oder die ausgewählten Änderungsarten an.</p>
    </div>

    <div class="border-t border-gray-200 bg-gray-50 px-5 py-3 text-xs text-gray-500 sm:px-7">
      Archivbeginn: 3. Juli 2026. Frühere Änderungen sind nicht enthalten.
    </div>
  </section>
</template>
