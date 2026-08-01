<script setup lang="ts">
import { onBeforeUnmount, onMounted } from "vue";
import ReleaseNotesArchive from "@/components/ReleaseNotesArchive.vue";
import {
  releaseNotesArchive,
  releaseNotesOverview,
  themeLabels,
  type ReleaseNoteTheme,
} from "@/data/releaseNotes";

const previousTitle = typeof document !== "undefined" ? document.title : "";

const themeStyles: Record<ReleaseNoteTheme, string> = {
  articles: "border-violet-200 bg-violet-50 text-violet-700",
  bookings: "border-blue-200 bg-blue-50 text-blue-700",
  reports: "border-emerald-200 bg-emerald-50 text-emerald-700",
  inventory: "border-amber-200 bg-amber-50 text-amber-700",
  devices: "border-cyan-200 bg-cyan-50 text-cyan-700",
  quality: "border-rose-200 bg-rose-50 text-rose-700",
};

onMounted(() => {
  document.title = "Release Notes | ClubCashBuddy";
});
onBeforeUnmount(() => {
  document.title = previousTitle;
});
</script>

<template>
  <div class="mx-auto flex w-full max-w-7xl flex-col gap-6">
    <section class="relative overflow-hidden rounded-3xl border border-primary/15 bg-gradient-to-br from-white via-blue-50 to-amber-50 px-5 py-7 shadow-sm sm:px-8 sm:py-10">
      <div class="pointer-events-none absolute -right-24 -top-28 h-72 w-72 rounded-full bg-blue-300/20 blur-3xl" aria-hidden="true" />
      <div class="pointer-events-none absolute -bottom-32 left-1/3 h-64 w-64 rounded-full bg-amber-300/20 blur-3xl" aria-hidden="true" />

      <div class="relative">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div class="inline-flex items-center gap-2 rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.18em] text-emerald-700">
            <span class="h-2 w-2 rounded-full bg-emerald-500 shadow-[0_0_12px_rgba(16,185,129,0.55)]" />
            {{ releaseNotesOverview.eyebrow }}
          </div>
          <p class="text-xs font-medium text-gray-500">{{ releaseNotesOverview.lastUpdated }}</p>
        </div>

        <div class="mt-8 max-w-3xl">
          <h1 class="text-3xl font-bold tracking-tight text-gray-950 sm:text-4xl lg:text-5xl">
            {{ releaseNotesOverview.title }}
          </h1>
          <p class="mt-4 max-w-2xl text-base leading-7 text-gray-600 sm:text-lg">
            {{ releaseNotesOverview.description }}
          </p>
          <div class="mt-5 inline-flex rounded-full border border-gray-200 bg-white/75 px-3 py-1.5 text-sm font-medium text-gray-700">
            {{ releaseNotesOverview.periodLabel }}
          </div>
        </div>

        <dl class="mt-9 grid gap-3 sm:grid-cols-3">
          <div
            v-for="highlight in releaseNotesOverview.highlights"
            :key="highlight.label"
            class="rounded-2xl border border-white/80 bg-white/65 p-4 shadow-sm backdrop-blur"
          >
            <dt class="text-sm text-gray-500">{{ highlight.label }}</dt>
            <dd class="mt-1 text-2xl font-bold tabular-nums text-gray-950">{{ highlight.value }}</dd>
          </div>
        </dl>
      </div>
    </section>

    <section class="overflow-hidden rounded-2xl border border-gray-200 bg-white shadow-sm">
      <div class="border-b border-gray-200 bg-gray-50 px-5 py-5 sm:px-7">
        <h2 class="text-xl font-bold text-gray-900">{{ releaseNotesOverview.overviewTitle }}</h2>
        <p class="mt-2 max-w-4xl text-sm leading-6 text-gray-600">{{ releaseNotesOverview.overviewDescription }}</p>
      </div>

      <div class="grid lg:grid-cols-2">
        <article
          v-for="(section, index) in releaseNotesOverview.sections"
          :key="section.theme"
          class="p-5 sm:p-7"
          :class="[
            index > 0 ? 'border-t border-gray-200 lg:border-t-0' : '',
            index % 2 === 1 ? 'lg:border-l lg:border-gray-200' : '',
          ]"
        >
          <div class="flex items-start gap-4">
            <span class="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl border text-lg" :class="themeStyles[section.theme]">
              {{ themeLabels[section.theme].icon }}
            </span>
            <div>
              <h3 class="text-lg font-bold text-gray-900">{{ section.title }}</h3>
              <p class="mt-1 text-sm leading-6 text-gray-500">{{ section.description }}</p>
            </div>
          </div>

          <ul class="mt-5 space-y-3">
            <li v-for="change in section.changes" :key="change" class="flex gap-3 text-sm leading-6 text-gray-700">
              <span class="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-primary" aria-hidden="true" />
              <span>{{ change }}</span>
            </li>
          </ul>
        </article>
      </div>
    </section>

    <ReleaseNotesArchive :archive="releaseNotesArchive" />
  </div>
</template>
