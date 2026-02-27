import { defineStore } from "pinia";
import { useAppAuthStore } from "@/stores/useAppAuthStore";

async function apiRequest(path: string, method = "GET", body?: unknown) {
  const auth = useAppAuthStore();
  auth.initFromStorage();
  const token = auth.adminToken;
  if (!token) throw new Error("Unauthorized");

  const res = await fetch(path, {
    method,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  if (res.status === 204) return null;
  const payload = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(payload?.error || "Request failed");
  return payload;
}

export const useAdminMembersStore = defineStore("adminMembers", {
  state: () => ({
    members: [] as any[],
    loading: false,
    error: null as string | null,
    initialized: false,
  }),

  actions: {
    // 🧱 Einmalige Initialisierung
    async initMembers() {
      if (this.initialized) return;
      this.initialized = true;
      await this.loadMembers();
    },

    async loadMembers() {
      this.loading = true;
      this.error = null;
      try {
        const data = await apiRequest("/api/admin-members");
        this.members = data ?? [];
      } catch (err: any) {
        console.error("[loadMembers]", err);
        this.error = "⚠️ Fehler beim Laden der Mitglieder";
      } finally {
        this.loading = false;
      }
    },

    async addMember(firstname: string, lastname: string) {
      await apiRequest("/api/admin-members", "POST", {
        firstname,
        lastname,
      });
      await this.loadMembers();
    },

    async updateMember(member: any) {
      await apiRequest("/api/admin-members", "PATCH", {
        id: member.id,
        firstname: member.firstname ?? null,
        lastname: member.lastname ?? null,
        balance: member.balance ?? null,
        active: member.active ?? null,
      });
      await this.loadMembers();
    },

    async deleteMember(id: string, force = false) {
      await apiRequest("/api/admin-members", "DELETE", {
        id,
        force,
      });
      await this.loadMembers();
    },
  },
});
