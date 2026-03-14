import { createApp } from "vue";
import { createPinia } from "pinia";
import App from "./App.vue";
import router from "./router";
import { registerSW } from "./pwa/sw";
import "./style.css";
import { syncQueue } from "@/pwa/offlineSync";
import { useDeviceAuthStore } from "@/stores/useDeviceAuthStore";

// Singleton-Backoff
let pollTimerId: number | null = null;
let inFlight = false;
let backoffMs = 60_000; // 60s Start
const MAX_BACKOFF = 15 * 60_000; // 15min
const INITIAL_BACKOFF = 60_000;

async function trySync(): Promise<boolean> {
  if (inFlight) return false;
  const auth = useDeviceAuthStore();
  if (!auth.token) return false;
  if (typeof navigator !== "undefined" && !navigator.onLine) return false;
  if (typeof document !== "undefined" && document.visibilityState !== "visible") {
    return false;
  }
  inFlight = true;
  try {
    const processed = await syncQueue(auth.token);
    // UI gezielt aktualisieren statt Hard-Reload
    if (processed && processed > 0) {
      window.dispatchEvent(
        new CustomEvent("queue-synced", { detail: { processed } })
      );
    }
    return true;
  } catch {
    return false;
  } finally {
    inFlight = false;
  }
}

function clearPoller() {
  if (pollTimerId !== null) {
    window.clearTimeout(pollTimerId);
    pollTimerId = null;
  }
}

function scheduleNextPoll(delayMs = backoffMs) {
  clearPoller();
  pollTimerId = window.setTimeout(runPollCycle, delayMs);
}

async function runPollCycle() {
  pollTimerId = null;
  const synced = await trySync();
  backoffMs = synced
    ? INITIAL_BACKOFF
    : Math.min(Math.max(backoffMs, INITIAL_BACKOFF) * 2, MAX_BACKOFF);
  scheduleNextPoll(backoffMs);
}

function ensurePoller() {
  if (pollTimerId !== null) return;
  scheduleNextPoll(backoffMs);
}

async function bootstrap() {
  const app = createApp(App);
  const pinia = createPinia();
  app.use(pinia);
  app.use(router);

  const auth = useDeviceAuthStore(pinia);
  await auth.initFromStorage();

  // bisheriger Online-Listener bleibt – aber ist unter Android oft wirkungslos
  window.addEventListener("online", () => {
    void trySync();
    scheduleNextPoll(INITIAL_BACKOFF);
  });

  // zusätzliche Trigger
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
      void trySync();
      scheduleNextPoll(INITIAL_BACKOFF);
    }
  });
  window.addEventListener("focus", () => {
    void trySync();
    scheduleNextPoll(INITIAL_BACKOFF);
  });

  // Polling starten
  ensurePoller();

  app.mount("#app");
  registerSW();
}

bootstrap().catch((err) => console.error("❌ App-Start fehlgeschlagen:", err));
