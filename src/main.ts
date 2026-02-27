import { createApp } from "vue";
import { createPinia } from "pinia";
import App from "./App.vue";
import router from "./router";
import { registerSW } from "./pwa/sw";
import "./style.css";
import { syncQueue } from "@/pwa/offlineSync";
import { useDeviceAuthStore } from "@/stores/useDeviceAuthStore";

// robuste Online-Prüfung
async function isReallyOnline(): Promise<boolean> {
  try {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), 2000);
    const res = await fetch("/api/ping", {
      method: "HEAD",
      cache: "no-store",
      signal: c.signal,
    });
    clearTimeout(t);
    return res.ok;
  } catch {
    return false;
  }
}

// Singleton-Backoff
let pollingId: number | null = null;
let inFlight = false;
let backoffMs = 15000; // 15s Start
const MAX_BACKOFF = 5 * 60_000; // 5min

async function trySync() {
  if (inFlight) return;
  const auth = useDeviceAuthStore();
  if (!auth.token) return;
  inFlight = true;
  try {
    if (await isReallyOnline()) {
      const processed = await syncQueue(auth.token);
      // UI gezielt aktualisieren statt Hard-Reload
      if (processed && processed > 0) {
        window.dispatchEvent(
          new CustomEvent("queue-synced", { detail: { processed } })
        );
      }
      backoffMs = 15000;
    }
  } catch {
    /* noop */
  } finally {
    inFlight = false;
  }
}

function ensurePoller() {
  if (pollingId) return;
  pollingId = window.setInterval(async () => {
    await trySync();
    // exponentielles Backoff erst anwenden, wenn offline/fehlgeschlagen
    if (!inFlight) {
      clearInterval(pollingId!);
      pollingId = null;
      setTimeout(ensurePoller, backoffMs);
      backoffMs = Math.min(backoffMs * 2, MAX_BACKOFF);
    }
  }, backoffMs);
}

async function bootstrap() {
  const app = createApp(App);
  const pinia = createPinia();
  app.use(pinia);
  app.use(router);

  const auth = useDeviceAuthStore(pinia);
  await auth.initFromStorage();

  // bisheriger Online-Listener bleibt – aber ist unter Android oft wirkungslos
  window.addEventListener("online", trySync);

  // zusätzliche Trigger
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") trySync();
  });
  window.addEventListener("focus", trySync);

  // Polling starten
  ensurePoller();

  app.mount("#app");
  registerSW();
}

bootstrap().catch((err) => console.error("❌ App-Start fehlgeschlagen:", err));
