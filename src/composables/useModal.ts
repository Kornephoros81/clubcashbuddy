import { ref, createApp, h } from "vue";
import BaseModal from "@/components/BaseModal.vue";

// Singleton auf Modulebene: früher erzeugte jeder useModal()-Aufruf eine
// eigene Vue-App samt DOM-Container, die nie wieder abgebaut wurden (Leak
// auf dauerlaufenden Kiosk-Geräten). Jetzt wird genau einmal gemountet.
const isOpen = ref(false);
const resolveFn = ref<((v: boolean) => void) | null>(null);
const title = ref("");
const message = ref("");
const danger = ref(false);
let mounted = false;

function settle(value: boolean) {
  isOpen.value = false;
  const resolve = resolveFn.value;
  resolveFn.value = null;
  resolve?.(value);
}

function ensureMounted() {
  if (mounted || typeof document === "undefined") return;
  mounted = true;

  const container = document.createElement("div");
  document.body.appendChild(container);

  createApp({
    setup() {
      return () =>
        h(
          BaseModal,
          {
            show: isOpen.value,
            title: title.value,
            danger: danger.value,
            onClose: () => settle(false),
            onConfirm: () => settle(true),
          },
          () => h("p", { class: "text-sm text-gray-700 whitespace-pre-line" }, message.value)
        );
    },
  }).mount(container);
}

// Öffnet das Modal und gibt Promise zurück
async function confirmModal(
  modalTitle: string,
  modalMessage: string,
  opts: { danger?: boolean } = {}
): Promise<boolean> {
  ensureMounted();
  // Noch offenen Dialog als "abgebrochen" auflösen, damit dessen Promise
  // nicht ewig hängt, wenn zwei Dialoge kurz nacheinander geöffnet werden.
  settle(false);

  title.value = modalTitle;
  message.value = modalMessage;
  danger.value = opts.danger || false;
  isOpen.value = true;
  return new Promise((resolve) => {
    resolveFn.value = resolve;
  });
}

export function useModal() {
  return { confirm: confirmModal };
}
