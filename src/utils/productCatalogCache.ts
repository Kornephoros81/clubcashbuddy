import { clearCachedProducts } from "@/utils/offlineDB";

export const PRODUCTS_CACHE_META_KEY = "clubcashbuddy_products_cache_meta";

export function markProductsCacheFresh() {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(PRODUCTS_CACHE_META_KEY, String(Date.now()));
}

export async function invalidateProductsCache() {
  if (typeof window !== "undefined") {
    window.localStorage.removeItem(PRODUCTS_CACHE_META_KEY);
  }
  await clearCachedProducts();
}
