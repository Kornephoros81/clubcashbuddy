import { useAppAuthStore } from "@/stores/useAppAuthStore";

export async function adminRpc(action: string, payload?: Record<string, unknown>) {
  const auth = useAppAuthStore();
  auth.initFromStorage();
  const token = auth.adminToken;
  if (!token) {
    throw new Error("Unauthorized");
  }

  const res = await fetch("/api/admin-rpc", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ action, payload: payload ?? {} }),
  });

  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(body?.error || "Request failed");
  }
  return body?.data;
}
