import { clearCachedProducts } from "@/utils/offlineDB";

export async function invalidateProductsCache() {
  await clearCachedProducts();
}
