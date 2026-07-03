import { useAppAuthStore } from "@/stores/useAppAuthStore";
import { fetchWithTimeout } from "@/utils/fetchWithTimeout";
import router from "@/router";

let sessionExpiredHandled = false;

async function handleSessionExpired() {
  // Nur einmal reagieren, auch wenn mehrere parallele Requests 401 liefern.
  if (sessionExpiredHandled) return;
  sessionExpiredHandled = true;
  try {
    const auth = useAppAuthStore();
    await auth.logoutAdmin();
  } finally {
    sessionExpiredHandled = false;
    void router.push("/login");
  }
}

/**
 * Zentraler Fetch-Wrapper für alle Admin-Endpunkte:
 * Token-Handling, Timeout, JSON-Parsing und – wichtig – Behandlung
 * abgelaufener Sessions (401/403 → Logout + Redirect zum Login).
 */
export async function adminFetch(
  path: string,
  opts: { method?: string; body?: unknown } = {}
): Promise<any> {
  const auth = useAppAuthStore();
  auth.ensureHydrated();
  const token = auth.adminToken;
  if (!token) {
    throw new Error("Nicht authentifiziert");
  }

  const res = await fetchWithTimeout(path, {
    method: opts.method ?? "GET",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });

  if (res.status === 401 || res.status === 403) {
    void handleSessionExpired();
    throw new Error("Sitzung abgelaufen – bitte erneut anmelden");
  }

  if (res.status === 204) return null;

  let payload: Record<string, unknown>;
  try {
    payload = await res.json();
  } catch {
    throw new Error("Ungültige Server-Antwort");
  }
  if (!res.ok) {
    throw new Error((payload?.error as string) || "Anfrage fehlgeschlagen");
  }
  return payload;
}

export async function adminRpc(action: string, payload?: Record<string, unknown>) {
  const body = await adminFetch("/api/admin-rpc", {
    method: "POST",
    body: { action, payload: payload ?? {} },
  });
  return body?.data;
}

export async function fetchAdminReportSummary(payload: Record<string, unknown>) {
  return adminFetch("/api/admin-report-summary", {
    method: "POST",
    body: payload,
  });
}
