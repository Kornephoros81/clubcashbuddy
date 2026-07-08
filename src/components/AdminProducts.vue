<script setup lang="ts">
import { computed, ref, onMounted } from "vue";
import { useAdminProductsStore } from "@/stores/useAdminProductsStore";
import { useToast } from "@/composables/useToast";
import { useModal } from "@/composables/useModal";
import BaseModal from "@/components/BaseModal.vue";

const store = useAdminProductsStore();
const { show: showToast } = useToast();
const { confirm } = useModal();

const showNewProductModal = ref(false);
const newProductName = ref("");
const newProductCategory = ref("Sonstiges");
const newProductPrice = ref<number | null>(null);
const newGuestPrice = ref<number | null>(null);
const newLastPurchasePrice = ref<number | null>(null);
const newProductInventoried = ref(true);
const newProductMhdSaleEnabled = ref(false);
const selectedProduct = ref<any | null>(null);
const productDetailSaving = ref(false);
const uploadingImageById = ref<Record<string, boolean>>({});
const brokenPreviewById = ref<Record<string, boolean>>({});
const sortBy = ref<"name" | "category">("category");
const sortDir = ref<"asc" | "desc">("asc");
const searchTerm = ref("");
const statusFilter = ref<"all" | "active" | "inactive">("all");
const categoryFilter = ref("");

onMounted(async () => {
  await store.initCategories();
  await store.initProducts();
  if (!store.categories.some((c) => c.name === newProductCategory.value)) {
    newProductCategory.value = activeCategoryOptions.value[0]?.name ?? "Sonstiges";
  }
});

function setUploading(productId: string, uploading: boolean) {
  uploadingImageById.value = {
    ...uploadingImageById.value,
    [productId]: uploading,
  };
}

function isUploading(productId: string) {
  return Boolean(uploadingImageById.value[productId]);
}

function hasPreviewImage(product: any) {
  const id = String(product?.id ?? "");
  return Boolean(product?.image_url) && !brokenPreviewById.value[id];
}

function onPreviewImageError(productId: string) {
  brokenPreviewById.value = {
    ...brokenPreviewById.value,
    [String(productId)]: true,
  };
}

async function fileToDataUrl(file: File): Promise<string> {
  return await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result ?? ""));
    reader.onerror = () => reject(new Error("Datei konnte nicht gelesen werden"));
    reader.readAsDataURL(file);
  });
}

async function onProductImageSelected(product: any, event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input?.files?.[0];
  if (!file) return;

  if (!file.type.startsWith("image/")) {
    showToast("⚠️ Bitte eine Bilddatei auswählen");
    input.value = "";
    return;
  }

  if (file.size > 600 * 1024) {
    showToast("⚠️ Bild zu groß (max. 600 KB)");
    input.value = "";
    return;
  }

  setUploading(product.id, true);
  try {
    const dataUrl = await fileToDataUrl(file);
    const updated = await store.uploadProductImage(product.id, dataUrl);
    if (selectedProduct.value?.id === product.id) {
      selectedProduct.value = {
        ...selectedProduct.value,
        ...updated,
        originalInventoried: selectedProduct.value.originalInventoried,
      };
    }
    brokenPreviewById.value = {
      ...brokenPreviewById.value,
      [String(product.id)]: false,
    };
    showToast(`✅ Bild für ${product.name} gespeichert`);
  } catch (err) {
    console.error("[uploadProductImage]", err);
    showToast("⚠️ Fehler beim Bild-Upload");
  } finally {
    input.value = "";
    setUploading(product.id, false);
  }
}

