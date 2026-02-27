import { inject } from "vue";

export function useToast() {
  const toastRef = inject("toast") as any;
  return {
    show(message: string) {
      toastRef?.value?.show?.(message);
    },
  };
}
