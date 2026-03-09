<!-- src/components/Terminal/OfflineStatus.vue -->
<script setup lang="ts">
import { computed } from "vue";
import { useTerminalLogic } from "@/composables/useTerminalLogic";

const logic = useTerminalLogic();

const visible = computed(
  () =>
    !logic.isOnline.value ||
    logic.pendingQueueCount.value > 0 ||
    logic.failedQueueCount.value > 0
);

const message = computed(() => {
  if (logic.failedQueueCount.value > 0)
    return `⚠️ ${logic.failedQueueCount.value} Buchungen fehlgeschlagen`;
  if (!logic.isOnline.value) return "📴 Offline-Modus";
  if (logic.pendingQueueCount.value > 0)
    return `⏳ ${logic.pendingQueueCount.value} Buchungen werden synchronisiert`;
  return "";
});
</script>

<template>
  <transition name="fade">
    <div
      v-if="visible"
      class="offline-chip fixed bottom-4 right-4 z-50 rounded-2xl border border-white/10 px-4 py-3 text-sm font-medium text-white shadow-[0_18px_60px_rgba(15,23,42,0.42)] backdrop-blur-xl select-none"
    >
      {{ message }}
    </div>
  </transition>
</template>

<style scoped>
.offline-chip {
  background:
    linear-gradient(135deg, rgba(15, 23, 42, 0.94), rgba(30, 41, 59, 0.88));
}

.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.25s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}
</style>