async function removeProductImage(product: any) {
  const ok = await confirm(
    "Bild entfernen",
    `Soll das Bild für "${product.name}" gelöscht werden?`,
    { danger: true }
  );
  if (!ok) return;

  setUploading(product.id, true);
  try {
    const updated = await store.deleteProductImage(product.id);
    if (selectedProduct.value?.id === product.id) {
      selectedProduct.value = {
        ...selectedProduct.value,
        ...updated,
        originalInventoried: selectedProduct.value.originalInventoried,
      };
    }
    brokenPreviewById.value = {
      ...brokenPreviewById.value,
      [String(product.id)]: false,
    };
    showToast(`🗑️ Bild für ${product.name} gelöscht`);
  } catch (err) {
    console.error("[removeProductImage]", err);
    showToast("⚠️ Fehler beim Löschen des Bildes");
  } finally {
    setUploading(product.id, false);
  }
}

const activeCategoryOptions = computed(() =>
  [...store.categories]
    .filter((c) => c.active)
    .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name))
);

const productCategoryOptions = computed(() => {
  const used = new Set((store.products ?? []).map((p: any) => String(p.category ?? "")));
  return [...store.categories]
    .filter((c) => c.active || used.has(c.name))
    .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
});

const sortedProducts = computed(() => {
  const collator = new Intl.Collator("de", { sensitivity: "base", numeric: true });
  const factor = sortDir.value === "asc" ? 1 : -1;
  const query = searchTerm.value.trim().toLocaleLowerCase("de-DE");
  return [...store.products]
    .filter((product: any) => {
      const matchesSearch =
        !query
        || String(product?.name ?? "").toLocaleLowerCase("de-DE").includes(query);
      const matchesStatus =
        statusFilter.value === "all"
          ? true
          : statusFilter.value === "active"
            ? Boolean(product?.active)
            : !product?.active;
      const matchesCategory =
        !categoryFilter.value || String(product?.category ?? "") === categoryFilter.value;
      return matchesSearch && matchesStatus && matchesCategory;
    })
    .sort((a: any, b: any) => {
    const av = String(a?.[sortBy.value] ?? "");
    const bv = String(b?.[sortBy.value] ?? "");
    const primary = collator.compare(av, bv) * factor;
    if (primary !== 0) return primary;
    if (sortBy.value === "category") {
      const an = String(a?.name ?? "");
      const bn = String(b?.name ?? "");
      return collator.compare(an, bn);
    }
      return 0;
    });
});

function toggleSort(column: "name" | "category") {
  if (sortBy.value === column) {
    sortDir.value = sortDir.value === "asc" ? "desc" : "asc";
    return;
  }
  sortBy.value = column;
  sortDir.value = "asc";
}

function sortIndicator(column: "name" | "category") {
  if (sortBy.value !== column) return "";
  return sortDir.value === "asc" ? " ▲" : " ▼";
}

function formatEuro(value: unknown) {
  const cents = Math.round(Number(value ?? 0) * 100);
  return `${(cents / 100).toFixed(2)} €`;
}

function openProductDetails(product: any) {
  selectedProduct.value = {
    ...product,
    originalInventoried: Boolean(product.inventoried),
    mhdSaleEnabled: Boolean(product.mhdSaleEnabled ?? product.mhd_sale_enabled),
  };
}

function closeProductDetails() {
  selectedProduct.value = null;
}

async function saveSelectedProduct() {
  const product = selectedProduct.value;
  if (!product?.id) return;
  if (!String(product.name ?? "").trim()) {
    showToast("⚠️ Bitte Artikelnamen angeben");
    return;
  }

  if (product.originalInventoried === true && product.inventoried === false) {
    const ok = await confirm(
      "Inventarisierung deaktivieren",
      "Das ist nur möglich, wenn der aktuelle Bestand 0 ist. Alte Buchungen bleiben historisch inventarisiert. Fortfahren?",
      { danger: true }
    );
    if (!ok) return;
  }

  productDetailSaving.value = true;
  try {
    const updated = await store.updateProduct({
      ...product,
      name: String(product.name ?? "").trim(),
      category: String(product.category ?? "").trim() || "Sonstiges",
    });
    showToast("✅ Artikel gespeichert");
    selectedProduct.value = {
      ...updated,
      originalInventoried: Boolean(updated.inventoried),
    };
    closeProductDetails();
  } catch (err) {
    console.error("[saveSelectedProduct]", err);
    showToast(`⚠️ ${String((err as any)?.message ?? "Fehler beim Speichern des Artikels")}`);
  } finally {
    productDetailSaving.value = false;
  }
}

