// src/stores/useAdminProductsStore.ts
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

export const useAdminProductsStore = defineStore("adminProducts", {
  state: () => ({
    products: [] as any[],
    categories: [] as any[],
    loading: false,
  }),

  actions: {
    async initProducts() {
      this.loading = true;
      const data = await apiRequest("/api/admin-products");

      this.products = (data ?? []).map((p: any) => ({
        ...p,
        priceEuro: p.price / 100,
        guestPriceEuro: p.guest_price / 100,
      }));
      this.loading = false;
    },

    async initCategories() {
      const data = await apiRequest("/api/admin-product-categories");
      this.categories = (data ?? []).map((c: any) => ({
        id: c.id,
        name: c.name,
        active: Boolean(c.active),
        sort_order: Number(c.sort_order ?? 0),
        created_at: c.created_at ?? null,
        product_count: Number(c.product_count ?? 0),
      }));
    },

    async addCategory(name: string) {
      await apiRequest("/api/admin-product-categories", "POST", {
        name,
      });
      await this.initCategories();
    },

    async updateCategory(category: any) {
      await apiRequest("/api/admin-product-categories", "PATCH", {
        id: category.id,
        name: category.name,
        active: category.active,
        sort_order: category.sort_order,
      });
      await this.initCategories();
      await this.initProducts();
    },

    async addProduct(p: any) {
      await apiRequest("/api/admin-products", "POST", {
        name: p.name,
        category: p.category,
        price: Math.round(p.priceEuro * 100),
        guest_price: Math.round(p.guestPriceEuro * 100),
        active: p.active,
        inventoried: p.inventoried,
      });
      await this.initProducts();
    },

    async updateProduct(p: any) {
      await apiRequest("/api/admin-products", "PATCH", {
        id: p.id,
        name: p.name,
        price: Math.round(p.priceEuro * 100),
        guest_price: Math.round(p.guestPriceEuro * 100),
        category: p.category,
        active: p.active,
        inventoried: p.inventoried,
      });
    },

    async deleteProduct(id: string, force = false) {
      await apiRequest("/api/admin-products", "DELETE", {
        id,
        force,
      });
      await this.initProducts();
    },

    async uploadProductImage(productId: string, imageDataUrl: string) {
      return await apiRequest("/api/admin-product-image", "POST", {
        product_id: productId,
        image_data_url: imageDataUrl,
      });
    },

    async deleteProductImage(productId: string) {
      await apiRequest("/api/admin-product-image", "DELETE", {
        product_id: productId,
      });
    },

    // === Erweiterung für Lagerverwaltung ===
    async loadProductsWithStorage() {
      this.loading = true;
      const data = await apiRequest("/api/admin-products");

      // Nur inventarisierte Produkte, alphabetisch sortiert
      const filtered = (data ?? [])
        .filter((p: any) => p.inventoried === true)
        .filter((p: any) => p.active === true)
        .sort((a: any, b: any) => a.name.localeCompare(b.name));

      this.products = filtered.map((p: any) => ({
        ...p,
        priceEuro: p.price / 100,
        guestPriceEuro: p.guest_price / 100,
        warehouse_stock: p.warehouse_stock ?? 0,
        fridge_stock: p.fridge_stock ?? 0,
        total_stock: Number(p.warehouse_stock ?? 0) + Number(p.fridge_stock ?? 0),
        last_restocked_at: p.last_restocked_at,
        delta: 0,
      }));
      this.loading = false;
    },

    async updateStorageChanges() {
      const changed = this.products.filter((p) => p.delta && p.delta !== 0);
      await apiRequest("/api/admin-storage", "POST", {
        items: changed.map((p) => ({ product_id: p.id, amount: p.delta })),
      });
      await this.loadProductsWithStorage();
    },
  },
});
