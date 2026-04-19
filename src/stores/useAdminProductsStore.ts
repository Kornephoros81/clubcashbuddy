// src/stores/useAdminProductsStore.ts
import { defineStore } from "pinia";
import { useAppAuthStore } from "@/stores/useAppAuthStore";
import { invalidateProductsCache } from "@/utils/productCatalogCache";

async function apiRequest(path: string, method = "GET", body?: unknown) {
  const auth = useAppAuthStore();
  auth.ensureHydrated();
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
    normalizeProduct(p: any) {
      return {
        ...p,
        priceEuro: Number(p.price ?? 0) / 100,
        guestPriceEuro: Number(p.guest_price ?? 0) / 100,
        lastPurchasePriceEuro: Number(p.last_purchase_price_cents ?? 0) / 100,
        inventoryValueEuro: Number(p.inventory_value_cents ?? 0) / 100,
      };
    },

    upsertProductInState(product: any) {
      const next = product?.id ? this.normalizeProduct(product) : null;
      if (!next?.id) return;
      const index = this.products.findIndex((entry) => entry.id === next.id);
      if (index >= 0) {
        this.products.splice(index, 1, next);
      } else {
        this.products.unshift(next);
      }
    },

    async initProducts() {
      this.loading = true;
      try {
        const data = await apiRequest("/api/admin-products");
        this.products = (data ?? []).map((p: any) => this.normalizeProduct(p));
      } finally {
        this.loading = false;
      }
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
      await invalidateProductsCache();
      await this.initCategories();
    },

    async updateCategory(category: any) {
      await apiRequest("/api/admin-product-categories", "PATCH", {
        id: category.id,
        name: category.name,
        active: category.active,
        sort_order: category.sort_order,
      });
      await invalidateProductsCache();
      await this.initCategories();
      await this.initProducts();
    },

    async addProduct(p: any) {
      const created = await apiRequest("/api/admin-products", "POST", {
        name: p.name,
        category: p.category,
        price: Math.round(p.priceEuro * 100),
        guest_price: Math.round(p.guestPriceEuro * 100),
        last_purchase_price_cents: Math.round(Number(p.lastPurchasePriceEuro ?? 0) * 100),
        active: p.active,
        inventoried: p.inventoried,
      });
      await invalidateProductsCache();
      this.upsertProductInState(created);
      return created;
    },

    async updateProduct(p: any) {
      const data = await apiRequest("/api/admin-products", "PATCH", {
        id: p.id,
        name: p.name,
        price: Math.round(p.priceEuro * 100),
        guest_price: Math.round(p.guestPriceEuro * 100),
        last_purchase_price_cents: Math.round(Number(p.lastPurchasePriceEuro ?? 0) * 100),
        category: p.category,
        active: p.active,
        inventoried: p.inventoried,
      });
      await invalidateProductsCache();
      this.upsertProductInState(data);
      return data;
    },

    async updateProductsBatch(products: any[]) {
      const payload = Array.isArray(products)
        ? products.map((p) => ({
            id: p.id,
            name: p.name,
            price: Math.round(Number(p.priceEuro ?? 0) * 100),
            guest_price: Math.round(Number(p.guestPriceEuro ?? 0) * 100),
            last_purchase_price_cents: Math.round(Number(p.lastPurchasePriceEuro ?? 0) * 100),
            category: p.category,
            active: p.active,
            inventoried: p.inventoried,
          }))
        : [];
      const data = await apiRequest("/api/admin-products-batch", "PATCH", {
        items: payload,
      });
      await invalidateProductsCache();
      const items = Array.isArray((data as any)?.items) ? (data as any).items : [];
      for (const item of items) {
        this.upsertProductInState(item);
      }
      return items;
    },

    async deleteProduct(id: string, force = false) {
      await apiRequest("/api/admin-products", "DELETE", {
        id,
        force,
      });
      await invalidateProductsCache();
      this.products = this.products.filter((product) => product.id !== id);
    },

    async uploadProductImage(productId: string, imageDataUrl: string) {
      const data = await apiRequest("/api/admin-product-image", "POST", {
        product_id: productId,
        image_data_url: imageDataUrl,
      });
      await invalidateProductsCache();
      this.upsertProductInState(data);
      return data;
    },

    async deleteProductImage(productId: string) {
      const data = await apiRequest("/api/admin-product-image", "DELETE", {
        product_id: productId,
      });
      await invalidateProductsCache();
      this.upsertProductInState(data);
      return data;
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
        lastPurchasePriceEuro: Number(p.last_purchase_price_cents ?? 0) / 100,
        inventoryValueEuro: Number(p.inventory_value_cents ?? 0) / 100,
        warehouse_stock: p.warehouse_stock ?? 0,
        fridge_stock: p.fridge_stock ?? 0,
        total_stock: Number(p.warehouse_stock ?? 0) + Number(p.fridge_stock ?? 0),
        last_restocked_at: p.last_restocked_at,
        last_purchase_price_cents: Number(p.last_purchase_price_cents ?? 0),
        inventory_value_cents: Number(p.inventory_value_cents ?? 0),
        purchasePriceEuro:
          Number(p.last_purchase_price_cents ?? 0) > 0
            ? Number(p.last_purchase_price_cents ?? 0) / 100
            : null,
        delta: 0,
      }));
      this.loading = false;
    },

    async updateStorageChanges() {
      const changed = this.products.filter((p) => p.delta && p.delta !== 0);
      const invalidPurchasePrice = changed.find((p) =>
        Number(p.delta ?? 0) > 0
          && (
            p.purchasePriceEuro === null
            || p.purchasePriceEuro === undefined
            || p.purchasePriceEuro === ""
            || !Number.isFinite(Number(p.purchasePriceEuro))
          ),
      );
      if (invalidPurchasePrice) {
        throw new Error(`Einkaufspreis fehlt für ${invalidPurchasePrice.name}`);
      }
      await apiRequest("/api/admin-storage", "POST", {
        items: changed.map((p) => ({
          product_id: p.id,
          amount: p.delta,
          purchase_price_cents:
            Number(p.delta ?? 0) > 0
              ? Math.round(Number(p.purchasePriceEuro ?? p.lastPurchasePriceEuro ?? 0) * 100)
              : null,
        })),
      });
      await this.loadProductsWithStorage();
    },
  },
});
