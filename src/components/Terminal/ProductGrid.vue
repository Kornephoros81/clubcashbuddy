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
  <div class="soft-scrollbar touch-scroll flex flex-col h-full overflow-y-auto pr-2">
    <div v-if="groupedProducts.length" class="space-y-4">
      <section
        v-for="[category, items] in groupedProducts"
        :key="category"
        class="mb-1"
      >
        <!-- Kategorie: kompakt, nicht sticky, keine Überdeckung -->
        <div class="w-full flex items-center my-1.5">
          <div class="flex-1 border-t border-slate-200"></div>
          <div class="section-chip mx-3">
            {{ category }}
          </div>
          <div class="flex-1 border-t border-slate-200"></div>
        </div>

        <!-- Grid für 1280×800: 6 Spalten auf groß, kleine Gaps, flache Buttons -->
        <div
          class="grid grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-2 pr-[4px]"
        >
          <button
            v-for="p in items"
            :key="p.id"
            @click="emit('add', p)"
            :disabled="loading || p.stock === 0"
            class="group relative flex flex-col rounded-[24px] border h-[102px] px-2 pt-2 pb-5 transition active:scale-[0.985] overflow-hidden"
            :class="[
              p.stock === 0
                ? 'bg-slate-100 text-slate-400 border-slate-200 cursor-not-allowed'
                : 'bg-white/96 hover:bg-blue-50 border-slate-200 hover:border-blue-300 shadow-[0_10px_24px_rgba(15,23,42,0.06)] hover:shadow-[0_16px_34px_rgba(30,58,138,0.14)]',
            ]"
          >
            <span
              class="absolute inset-x-2 top-2 h-px"
              :class="p.stock === 0 ? 'bg-slate-200' : 'bg-slate-100 group-hover:bg-blue-100'"
            ></span>

            <!-- Fester Medienbereich -->
            <div
              class="flex-1 min-h-0 flex items-center justify-center px-0.5 rounded-2xl bg-transparent"
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
                class="block font-semibold leading-tight text-slate-800 text-[clamp(0.84rem,0.9vw+0.3rem,1.08rem)] text-center"
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
              class="absolute left-2 right-2 bottom-1.5 flex items-center justify-between gap-2"
            >
              <span
                v-if="hasValidImage(p)"
                class="min-w-0 text-[0.72rem] font-semibold text-slate-700 truncate text-left"
              >
                {{ p.name }}
              </span>
              <span
                class="shrink-0 ml-auto rounded-full bg-blue-100 px-2 py-0.5 text-[0.72rem] font-bold text-blue-800"
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
