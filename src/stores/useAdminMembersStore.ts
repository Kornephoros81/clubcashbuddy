import { defineStore } from "pinia";
import { adminFetch, adminRpc } from "@/lib/adminApi";

function apiRequest(path: string, method = "GET", body?: unknown) {
  return adminFetch(path, { method, body });
}

export const useAdminMembersStore = defineStore("adminMembers", {
  state: () => ({
    members: [] as any[],
    archivedMembers: [] as any[],
    loading: false,
    archivedLoading: false,
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

    async loadArchivedMembers() {
      this.archivedLoading = true;
      try {
        const data = await adminRpc("list_archived_members");
        this.archivedMembers = Array.isArray(data) ? data : [];
      } finally {
        this.archivedLoading = false;
      }
    },

    async findArchivedCandidates(firstname: string, lastname: string) {
      const data = await adminRpc("find_archived_member_candidates", {
        firstname,
        lastname,
      });
      return Array.isArray(data) ? data : [];
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

    async archiveMember(id: string) {
      await adminRpc("archive_member", {
        member_id: id,
      });
      this.members = this.members.filter((member) => member.id !== id);
      await this.loadArchivedMembers();
    },

    async restoreArchivedMember(id: string) {
      const restored = await adminRpc("restore_archived_member", {
        member_id: id,
      });
      this.archivedMembers = this.archivedMembers.filter((member) => member.id !== id);
      this.upsertMemberInState(restored);
      return restored;
    },

  },
});
