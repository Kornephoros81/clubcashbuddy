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
    <div v-if="groupedProducts.length" class="space-y-4 xl:space-y-3">
      <section
        v-for="[category, items] in groupedProducts"
        :key="category"
        class="mb-1"
      >
        <!-- Kategorie: kompakt, nicht sticky, keine Überdeckung -->
        <div class="w-full flex items-center my-1.5 xl:my-1">
          <div class="flex-1 border-t border-white/10"></div>
          <div class="section-chip mx-3">
            {{ category }}
          </div>
          <div class="flex-1 border-t border-white/10"></div>
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
                ? 'bg-white/[0.03] text-slate-600 border-white/8 cursor-not-allowed'
                : 'bg-white/[0.04] hover:bg-cyan-300/10 border-white/10 hover:border-cyan-300/20 shadow-[0_10px_24px_rgba(0,0,0,0.22)] hover:shadow-[0_18px_40px_rgba(8,145,178,0.16)]',
            ]"
          >
            <span
              class="absolute inset-x-2 top-2 h-px"
              :class="p.stock === 0 ? 'bg-white/8' : 'bg-white/8 group-hover:bg-cyan-300/20'"
            ></span>

            <!-- Fester Medienbereich -->
            <div
              class="flex-1 min-h-0 flex items-center justify-center px-0.5 rounded-2xl bg-transparent"
            >
              <img
                v-if="hasValidImage(p)"
                :src="p.image_url"
                :alt="p.name"
                class="h-full max-h-[58px] xl:max-h-[50px] w-full object-contain"
                loading="lazy"
                @error="onImageError(p.id)"
              />
              <span
                v-else
                class="block font-semibold leading-tight text-slate-100 text-[clamp(0.84rem,0.9vw+0.3rem,1.08rem)] xl:text-[0.92rem] text-center"
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
                class="min-w-0 text-[0.72rem] xl:text-[0.68rem] font-semibold text-slate-200 truncate text-left"
              >
                {{ p.name }}
              </span>
              <span
                class="shrink-0 ml-auto rounded-full bg-cyan-300/14 px-2 py-0.5 xl:px-1.5 text-[0.72rem] xl:text-[0.68rem] font-bold text-cyan-100 ring-1 ring-cyan-300/16"
              >
                {{ displayPrice(p) }} €
              </span>
            </div>
          </button>
        </div>
      </section>
    </div>

    <p v-else class="text-center text-slate-500 italic mt-6">
      Keine Produkte vorhanden.
    </p>
  </div>
</template>