/* ➕ Neues Produkt */
async function confirmAddProduct() {
  try {
    if (!newProductName.value.trim()) {
      showToast("⚠️ Bitte Produktnamen angeben");
      return;
    }

    await store.addProduct({
      name: newProductName.value.trim(),
      category: newProductCategory.value.trim() || "Sonstiges",
      priceEuro: newProductPrice.value ?? 0,
      guestPriceEuro: newGuestPrice.value ?? 0,
      lastPurchasePriceEuro: newLastPurchasePrice.value ?? 0,
      active: true,
      inventoried: newProductInventoried.value,
      mhdSaleEnabled: newProductMhdSaleEnabled.value,
    });

    showToast("✅ Neuer Artikel angelegt");
    newProductName.value = "";
    newProductCategory.value = activeCategoryOptions.value[0]?.name ?? "Sonstiges";
    newProductPrice.value = null;
    newGuestPrice.value = null;
    newLastPurchasePrice.value = null;
    newProductInventoried.value = true;
    newProductMhdSaleEnabled.value = false;
    showNewProductModal.value = false;
  } catch (err) {
    console.error("[add]", err);
    showToast("⚠️ Fehler beim Hinzufügen");
  }
}

/* 🗑️ Löschen */
async function deleteProduct(p: any) {
  const ok = await confirm(
    "Artikel löschen",
    `Soll der Artikel "${p.name}" wirklich gelöscht werden?`,
    { danger: true }
  );
  if (!ok) return;

  try {
    await store.deleteProduct(p.id, false);
    if (selectedProduct.value?.id === p.id) closeProductDetails();
    showToast(`🗑️ ${p.name} gelöscht`);
  } catch (err) {
    const message = String((err as any)?.message ?? err ?? "");
    if (message.includes("p_force=true")) {
      const force = await confirm(
        "Hart löschen",
        `Bei "${p.name}" besteht noch Bestand. Wirklich endgültig löschen?`,
        { danger: true }
      );
      if (!force) return;

      try {
        await store.deleteProduct(p.id, true);
        if (selectedProduct.value?.id === p.id) closeProductDetails();
        showToast(`🗑️ ${p.name} endgültig gelöscht`);
        return;
      } catch (forceErr) {
        console.error("[deleteProduct.force]", forceErr);
      }
    }

    console.error("[deleteProduct]", err);
    showToast("⚠️ Fehler beim Löschen");
  }
}
</script>

