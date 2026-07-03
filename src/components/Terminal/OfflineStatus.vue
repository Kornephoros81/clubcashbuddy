<!-- src/components/Terminal/OfflineStatus.vue -->
<script setup lang="ts">
import { computed } from "vue";
import { useTerminalLogic } from "@/composables/useTerminalLogic";

const { isOnline, pendingQueueCount } = useTerminalLogic();

const visible = computed(
  () =>
    !isOnline.value ||
    pendingQueueCount.value > 0
);

const message = computed(() => {
  if (!isOnline.value) return "📴 Offline-Modus";
  if (pendingQueueCount.value > 0)
    return `⏳ ${pendingQueueCount.value} Buchungen werden synchronisiert`;
  return "";
});
</script>

<template>
  <transition name="fade">
    <div
      v-if="visible"
      class="fixed bottom-3 right-3 z-50 px-3 py-2 text-xs font-medium rounded-md shadow-md bg-gray-800 text-white opacity-90 select-none"
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
