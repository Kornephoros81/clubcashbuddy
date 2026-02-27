import { defineStore } from "pinia";

const ADMIN_TOKEN_KEY = "app_admin_token";
const ADMIN_USER_KEY = "app_admin_user";

export const useAppAuthStore = defineStore("appAuth", {
  state: () => ({
    adminToken: (typeof localStorage !== "undefined" ? localStorage.getItem(ADMIN_TOKEN_KEY) : null) as string | null,
    adminUser: (typeof localStorage !== "undefined" ? localStorage.getItem(ADMIN_USER_KEY) : null) as string | null,
  }),

  getters: {
    isAdminAuthenticated: (state) => Boolean(state.adminToken),
  },

  actions: {
    initFromStorage() {
      if (typeof localStorage === "undefined") return;
      this.adminToken = localStorage.getItem(ADMIN_TOKEN_KEY);
      this.adminUser = localStorage.getItem(ADMIN_USER_KEY);
    },

    async loginAdmin(username: string, password: string) {
      const res = await fetch("/api/admin-login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password }),
      });

      const payload = await res.json().catch(() => ({}));
      if (!res.ok) {
        throw new Error(payload?.error || "Login fehlgeschlagen");
      }

      const token = payload?.token;
      if (!token) {
        throw new Error("Keine Session erhalten");
      }

      if (typeof localStorage !== "undefined") {
        localStorage.setItem(ADMIN_TOKEN_KEY, token);
        localStorage.setItem(ADMIN_USER_KEY, username);
      }

      this.adminToken = token;
      this.adminUser = username;
    },

    async logoutAdmin() {
      try {
        if (this.adminToken) {
          await fetch("/api/admin-logout", {
            method: "POST",
            headers: { Authorization: `Bearer ${this.adminToken}` },
          });
        }
      } finally {
        if (typeof localStorage !== "undefined") {
          localStorage.removeItem(ADMIN_TOKEN_KEY);
          localStorage.removeItem(ADMIN_USER_KEY);
        }
        this.adminToken = null;
        this.adminUser = null;
      }
    },
  },
});
