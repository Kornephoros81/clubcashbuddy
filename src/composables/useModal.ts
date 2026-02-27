import { ref, createApp, h } from "vue";
import BaseModal from "@/components/BaseModal.vue";

export function useModal() {
  const isOpen = ref(false);
  const resolveFn = ref<(v: boolean) => void>();
  const title = ref("");
  const message = ref("");
  const danger = ref(false);

  // Wrapper-Komponente dynamisch mounten
  const container = document.createElement("div");
  document.body.appendChild(container);

  const app = createApp({
    setup() {
      function close() {
        isOpen.value = false;
        resolveFn.value?.(false);
      }
      function confirm() {
        isOpen.value = false;
        resolveFn.value?.(true);
      }

      return () =>
        h(
          BaseModal,
          {
            show: isOpen.value,
            title: title.value,
            danger: danger.value,
            onClose: close,
            onConfirm: confirm,
          },
          () => h("p", { class: "text-sm text-gray-700 whitespace-pre-line" }, message.value)
        );
    },
  });

  app.mount(container);

  // Öffnet das Modal und gibt Promise zurück
  async function confirmModal(
    modalTitle: string,
    modalMessage: string,
    opts: { danger?: boolean } = {}
  ): Promise<boolean> {
    title.value = modalTitle;
    message.value = modalMessage;
    danger.value = opts.danger || false;
    isOpen.value = true;
    return new Promise((resolve) => {
      resolveFn.value = resolve;
    });
  }

  return { confirm: confirmModal };
}
