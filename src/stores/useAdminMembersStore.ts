import { defineStore } from "pinia";
import { adminFetch } from "@/lib/adminApi";

function apiRequest(path: string, method = "GET", body?: unknown) {
  return adminFetch(path, { method, body });
}

export const useAdminMembersStore = defineStore("adminMembers", {
  state: () => ({
    members: [] as any[],
    loading: false,
    error: null as string | null,
    initialized: false,
  }),

  actions: {
    upsertMemberInState(member: any) {
      const next = member ? { ...member } : null;
      if (!next?.id) return;
      const index = this.members.findIndex((entry) => entry.id === next.id);
      if (index >= 0) {
        this.members.splice(index, 1, next);
      } else {
        this.members.unshift(next);
      }
    },

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
      const created = await apiRequest("/api/admin-members", "POST", {
        firstname,
        lastname,
      });
      this.upsertMemberInState(created);
      return created;
    },

    async updateMember(member: any) {
      const updated = await apiRequest("/api/admin-members", "PATCH", {
        id: member.id,
        firstname: member.firstname ?? null,
        lastname: member.lastname ?? null,
        balance: member.balance ?? null,
        active: member.active ?? null,
      });
      this.upsertMemberInState(updated);
      return updated;
    },

    async deleteMember(id: string, force = false) {
      await apiRequest("/api/admin-members", "DELETE", {
        id,
        force,
      });
      this.members = this.members.filter((member) => member.id !== id);
    },
  },
});
