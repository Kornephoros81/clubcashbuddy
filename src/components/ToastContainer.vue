<script setup lang="ts">
import { ref } from "vue";

const toasts = ref<{ id: number; message: string }[]>([]);

function show(message: string) {
  const id = Date.now();
  toasts.value.push({ id, message });
  setTimeout(() => {
    toasts.value = toasts.value.filter((t) => t.id !== id);
  }, 3000);
}

// 👉 global verfügbar machen
defineExpose({ show });
</script>

<template>
  <div class="fixed bottom-5 right-5 space-y-2 z-50">
    <div
      v-for="t in toasts"
      :key="t.id"
      class="bg-gray-900 text-white px-4 py-2 rounded-lg shadow-lg"
    >
      {{ t.message }}
    </div>
  </div>
</template>