<template>
  <div class="space-y-6">
    <!-- Header -->
    <div class="flex flex-col xl:flex-row justify-between items-start xl:items-center gap-3">
      <h2 class="text-xl font-semibold text-primary">Artikelverwaltung</h2>

      <div class="flex flex-col sm:flex-row gap-2 w-full xl:w-auto">
        <RouterLink
          to="/admin/product-categories"
          class="bg-primary/10 text-primary px-4 py-2 rounded-lg shadow hover:bg-primary/20 transition text-center"
        >
          Kategorien
        </RouterLink>
        <button
          @click="showNewProductModal = true"
          class="bg-green-600 text-white px-4 py-2 rounded-lg shadow hover:bg-green-700 transition"
        >
          + Artikel
        </button>
      </div>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4">
      <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
        <div>
          <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Suche</label>
          <input
            v-model="searchTerm"
            type="text"
            placeholder="Artikelname suchen"
            class="w-full border rounded-md px-3 py-2 text-sm"
          />
        </div>
        <div>
          <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Status</label>
          <select
            v-model="statusFilter"
            class="w-full border rounded-md px-3 py-2 text-sm"
          >
            <option value="all">Alle</option>
            <option value="active">Nur aktiv</option>
            <option value="inactive">Nur inaktiv</option>
          </select>
        </div>
        <div>
          <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Kategorie</label>
          <select
            v-model="categoryFilter"
            class="w-full border rounded-md px-3 py-2 text-sm"
          >
            <option value="">Alle Kategorien</option>
            <option v-for="c in productCategoryOptions" :key="c.id" :value="c.name">
              {{ c.name }}
            </option>
          </select>
        </div>
      </div>
      <div class="mt-3 text-xs text-gray-500">
        {{ sortedProducts.length }} von {{ store.products.length }} Artikeln sichtbar
      </div>
    </div>

    <div v-if="store.loading" class="text-center py-10 text-gray-500">
      ⏳ Artikel werden geladen...
    </div>

    <div v-if="!store.loading" class="space-y-4">
      <div class="lg:hidden space-y-4">
        <div
          v-for="p in sortedProducts"
          :key="p.id"
          class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-4"
        >
          <div class="flex items-start gap-3">
            <div class="shrink-0">
              <img
                v-if="hasPreviewImage(p)"
                :src="p.image_url"
                :alt="`Bild ${p.name}`"
                class="w-16 h-16 object-contain rounded border bg-white"
                @error="onPreviewImageError(p.id)"
              />
              <div
                v-else
                class="w-16 h-16 rounded border bg-gray-100 text-[10px] text-gray-500 flex items-center justify-center text-center leading-tight px-1"
              >
                Kein Bild
              </div>
            </div>
            <div class="min-w-0 flex-1">
              <div class="text-base font-semibold text-gray-900 truncate">{{ p.name }}</div>
              <div class="text-sm text-gray-500 mt-1">{{ p.category }}</div>
              <div class="mt-2 flex flex-wrap gap-2 text-xs">
                <span class="rounded-full px-2 py-1" :class="p.active ? 'bg-emerald-100 text-emerald-700' : 'bg-gray-100 text-gray-600'">
                  {{ p.active ? "Aktiv" : "Inaktiv" }}
                </span>
                <span class="rounded-full px-2 py-1" :class="p.inventoried ? 'bg-blue-100 text-blue-700' : 'bg-gray-100 text-gray-600'">
                  {{ p.inventoried ? "Inventarisiert" : "Nicht inventarisiert" }}
                </span>
                <span v-if="p.mhdSaleEnabled" class="rounded-full bg-amber-100 px-2 py-1 text-amber-700">MHD</span>
              </div>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-3 text-sm">
            <div>
              <div class="text-xs uppercase text-gray-500">Preis</div>
              <div class="font-medium text-gray-900">{{ formatEuro(p.priceEuro) }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Gast</div>
              <div class="font-medium text-gray-900">{{ formatEuro(p.guestPriceEuro) }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">EK</div>
              <div class="font-medium text-gray-900">{{ formatEuro(p.lastPurchasePriceEuro) }}</div>
            </div>
            <div>
              <div class="text-xs uppercase text-gray-500">Kategorie</div>
              <div class="font-medium text-gray-900 truncate">{{ p.category }}</div>
            </div>
          </div>

          <button
            @click="openProductDetails(p)"
            class="w-full bg-primary text-white px-3 py-2 rounded-md hover:bg-primary/90 text-sm font-medium"
          >
            Bearbeiten
          </button>
        </div>
        <div v-if="sortedProducts.length === 0" class="bg-white rounded-2xl shadow border border-gray-200 p-6 text-center text-gray-400 italic">
          Keine Artikel für den gewählten Filter
        </div>
      </div>

      <div
        class="hidden lg:block bg-white rounded-2xl shadow overflow-x-auto border border-gray-200"
      >
      <table class="min-w-full text-sm text-gray-700">
        <thead
          class="bg-primary/10 text-primary uppercase text-xs font-semibold"
        >
          <tr>
            <th class="px-4 py-3 text-left">
              <button @click="toggleSort('name')" class="hover:underline normal-case">
                Name{{ sortIndicator("name") }}
              </button>
            </th>
            <th class="px-4 py-3 text-right">Preis (€)</th>
            <th class="px-4 py-3 text-right">Gast (€)</th>
            <th class="px-4 py-3 text-right">EK (€)</th>
            <th class="px-4 py-3 text-left">
              <button @click="toggleSort('category')" class="hover:underline normal-case">
                Kategorie{{ sortIndicator("category") }}
              </button>
            </th>
            <th class="px-4 py-3 text-left">Bild</th>
            <th class="px-4 py-3 text-center">Aktiv</th>
            <th class="px-4 py-3 text-center">Inventarisiert</th>
            <th class="px-4 py-3 text-center">MHD</th>
            <th class="px-4 py-3 text-center">Aktionen</th>
          </tr>
        </thead>

        <tbody>
          <tr
            v-for="p in sortedProducts"
            :key="p.id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">
              <div class="font-medium text-gray-900">{{ p.name }}</div>
            </td>

            <!-- Preis -->
            <td class="px-4 py-2 text-right">
              {{ formatEuro(p.priceEuro) }}
            </td>

            <!-- Gästepreis -->
            <td class="px-4 py-2 text-right">
              {{ formatEuro(p.guestPriceEuro) }}
            </td>

            <!-- Einkaufspreis -->
            <td class="px-4 py-2 text-right">
              {{ formatEuro(p.lastPurchasePriceEuro) }}
            </td>

            <!-- Kategorie -->
            <td class="px-4 py-2">
              {{ p.category }}
            </td>

            <!-- Bild -->
            <td class="px-4 py-2">
              <img
                v-if="hasPreviewImage(p)"
                :src="p.image_url"
                :alt="`Bild ${p.name}`"
                class="w-12 h-12 object-contain rounded border bg-white"
                @error="onPreviewImageError(p.id)"
              />
              <div
                v-else
                class="w-12 h-12 rounded border bg-gray-100 text-[10px] text-gray-500 flex items-center justify-center text-center leading-tight px-1"
              >
                Kein Bild
              </div>
            </td>

            <!-- Aktiv -->
            <td class="px-4 py-2 text-center">
              <span class="rounded-full px-2 py-1 text-xs" :class="p.active ? 'bg-emerald-100 text-emerald-700' : 'bg-gray-100 text-gray-600'">
                {{ p.active ? "Aktiv" : "Inaktiv" }}
              </span>
            </td>

            <!-- Inventarisiert -->
            <td class="px-4 py-2 text-center">
              <span class="rounded-full px-2 py-1 text-xs" :class="p.inventoried ? 'bg-blue-100 text-blue-700' : 'bg-gray-100 text-gray-600'">
                {{ p.inventoried ? "Ja" : "Nein" }}
              </span>
            </td>
            <!-- MHD -->
            <td class="px-4 py-2 text-center">
              <span class="rounded-full px-2 py-1 text-xs" :class="p.mhdSaleEnabled ? 'bg-amber-100 text-amber-700' : 'bg-gray-100 text-gray-500'">
                {{ p.mhdSaleEnabled ? "Ja" : "Nein" }}
              </span>
            </td>

            <!-- Aktionen -->
            <td class="px-4 py-2 text-center">
              <button
                @click="openProductDetails(p)"
                class="bg-primary text-white px-3 py-1 rounded-md hover:bg-primary/90 text-sm font-medium"
              >
                Bearbeiten
              </button>
            </td>
          </tr>
          <tr v-if="sortedProducts.length === 0">
            <td colspan="10" class="text-center py-6 text-gray-400 italic">
              Keine Artikel für den gewählten Filter
            </td>
          </tr>
        </tbody>
      </table>
      </div>
    </div>

    <div
      v-if="selectedProduct"
      class="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4"
      @click.self="closeProductDetails"
    >
      <div class="bg-white rounded-xl shadow-xl w-full max-w-3xl max-h-[90vh] overflow-y-auto border border-gray-200">
        <div class="flex items-start justify-between gap-4 px-5 py-4 border-b">
          <div class="min-w-0">
            <h3 class="text-lg font-semibold text-gray-900 truncate">{{ selectedProduct.name || "Artikel" }}</h3>
            <div class="mt-1 flex flex-wrap gap-2 text-xs">
              <span class="rounded-full px-2 py-1" :class="selectedProduct.active ? 'bg-emerald-100 text-emerald-700' : 'bg-gray-100 text-gray-600'">
                {{ selectedProduct.active ? "Aktiv" : "Inaktiv" }}
              </span>
              <span class="rounded-full px-2 py-1" :class="selectedProduct.inventoried ? 'bg-blue-100 text-blue-700' : 'bg-gray-100 text-gray-600'">
                {{ selectedProduct.inventoried ? "Inventarisiert" : "Nicht inventarisiert" }}
              </span>
              <span v-if="selectedProduct.mhdSaleEnabled" class="rounded-full bg-amber-100 px-2 py-1 text-amber-700">MHD</span>
            </div>
          </div>
          <button
            class="text-gray-500 hover:text-gray-800 text-xl leading-none"
            @click="closeProductDetails"
            aria-label="Schließen"
          >
            ×
          </button>
        </div>

        <div class="p-5 space-y-6">
          <section class="space-y-3">
            <h4 class="text-sm font-semibold text-gray-800">Stammdaten</h4>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
              <div class="md:col-span-2">
                <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Name</label>
                <input
                  v-model="selectedProduct.name"
                  class="w-full border rounded-md px-3 py-2 text-sm focus:ring-1 focus:ring-primary"
                />
              </div>
              <div>
                <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Preis (€)</label>
                <input
                  v-model.number="selectedProduct.priceEuro"
                  type="number"
                  step="0.01"
                  min="0"
                  class="w-full border rounded-md px-3 py-2 text-sm focus:ring-1 focus:ring-primary"
                />
              </div>
              <div>
                <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Gast (€)</label>
                <input
                  v-model.number="selectedProduct.guestPriceEuro"
                  type="number"
                  step="0.01"
                  min="0"
                  class="w-full border rounded-md px-3 py-2 text-sm focus:ring-1 focus:ring-primary"
                />
              </div>
              <div>
                <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">EK (€)</label>
                <input
                  v-model.number="selectedProduct.lastPurchasePriceEuro"
                  type="number"
                  step="0.01"
                  min="0"
                  class="w-full border rounded-md px-3 py-2 text-sm focus:ring-1 focus:ring-primary"
                />
              </div>
              <div>
                <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Kategorie</label>
                <select
                  v-model="selectedProduct.category"
                  class="w-full border rounded-md px-3 py-2 text-sm focus:ring-1 focus:ring-primary"
                >
                  <option v-for="c in productCategoryOptions" :key="c.id" :value="c.name">
                    {{ c.name }}
                  </option>
                </select>
              </div>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label class="inline-flex items-center gap-2 text-sm text-gray-700">
                <input
                  type="checkbox"
                  v-model="selectedProduct.active"
                  class="scale-125 accent-primary"
                />
                Artikel ist aktiv
              </label>
              <label class="inline-flex items-center gap-2 text-sm text-gray-700">
                <input
                  type="checkbox"
                  v-model="selectedProduct.inventoried"
                  class="scale-125 accent-primary"
                />
                Artikel wird inventarisiert
              </label>
              <label class="inline-flex items-center gap-2 text-sm text-gray-700">
                <input
                  type="checkbox"
                  v-model="selectedProduct.mhdSaleEnabled"
                  class="scale-125 accent-primary"
                />
                Im MHD-Modal anbieten
              </label>
            </div>
          </section>

          <section class="space-y-3">
            <h4 class="text-sm font-semibold text-gray-800">Bild</h4>
            <div class="flex items-center gap-4">
              <img
                v-if="hasPreviewImage(selectedProduct)"
                :src="selectedProduct.image_url"
                :alt="`Bild ${selectedProduct.name}`"
                class="w-20 h-20 object-contain rounded border bg-white"
                @error="onPreviewImageError(selectedProduct.id)"
              />
              <div
                v-else
                class="w-20 h-20 rounded border bg-gray-100 text-xs text-gray-500 flex items-center justify-center text-center leading-tight px-2"
              >
                Kein Bild
              </div>
              <div class="space-y-2">
                <input
                  type="file"
                  accept="image/png,image/jpeg,image/webp,image/gif,image/svg+xml"
                  :disabled="isUploading(selectedProduct.id)"
                  class="text-xs w-full"
                  @change="onProductImageSelected(selectedProduct, $event)"
                />
                <button
                  v-if="selectedProduct.image_url"
                  @click="removeProductImage(selectedProduct)"
                  :disabled="isUploading(selectedProduct.id)"
                  class="text-xs text-red-700 hover:text-red-900 text-left disabled:opacity-50"
                >
                  Bild entfernen
                </button>
                <div v-if="isUploading(selectedProduct.id)" class="text-xs text-gray-500">
                  Upload läuft...
                </div>
              </div>
            </div>
          </section>

          <section class="border-t pt-4 flex flex-col sm:flex-row justify-between gap-3">
            <button
              @click="deleteProduct(selectedProduct)"
              class="bg-red-100 text-red-700 px-4 py-2 rounded-md hover:bg-red-200 text-sm font-medium"
            >
              Artikel löschen
            </button>
            <div class="flex justify-end gap-2">
              <button
                @click="closeProductDetails"
                class="bg-gray-100 text-gray-700 px-4 py-2 rounded-md hover:bg-gray-200 text-sm font-medium"
              >
                Abbrechen
              </button>
              <button
                @click="saveSelectedProduct"
                :disabled="productDetailSaving"
                class="bg-primary text-white px-4 py-2 rounded-md hover:bg-primary/90 text-sm font-medium disabled:opacity-60"
              >
                {{ productDetailSaving ? "Speichern..." : "Speichern" }}
              </button>
            </div>
          </section>
        </div>
      </div>
    </div>

    <!-- Modal -->
    <BaseModal
      :show="showNewProductModal"
      title="Neuen Artikel anlegen"
      @close="showNewProductModal = false"
      @confirm="confirmAddProduct"
    >
      <div class="space-y-3">
        <label class="block text-sm text-gray-600">Name</label>
        <input
          v-model="newProductName"
          class="w-full border rounded-md p-2 text-sm"
        />

        <label class="block text-sm text-gray-600">Preis (€)</label>
        <input
          v-model.number="newProductPrice"
          type="number"
          step="0.01"
          class="w-full border rounded-md p-2 text-sm"
        />

        <label class="block text-sm text-gray-600">Gast (€)</label>
        <input
          v-model.number="newGuestPrice"
          type="number"
          step="0.01"
          class="w-full border rounded-md p-2 text-sm"
        />

        <label class="block text-sm text-gray-600">EK (€)</label>
        <input
          v-model.number="newLastPurchasePrice"
          type="number"
          step="0.01"
          min="0"
          class="w-full border rounded-md p-2 text-sm"
        />

        <label class="block text-sm text-gray-600">Kategorie</label>
        <select
          v-model="newProductCategory"
          class="w-full border rounded-md p-2 text-sm"
        >
          <option v-for="c in activeCategoryOptions" :key="c.id" :value="c.name">
            {{ c.name }}
          </option>
        </select>

        <label class="flex items-center gap-2 text-sm text-gray-600 mt-3">
          <input
            type="checkbox"
            v-model="newProductInventoried"
            class="scale-125 accent-primary"
          />
          <span>Produkt wird inventarisiert</span>
        </label>
        <label class="flex items-center gap-2 text-sm text-gray-600 mt-3">
          <input
            type="checkbox"
            v-model="newProductMhdSaleEnabled"
            class="scale-125 accent-primary"
          />
          <span>Im MHD-Modal anbieten</span>
        </label>
      </div>
    </BaseModal>
  </div>
</template>
