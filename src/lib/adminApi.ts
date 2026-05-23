import { useAppAuthStore } from "@/stores/useAppAuthStore";
import { fetchWithTimeout } from "@/utils/fetchWithTimeout";

export async function adminRpc(action: string, payload?: Record<string, unknown>) {
  const auth = useAppAuthStore();
  auth.ensureHydrated();
  const token = auth.adminToken;
  if (!token) {
    throw new Error("Nicht authentifiziert");
  }

  const res = await fetchWithTimeout("/api/admin-rpc", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ action, payload: payload ?? {} }),
  });

  let body: Record<string, unknown>;
  try {
    body = await res.json();
  } catch {
    throw new Error("Ungültige Server-Antwort");
  }
  if (!res.ok) {
    throw new Error((body?.error as string) || "Anfrage fehlgeschlagen");
  }
  return body?.data;
}

export async function fetchAdminReportSummary(payload: Record<string, unknown>) {
  const auth = useAppAuthStore();
  auth.ensureHydrated();
  const token = auth.adminToken;
  if (!token) {
    throw new Error("Nicht authentifiziert");
  }

  const res = await fetchWithTimeout("/api/admin-report-summary", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
  });

  let body: Record<string, unknown>;
  try {
    body = await res.json();
  } catch {
    throw new Error("Ungültige Server-Antwort");
  }
  if (!res.ok) {
    throw new Error((body?.error as string) || "Anfrage fehlgeschlagen");
  }
  return body;
}
