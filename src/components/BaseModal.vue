<script setup lang="ts">
import { defineProps, defineEmits } from "vue";

defineProps<{
  title: string;
  show: boolean;
  confirmLabel?: string;
  cancelLabel?: string;
  danger?: boolean; // z. B. für "Löschen" -> roter Button
}>();

const emit = defineEmits<{ (e: "close"): void; (e: "confirm"): void }>();
</script>

<template>
  <transition name="fade">
    <div
      v-if="show"
      class="fixed inset-0 flex items-center justify-center bg-black/40 z-50"
    >
      <div
        class="bg-white rounded-2xl shadow-xl w-full max-w-sm p-6 space-y-4 border border-slate-300"
      >
        <!-- Titel -->
        <h3 class="text-lg font-semibold text-primary">{{ title }}</h3>

        <!-- Inhalt -->
        <div class="text-sm text-gray-700">
          <slot />
        </div>

        <!-- Buttons -->
        <div class="flex justify-end gap-3 pt-3">
          <button
            @click="emit('close')"
            class="button-outline-strong px-4 py-2 text-gray-600 bg-gray-100 rounded-md border-slate-300 hover:bg-gray-200"
          >
            {{ cancelLabel || "Abbrechen" }}
          </button>
          <button
            @click="emit('confirm')"
            :class="[
              'button-outline-strong px-4 py-2 rounded-md font-medium transition',
              danger
                ? 'border-red-800 bg-red-600 hover:bg-red-700 text-white'
                : 'border-blue-800 bg-primary hover:bg-primary/90 text-white',
            ]"
          >
            {{ confirmLabel || "Bestätigen" }}
          </button>
        </div>
      </div>
    </div>
  </transition>
</template>

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.25s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}
</style>
