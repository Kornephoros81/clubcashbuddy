<script setup lang="ts">
defineProps<{
  bookings: any[];
  totalToday: number;
  loading: boolean;
  showTotal?: boolean; // NEW: interne Summenzeile optional
}>();
defineEmits(["undo"]);
</script>

<template>
  <div
    class="glass-panel rounded-[24px] flex flex-col overflow-hidden"
  >
    <ul class="divide-y divide-gray-100">
      <li
        v-for="(b, i) in bookings"
        :key="i"
        class="px-3 py-2.5 xl:py-2 text-sm xl:text-[0.82rem] grid grid-cols-[1fr_auto_auto] items-center gap-2"
      >
        <div class="min-w-0">
          <div
            class="font-semibold text-slate-800 leading-snug whitespace-normal break-words hyphens-auto"
            style="
              display: -webkit-box;
              -webkit-line-clamp: 2;
              -webkit-box-orient: vertical;
              overflow: hidden;
            "
          >
            {{ b.product_name || b.note || "Buchung" }}
            <span v-if="b.count > 1" class="text-gray-500 text-xs">
              ×{{ b.count }}</span
            >
          </div>
          <div
            v-if="b.syncStatus === 'pending'"
            class="mt-1 inline-flex rounded-full bg-amber-100 px-2 py-0.5 text-[0.68rem] xl:text-[0.62rem] text-amber-700 font-semibold"
            title="Noch nicht synchronisiert"
          >
            Ausstehend
          </div>
          <div
            v-else-if="b.syncStatus === 'failed'"
            class="mt-1 inline-flex rounded-full bg-red-100 px-2 py-0.5 text-[0.68rem] xl:text-[0.62rem] text-red-700 font-semibold"
            title="Synchronisation fehlgeschlagen"
          >
            Fehler
          </div>
        </div>

        <span
          class="justify-self-end whitespace-nowrap text-right rounded-full px-2.5 xl:px-2 py-1 xl:py-0.5 text-[0.76rem] xl:text-[0.7rem] font-bold"
          :class="b.amount < 0 ? 'text-red-600' : 'text-green-700'"
          :style="{
            backgroundColor: b.amount < 0 ? 'var(--danger-soft)' : 'var(--success-soft)',
          }"
        >
          {{ (Math.abs(b.amount) / 100).toFixed(2) }} €
        </span>

        <button
          v-if="b.amount < 0"
          @click="$emit('undo', b)"
          :disabled="loading || b.syncStatus"
          class="justify-self-end flex h-9 w-9 xl:h-8 xl:w-8 items-center justify-center rounded-full bg-white text-slate-400 border border-slate-200 hover:text-red-600 hover:border-red-200 transition-colors text-base xl:text-sm disabled:opacity-50 disabled:cursor-not-allowed"
          :title="
            b.syncStatus
              ? 'Ausstehende Buchungen können nicht storniert werden'
              : 'Buchung stornieren'
          "
        >
          🗑️
        </button>
        <span v-else class="justify-self-end flex h-9 w-9 xl:h-8 xl:w-8 items-center justify-center rounded-full bg-slate-50 text-slate-300 border border-transparent text-base xl:text-sm">🔒</span>
      </li>
    </ul>

    <!-- interne Summe nur falls gewünscht -->
    <div
      v-if="showTotal && bookings.length"
      class="mt-2 flex justify-between border-t border-slate-200 pt-3 text-base font-semibold text-slate-700 px-3 pb-3"
    >
      <span>Summe heute</span>
      <span>{{ (totalToday / 100).toFixed(2) }} €</span>
    </div>
  </div>
</template>
