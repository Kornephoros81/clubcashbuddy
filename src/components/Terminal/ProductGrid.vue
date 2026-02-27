<script setup lang="ts">
import { computed, ref } from "vue";

const props = defineProps<{
  products: any[];
  loading?: boolean;
  isGuest?: boolean;
}>();
const emit = defineEmits<{ (e: "add", product: any): void }>();
const brokenImagesById = ref<Record<string, boolean>>({});

function hasValidImage(product: any) {
  return Boolean(product?.image_url) && !brokenImagesById.value[String(product.id)];
}

function onImageError(productId: string) {
  brokenImagesById.value = {
    ...brokenImagesById.value,
    [String(productId)]: true,
  };
}

function displayPrice(product: any) {
  const cents = props.isGuest
    ? (product?.guest_price ?? product?.price ?? 0)
    : (product?.price ?? 0);
  return (cents / 100).toFixed(2);
}

// Kategorien gruppieren und sortieren
const groupedProducts = computed(() => {
  const groups: Record<string, any[]> = {};
  for (const p of props.products) {
    const cat = p.category || "Allgemein";
    (groups[cat] ||= []).push(p);
  }
  for (const k in groups)
    groups[k].sort((a, b) => a.name.localeCompare(b.name, "de"));
  return Object.entries(groups).sort(([a], [b]) => a.localeCompare(b, "de"));
});
</script>

<template>
  <!-- rechter Innenabstand gegen Scrollbar-Kleben -->
  <div class="flex flex-col h-full overflow-y-auto pr-2">
    <div v-if="groupedProducts.length" class="space-y-4">
      <section
        v-for="[category, items] in groupedProducts"
        :key="category"
        class="mb-1"
      >
        <!-- Kategorie: kompakt, nicht sticky, keine Überdeckung -->
        <div class="w-full flex items-center my-1">
          <div class="flex-1 border-t border-gray-200"></div>
          <div
            class="mx-3 text-[0.7rem] uppercase tracking-wide text-gray-500 font-semibold"
          >
            {{ category }}
          </div>
          <div class="flex-1 border-t border-gray-200"></div>
        </div>

        <!-- Grid für 1280×800: 6 Spalten auf groß, kleine Gaps, flache Buttons -->
        <div
          class="grid grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-1.5 pr-[4px]"
        >
          <button
            v-for="p in items"
            :key="p.id"
            @click="emit('add', p)"
            :disabled="loading || p.stock === 0"
            class="relative flex flex-col rounded-lg border h-[96px] px-1.5 pt-1 pb-5 shadow-sm transition active:scale-[0.98]"
            :class="[
              p.stock === 0
                ? 'bg-gray-100 text-gray-400 border-gray-200 cursor-not-allowed'
                : 'bg-white hover:bg-blue-50 border-gray-200 hover:border-blue-300',
            ]"
          >
            <!-- Fester Medienbereich -->
            <div
              class="flex-1 min-h-0 flex items-center justify-center px-0.5 rounded bg-white"
            >
              <img
                v-if="hasValidImage(p)"
                :src="p.image_url"
                :alt="p.name"
                class="h-full max-h-[58px] w-full object-contain"
                loading="lazy"
                @error="onImageError(p.id)"
              />
              <span
                v-else
                class="block font-semibold leading-tight text-gray-800 text-[clamp(0.84rem,0.9vw+0.3rem,1.08rem)] text-center"
                style="
                  display: -webkit-box;
                  -webkit-line-clamp: 2;
                  -webkit-box-orient: vertical;
                  overflow: hidden;
                  hyphens: auto;
                  word-break: break-word;
                "
              >
                {{ p.name }}
              </span>
            </div>

            <!-- Footer-Zeile: links Name (bei Bild), rechts Preis -->
            <div
              class="absolute left-1.5 right-1.5 bottom-1 flex items-center justify-between gap-2"
            >
              <span
                v-if="hasValidImage(p)"
                class="min-w-0 text-[0.72rem] font-semibold text-gray-700 truncate text-left"
              >
                {{ p.name }}
              </span>
              <span
                class="shrink-0 ml-auto text-[0.72rem] font-semibold text-blue-700"
              >
                {{ displayPrice(p) }} €
              </span>
            </div>
          </button>
        </div>
      </section>
    </div>

    <p v-else class="text-center text-gray-500 italic mt-6">
      Keine Produkte vorhanden.
    </p>
  </div>
</template>

<style scoped>
::-webkit-scrollbar {
  width: 5px;
}
::-webkit-scrollbar-thumb {
  background-color: rgba(0, 0, 0, 0.15);
  border-radius: 3px;
}
</style>
