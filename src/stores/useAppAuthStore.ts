import { defineStore } from "pinia";

const ADMIN_TOKEN_KEY = "app_admin_token";
const ADMIN_USER_KEY = "app_admin_user";

function readAdminSessionValue(key: string) {
  if (typeof window === "undefined") return null;
  const sessionValue = window.sessionStorage.getItem(key);
  if (sessionValue) return sessionValue;

  const legacyValue = window.localStorage.getItem(key);
  if (legacyValue) {
    window.sessionStorage.setItem(key, legacyValue);
    window.localStorage.removeItem(key);
    return legacyValue;
  }

  return null;
}

function writeAdminSessionValue(key: string, value: string) {
  if (typeof window === "undefined") return;
  window.sessionStorage.setItem(key, value);
  window.localStorage.removeItem(key);
}

function clearAdminSessionValue(key: string) {
  if (typeof window === "undefined") return;
  window.sessionStorage.removeItem(key);
  window.localStorage.removeItem(key);
}

export const useAppAuthStore = defineStore("appAuth", {
  state: () => ({
    adminToken: readAdminSessionValue(ADMIN_TOKEN_KEY) as string | null,
    adminUser: readAdminSessionValue(ADMIN_USER_KEY) as string | null,
  }),

  getters: {
    isAdminAuthenticated: (state) => Boolean(state.adminToken),
  },

  actions: {
    initFromStorage() {
      this.adminToken = readAdminSessionValue(ADMIN_TOKEN_KEY);
      this.adminUser = readAdminSessionValue(ADMIN_USER_KEY);
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

      writeAdminSessionValue(ADMIN_TOKEN_KEY, token);
      writeAdminSessionValue(ADMIN_USER_KEY, username);

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
        clearAdminSessionValue(ADMIN_TOKEN_KEY);
        clearAdminSessionValue(ADMIN_USER_KEY);
        this.adminToken = null;
        this.adminUser = null;
      }
    },
  },
});
