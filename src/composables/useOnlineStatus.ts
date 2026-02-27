// src/composables/useOnlineStatus.ts
import { ref, onMounted, onUnmounted } from "vue";

export function useOnlineStatus() {
  const isOnline = ref(true);

  onMounted(() => {
    isOnline.value = navigator.onLine;
    const setTrue = () => (isOnline.value = true);
    const setFalse = () => (isOnline.value = false);
    window.addEventListener("online", setTrue);
    window.addEventListener("offline", setFalse);
    onUnmounted(() => {
      window.removeEventListener("online", setTrue);
      window.removeEventListener("offline", setFalse);
    });
  });

  return { isOnline };
}
