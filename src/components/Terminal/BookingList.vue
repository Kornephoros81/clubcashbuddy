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
    class="booking-list flex flex-col overflow-hidden rounded-[1.4rem] border border-white/10 bg-white/6"
  >
    <ul class="divide-y divide-white/8">
      <li
        v-for="(b, i) in bookings"
        :key="i"
        class="grid grid-cols-[1fr_auto_auto] items-center gap-3 px-4 py-3 text-sm"
      >
        <div class="min-w-0">
          <div
            class="whitespace-normal break-words font-medium leading-snug text-slate-100 hyphens-auto"
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
            class="mt-1 text-xs font-semibold text-amber-300"
            title="Noch nicht synchronisiert"
          >
            Ausstehend
          </div>
          <div
            v-else-if="b.syncStatus === 'failed'"
            class="mt-1 text-xs font-semibold text-rose-300"
            title="Synchronisation fehlgeschlagen"
          >
            Fehler
          </div>
        </div>

        <span
          class="justify-self-end whitespace-nowrap rounded-full px-2.5 py-1 text-right text-sm font-semibold"
          :class="
            b.amount < 0
              ? 'bg-rose-500/12 text-rose-100'
              : 'bg-emerald-500/12 text-emerald-100'
          "
        >
          {{ (Math.abs(b.amount) / 100).toFixed(2) }} €
        </span>

        <button
          v-if="b.amount < 0"
          @click="$emit('undo', b)"
          :disabled="loading || b.syncStatus"
          class="justify-self-end rounded-full border border-white/10 bg-white/6 px-2.5 py-1.5 text-sm text-slate-300 transition-colors hover:text-rose-100 disabled:cursor-not-allowed disabled:opacity-50"
          :title="
            b.syncStatus
              ? 'Ausstehende Buchungen können nicht storniert werden'
              : 'Buchung stornieren'
          "
        >
          Storno
        </button>
        <span v-else class="justify-self-end text-base text-slate-600">•</span>
      </li>
    </ul>

    <div
      v-if="showTotal && bookings.length"
      class="mt-2 flex justify-between border-t border-white/10 px-4 pb-3 pt-3 text-base font-semibold text-slate-100"
    >
      <span>Summe heute</span>
      <span>{{ (totalToday / 100).toFixed(2) }} €</span>
    </div>
  </div>
</template>

<style scoped>
.booking-list {
  box-shadow: 0 20px 60px rgba(15, 23, 42, 0.18);
  backdrop-filter: blur(14px);
}
</style>
