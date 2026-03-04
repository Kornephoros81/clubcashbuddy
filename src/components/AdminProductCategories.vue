<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useAdminProductsStore } from "@/stores/useAdminProductsStore";
import { useToast } from "@/composables/useToast";

const store = useAdminProductsStore();
const { show: showToast } = useToast();
const newCategoryName = ref("");

onMounted(async () => {
  try {
    await store.initCategories();
  } catch (err) {
    console.error("[AdminProductCategories.init]", err);
    showToast("⚠️ Kategorien konnten nicht geladen werden");
  }
});

async function addCategory() {
  const name = newCategoryName.value.trim();
  if (!name) {
    showToast("⚠️ Bitte Kategorienamen angeben");
    return;
  }

  try {
    await store.addCategory(name);
    newCategoryName.value = "";
    showToast("✅ Kategorie angelegt");
  } catch (err) {
    console.error("[addCategory]", err);
    showToast("⚠️ Fehler beim Anlegen der Kategorie");
  }
}

async function saveCategory(c: any) {
  const name = String(c?.name ?? "").trim();
  if (!name) {
    showToast("⚠️ Kategorie darf nicht leer sein");
    return;
  }

  try {
    await store.updateCategory({
      ...c,
      name,
      sort_order: Number(c.sort_order ?? 0),
    });
    showToast("✅ Kategorie gespeichert");
  } catch (err) {
    console.error("[saveCategory]", err);
    showToast("⚠️ Fehler beim Speichern der Kategorie");
  }
}
</script>

<template>
  <div class="space-y-6">
    <div class="flex justify-between items-center">
      <h2 class="text-xl font-semibold text-primary">Kategorienverwaltung</h2>
      <RouterLink
        to="/admin/products"
        class="bg-primary/10 text-primary px-4 py-2 rounded-lg shadow hover:bg-primary/20 transition"
      >
        Zu Artikeln
      </RouterLink>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-3">
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold text-primary">Kategorien</h3>
        <div class="flex items-center gap-2">
          <input
            v-model="newCategoryName"
            placeholder="Neue Kategorie"
            class="border rounded-md px-3 py-1.5 text-sm w-52"
          />
          <button
            @click="addCategory"
            class="bg-primary text-white px-3 py-1.5 rounded-md hover:bg-primary/90 text-sm"
          >
            + Kategorie
          </button>
        </div>
      </div>

      <div class="overflow-x-auto">
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
            <tr>
              <th class="px-3 py-2 text-left">Name</th>
              <th class="px-3 py-2 text-right">Sortierung</th>
              <th class="px-3 py-2 text-center">Aktiv</th>
              <th class="px-3 py-2 text-right">Produkte</th>
              <th class="px-3 py-2 text-center">Aktion</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="c in store.categories" :key="c.id" class="border-t">
              <td class="px-3 py-2">
                <input
                  v-model="c.name"
                  class="w-full border rounded-md px-2 py-1 text-sm focus:ring-1 focus:ring-primary"
                />
              </td>
              <td class="px-3 py-2 text-right">
                <input
                  v-model.number="c.sort_order"
                  type="number"
                  class="w-20 text-right border rounded-md px-2 py-1 text-sm focus:ring-1 focus:ring-primary"
                />
              </td>
              <td class="px-3 py-2 text-center">
                <input
                  type="checkbox"
                  v-model="c.active"
                  class="scale-125 accent-primary"
                />
              </td>
              <td class="px-3 py-2 text-right">{{ c.product_count }}</td>
              <td class="px-3 py-2 text-center">
                <button
                  @click="saveCategory(c)"
                  class="bg-primary/10 text-primary px-3 py-1 rounded-md hover:bg-primary/20 text-sm font-medium"
                >
                  Speichern
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>
