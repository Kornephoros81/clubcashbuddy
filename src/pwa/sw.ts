// src/pwa/sw.ts
import { registerSW as viteRegisterSW } from "virtual:pwa-register";

// 🔹 Hilfsfunktion für Debug-Ausgabe
function logSWVersion() {
  const buildTag = import.meta.env.VITE_BUILD_ID || import.meta.env.VITE_APP_VERSION;
  console.log(
    `%c[PWA] Aktive SW-Version: ${buildTag || "unbekannt"} (${new Date().toLocaleString()})`,
    "color:#16a34a;font-weight:bold;"
  );
}

export function registerSW() {
  logSWVersion(); // immer beim Start anzeigen

  const updateSW = viteRegisterSW({
    immediate: true,
    onNeedRefresh() {
      console.log("%c[PWA] Neue Version erkannt – aktualisiere...", "color:#f59e0b;");
      updateSW(true);
    },
    onOfflineReady() {
      console.log("%c[PWA] App ist jetzt offline verfügbar.", "color:#0ea5e9;");
    },
    onRegisteredSW(swUrl, registration) {
      console.log("[PWA] Service Worker registriert:", swUrl);
      if (registration?.waiting) {
        updateSW(true);
      }
    },
  });
}
