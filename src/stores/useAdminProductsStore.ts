// src/stores/useAdminProductsStore.ts
import { defineStore } from "pinia";
import { adminFetch } from "@/lib/adminApi";
import { invalidateProductsCache } from "@/utils/productCatalogCache";

function apiRequest(path: string, method = "GET", body?: unknown) {
  return adminFetch(path, { method, body });
}

export const useAdminProductsStore = defineStore("adminProducts", {
  state: () => ({
    products: [] as any[],
    purchaseLots: [] as any[],
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
        mhdSaleEnabled: Boolean(p.mhd_sale_enabled),
        inventoryValueEuro: Number(p.inventory_value_cents ?? 0) / 100,
      };
    },

    normalizePurchaseLot(lot: any) {
      return {
        ...lot,
        unitCostEuro: Number(lot.unit_cost_cents ?? 0) / 100,
        isFallback: lot.source_reason === "sale_fallback",
        isClosed: Boolean(lot.closed_at) || (Number(lot.remaining_quantity ?? 0) === 0 && lot.source_reason !== "sale_fallback"),
        costPending: Boolean(lot.cost_pending),
        pendingAllocationCount: Number(lot.pending_allocation_count ?? 0),
        correctedFromPriceEuro:
          lot.corrected_from_price_cents === null || lot.corrected_from_price_cents === undefined
            ? null
            : Number(lot.corrected_from_price_cents ?? 0) / 100,
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
        active: p.active,
        inventoried: p.inventoried,
        last_purchase_price_cents: Math.round(Number(p.lastPurchasePriceEuro ?? 0) * 100),
        mhd_sale_enabled: Boolean(p.mhdSaleEnabled),
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
        category: p.category,
        active: p.active,
        inventoried: p.inventoried,
        last_purchase_price_cents: Math.round(Number(p.lastPurchasePriceEuro ?? 0) * 100),
        mhd_sale_enabled: Boolean(p.mhdSaleEnabled),
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
            category: p.category,
            active: p.active,
            inventoried: p.inventoried,
            last_purchase_price_cents: Math.round(Number(p.lastPurchasePriceEuro ?? 0) * 100),
            mhd_sale_enabled: Boolean(p.mhdSaleEnabled),
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
      try {
        const data = await apiRequest("/api/admin-products");

        // Nur inventarisierte Produkte, alphabetisch sortiert
        const filtered = (data ?? [])
          .filter((p: any) => p.inventoried === true)
          .filter((p: any) => p.active === true)
          .sort((a: any, b: any) => a.name.localeCompare(b.name));

        this.products = filtered.map((p: any) => ({
          ...this.normalizeProduct(p),
          warehouse_stock: p.warehouse_stock ?? 0,
          total_stock: Number(p.warehouse_stock ?? 0),
          last_restocked_at: p.last_restocked_at,
          last_purchase_price_cents: Number(p.last_purchase_price_cents ?? 0),
          inventory_value_cents: Number(p.inventory_value_cents ?? 0),
          purchasePriceEuro:
            Number(p.last_purchase_price_cents ?? 0) > 0
              ? Number(p.last_purchase_price_cents ?? 0) / 100
              : null,
          delta: 0,
        }));
      } finally {
        this.loading = false;
      }
    },

    async loadPurchaseLots(productId: string | null = null, lotState: "active" | "closed" | "all" = "active") {
      const params = new URLSearchParams();
      if (productId) params.set("product_id", productId);
      params.set("lot_state", lotState);
      const query = params.toString();
      const data = await apiRequest(`/api/admin-product-lots${query ? `?${query}` : ""}`);
      this.purchaseLots = (data ?? []).map((lot: any) => this.normalizePurchaseLot(lot));
    },

    async updatePurchaseLot(lot: any) {
      const data = await apiRequest("/api/admin-product-lots", "PATCH", {
        id: lot.id,
        unit_cost_cents: Math.round(Number(lot.unitCostEuro ?? 0) * 100),
        note: lot.note ?? null,
      });
      await this.loadProductsWithStorage();
      return this.normalizePurchaseLot(data);
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
      await this.loadPurchaseLots(null, "active");
    },
  },
});
