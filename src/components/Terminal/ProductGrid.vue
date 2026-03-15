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
  <div class="soft-scrollbar touch-scroll flex flex-col h-full overflow-y-auto overscroll-contain pr-2 xl:pr-1">
    <div v-if="groupedProducts.length" class="space-y-2.5 xl:space-y-2">
      <section
        v-for="[category, items] in groupedProducts"
        :key="category"
        class="mb-0.5"
      >
        <!-- Kategorie: kompakt, nicht sticky, keine Überdeckung -->
        <div class="w-full flex items-center mb-1.5 mt-0.5 xl:mb-1 xl:mt-0">
          <div class="flex-1 border-t border-slate-300"></div>
          <div class="section-chip mx-2.5 py-[0.24rem] xl:py-[0.18rem] text-[0.68rem] xl:text-[0.64rem]">
            {{ category }}
          </div>
          <div class="flex-1 border-t border-slate-300"></div>
        </div>

        <!-- Grid für 1280×800: 6 Spalten auf groß, kleine Gaps, flache Buttons -->
        <div
          class="grid grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-2 xl:gap-1.5 pr-[4px]"
        >
          <button
            v-for="p in items"
            :key="p.id"
            @click="emit('add', p)"
            :disabled="loading || p.stock === 0"
            class="group relative flex flex-col rounded-[24px] border h-[102px] xl:h-[94px] px-2 xl:px-1.5 pt-2 xl:pt-1.5 pb-5 xl:pb-4 transition active:scale-[0.985] overflow-hidden"
            :class="[
              p.stock === 0
                ? 'bg-slate-100 text-slate-400 border-slate-300 cursor-not-allowed'
                : 'bg-white hover:bg-slate-50 border-slate-300 hover:border-blue-400 shadow-[0_10px_24px_rgba(15,23,42,0.06)] hover:shadow-[0_16px_34px_rgba(30,58,138,0.14)]',
            ]"
          >
            <!-- Fester Medienbereich -->
            <div
              class="mx-0.5 mt-0.5 flex-1 min-h-0 flex items-center justify-center px-1.5 rounded-[18px] border"
              :class="
                p.stock === 0
                  ? 'bg-slate-50 border-slate-200'
                  : 'bg-gradient-to-b from-slate-50 to-white border-slate-200 group-hover:border-blue-200'
              "
            >
              <img
                v-if="hasValidImage(p)"
                :src="p.image_url"
                :alt="p.name"
                class="block h-full w-auto max-w-full object-contain"
                loading="lazy"
                @error="onImageError(p.id)"
              />
              <span
                v-else
                class="block font-semibold leading-tight text-slate-800 text-[clamp(0.84rem,0.9vw+0.3rem,1.08rem)] xl:text-[0.92rem] text-center"
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
                class="min-w-0 text-[0.72rem] xl:text-[0.68rem] font-semibold text-slate-700 truncate text-left"
              >
                {{ p.name }}
              </span>
              <span
                class="shrink-0 ml-auto rounded-full bg-blue-600 px-2.5 py-0.5 xl:px-2 xl:py-[0.2rem] text-[0.76rem] xl:text-[0.72rem] font-normal leading-none tracking-tight text-white tabular-nums shadow-sm"
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
