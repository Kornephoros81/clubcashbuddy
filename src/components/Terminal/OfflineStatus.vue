<!-- src/components/Terminal/OfflineStatus.vue -->
<script setup lang="ts">
import { computed } from "vue";
import { useTerminalLogic } from "@/composables/useTerminalLogic";

const logic = useTerminalLogic();

const visible = computed(
  () =>
    !logic.isOnline ||
    logic.pendingQueueCount > 0 ||
    logic.failedQueueCount > 0
);

const message = computed(() => {
  if (logic.failedQueueCount > 0)
    return `⚠️ ${logic.failedQueueCount} Buchungen fehlgeschlagen`;
  if (!logic.isOnline) return "📴 Offline-Modus";
  if (logic.pendingQueueCount > 0)
    return `⏳ ${logic.pendingQueueCount} Buchungen werden synchronisiert`;
  return "";
});
</script>

<template>
  <transition name="fade">
    <div
      v-if="visible"
      class="fixed bottom-3 right-3 z-50 px-3 py-2 text-xs font-medium rounded-2xl shadow-md bg-slate-950/88 text-slate-100 border border-white/10 backdrop-blur-md select-none"
    >
      {{ message }}
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
