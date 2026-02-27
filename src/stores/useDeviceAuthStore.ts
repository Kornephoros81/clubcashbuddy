import { defineStore } from "pinia";
import { createClient } from "@supabase/supabase-js";

export const useDeviceAuthStore = defineStore("deviceAuth", {
  state: () => ({
    token: localStorage.getItem("device_token") || null,
    deviceName: localStorage.getItem("device_name") || null,
    authenticated: false,
    supabase: null as any,
    initializing: true, // 🟢 Flag: wird true bis init abgeschlossen ist
    initialized: false, // 🧩 verhindert doppeltes Setup in Tabs
  }),

  actions: {
    isAuthStatus(status: number) {
      return status === 401 || status === 403;
    },

    handleAuthStatus(status: number) {
      if (this.isAuthStatus(status)) {
        this.logout(false);
        return true;
      }
      return false;
    },

    // ----------------------------------------------------
    // 🔧 Initialisierung beim Start
    // ----------------------------------------------------
    async initFromStorage() {
      if (this.initialized) return; // Schutz gegen Mehrfachaufrufe
      this.initialized = true;

      const token = localStorage.getItem("device_token");
      const name = localStorage.getItem("device_name");

      if (token) {
        this.token = token;
        this.deviceName = name;
        this.authenticated = true;
        this.initSupabase();
      } else {
        this.clearLocal();
      }

      // Cross-Tab Sync (Logout/Login in anderem Tab)
      if (typeof window !== "undefined") {
        window.addEventListener("storage", (e) => {
          if (e.key === "device_token") {
            if (!e.newValue) this.logout(false);
            else if (e.newValue) {
              this.token = e.newValue;
              this.authenticated = true;
              this.initSupabase();
            }
          }
        });
      }

      this.initializing = false; // ✅ jetzt ist init abgeschlossen
    },

    // ----------------------------------------------------
    // 🔌 Supabase-Client initialisieren
    // ----------------------------------------------------
    initSupabase() {
      if (!this.token) return;
      this.supabase = createClient(
        import.meta.env.VITE_SUPABASE_URL,
        import.meta.env.VITE_SUPABASE_ANON_KEY,
        { global: { headers: { Authorization: `Bearer ${this.token}` } } }
      );
    },

    // ----------------------------------------------------
    // 🔐 Geräte-Kopplung (Einmalcode)
    // ----------------------------------------------------
    async authenticateDevice(pairCode: string) {
      const res = await fetch("/api/device-pair", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${import.meta.env.VITE_SUPABASE_ANON_KEY}`,
        },
        body: JSON.stringify({ pair_code: pairCode }),
      });

      if (!res.ok) {
        const err = await res.text();
        console.error("Device pairing failed:", res.status, err);
        throw new Error("Ungültiger oder abgelaufener Pairing-Code");
      }

      const { token, device_name } = await res.json();

      localStorage.setItem("device_token", token);
      localStorage.setItem("device_name", device_name);

      this.token = token;
      this.deviceName = device_name;
      this.authenticated = true;
      this.initSupabase();
    },

    // ----------------------------------------------------
    // 🚪 Logout
    // ----------------------------------------------------
    logout(reload: boolean = true) {
      this.clearLocal();
      this.token = null;
      this.authenticated = false;
      this.supabase = null;

      if (reload && typeof window !== "undefined") location.reload();
    },

    // ----------------------------------------------------
    // 🧹 Helper: lokale Daten löschen
    // ----------------------------------------------------
    clearLocal() {
      localStorage.removeItem("device_token");
      localStorage.removeItem("device_name");
      this.deviceName = null;
      this.token = null;
      this.authenticated = false;
    },
  },
});
