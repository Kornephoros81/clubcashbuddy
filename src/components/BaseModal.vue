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
      class="fixed inset-0 flex items-center justify-center bg-black/60 z-50 backdrop-blur-sm"
    >
      <div
        class="glass-panel-strong rounded-[28px] w-full max-w-sm p-6 space-y-4"
      >
        <!-- Titel -->
        <h3 class="display-brand text-xl font-semibold text-cyan-100">{{ title }}</h3>

        <!-- Inhalt -->
        <div class="text-sm text-slate-200">
          <slot />
        </div>

        <!-- Buttons -->
        <div class="flex justify-end gap-3 pt-3">
          <button
            @click="emit('close')"
            class="rounded-2xl border border-white/10 bg-white/[0.04] px-4 py-2 text-slate-200 hover:bg-white/[0.08]"
          >
            {{ cancelLabel || "Abbrechen" }}
          </button>
          <button
            @click="emit('confirm')"
            :class="[
              'px-4 py-2 rounded-2xl font-medium transition',
              danger
                ? 'bg-rose-400/18 hover:bg-rose-400/26 text-rose-100 border border-rose-300/20'
                : 'bg-cyan-300 hover:bg-cyan-200 text-slate-950 border border-cyan-200',
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
