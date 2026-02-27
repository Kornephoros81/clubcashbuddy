// src/stores/useCatalog.ts
import { defineStore } from "pinia";
import { useDeviceAuthStore } from "@/stores/useDeviceAuthStore";
import {
  cacheMembers,
  getCachedMembers,
  cacheProducts,
  getCachedProducts,
} from "@/utils/offlineDB";

export type Member = {
  id: string;
  name: string;
  active?: boolean;
  is_guest?: boolean;
  settled?: boolean;
  last_booking_at?: string | null;
  has_booked_today?: boolean;
};

export type Product = {
  id: string;
  name: string;
  price: number;
  guest_price: number;
  category: string;
  active: boolean;
  inventoried?: boolean;
  image_url?: string | null;
};

export const useCatalog = defineStore("catalog", {
  state: () => ({
    members: [] as Member[],
    products: [] as Product[],
  }),

  actions: {
    async applyMembers(members: Member[]) {
      this.members.splice(0, this.members.length, ...(Array.isArray(members) ? members : []));
      await cacheMembers(this.members);
    },

    async loadMembers() {
      const auth = useDeviceAuthStore();

      try {
        if (!auth.token) throw new Error("Kein Token");
        const res = await fetch("/api/get-members", {
          method: "POST",
          headers: { Authorization: `Bearer ${auth.token}` },
        });
        if (auth.handleAuthStatus(res.status)) throw new Error("Unauthorized");
        if (!res.ok) throw new Error("HTTP " + res.status);

        const data = await res.json();
        // ✅ Reaktive Mutation
        await this.applyMembers(Array.isArray(data) ? data : []);
        console.log(`[useCatalog] Mitglieder geladen (${this.members.length})`);
      } catch (err) {
        console.warn("[useCatalog] Offline-Fallback:", err);
        const cached = await getCachedMembers();
        if (cached.length) {
          // ✅ Reaktive Mutation statt Zuweisung
          this.members.splice(0, this.members.length, ...cached);
          console.log(`[useCatalog] Cache verwendet (${cached.length})`);
        } else {
          this.members.splice(0, this.members.length);
          console.warn("[useCatalog] Kein Mitglieder-Cache gefunden");
        }
      }
    },

    async loadProducts() {
      try {
        const res = await fetch("/api/catalog-products");
        if (!res.ok) throw new Error("HTTP " + res.status);
        const data = await res.json();

        // ✅ Reaktive Mutation
        this.products.splice(0, this.products.length, ...(data ?? []));
        await cacheProducts(this.products);
        console.log(`[useCatalog] Produkte geladen (${this.products.length})`);
      } catch (err) {
        console.warn("[useCatalog] Offline-Fallback Produkte:", err);
        const cached = await getCachedProducts();
        if (cached.length) {
          // ✅ Reaktive Mutation statt Zuweisung
          this.products.splice(0, this.products.length, ...cached);
          console.log(
            `[useCatalog] Produkt-Cache verwendet (${cached.length})`
          );
        } else {
          this.products.splice(0, this.products.length);
          console.warn("[useCatalog] Kein Produkt-Cache gefunden");
        }
      }
    },
  },
});
