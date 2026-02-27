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
    class="bg-white rounded-xl border border-gray-200 shadow-sm flex flex-col"
  >
    <ul class="divide-y divide-gray-100">
      <li
        v-for="(b, i) in bookings"
        :key="i"
        class="px-3 py-2 text-sm grid grid-cols-[1fr_auto_auto] items-center gap-2"
      >
        <div class="min-w-0">
          <div
            class="font-medium text-gray-800 leading-snug whitespace-normal break-words hyphens-auto"
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
            class="text-xs text-amber-600 font-semibold mt-0.5"
            title="Noch nicht synchronisiert"
          >
            🕓 Ausstehend
          </div>
          <div
            v-else-if="b.syncStatus === 'failed'"
            class="text-xs text-red-600 font-semibold mt-0.5"
            title="Synchronisation fehlgeschlagen"
          >
            ⚠️ Fehler
          </div>
        </div>

        <span
          class="justify-self-end font-semibold whitespace-nowrap text-right"
          :class="b.amount < 0 ? 'text-red-600' : 'text-green-700'"
        >
          {{ (Math.abs(b.amount) / 100).toFixed(2) }} €
        </span>

        <button
          v-if="b.amount < 0"
          @click="$emit('undo', b)"
          :disabled="loading || b.syncStatus"
          class="justify-self-end text-gray-400 hover:text-red-600 transition-colors text-base disabled:opacity-50 disabled:cursor-not-allowed"
          :title="
            b.syncStatus
              ? 'Ausstehende Buchungen können nicht storniert werden'
              : 'Buchung stornieren'
          "
        >
          🗑️
        </button>
        <span v-else class="justify-self-end text-gray-300 text-base">🔒</span>
      </li>
    </ul>

    <!-- interne Summe nur falls gewünscht -->
    <div
      v-if="showTotal && bookings.length"
      class="mt-2 flex justify-between border-t border-gray-200 pt-2 text-base font-semibold text-gray-700 px-3 pb-2"
    >
      <span>Summe heute</span>
      <span>{{ (totalToday / 100).toFixed(2) }} €</span>
    </div>
  </div>
</template>
