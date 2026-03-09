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
  <div class="product-grid-shell flex h-full flex-col overflow-y-auto px-3 py-3">
    <div v-if="groupedProducts.length" class="space-y-4 pr-2">
      <section
        v-for="[category, items] in groupedProducts"
        :key="category"
        class="space-y-3"
      >
        <div class="flex items-center gap-3">
          <div class="h-px flex-1 bg-white/10"></div>
          <div
            class="rounded-full border border-white/10 bg-white/6 px-3 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.2em] text-slate-300"
          >
            {{ category }}
          </div>
          <div class="h-px flex-1 bg-white/10"></div>
        </div>

        <div
          class="grid grid-cols-3 gap-2 md:grid-cols-4 lg:grid-cols-6"
        >
          <button
            v-for="p in items"
            :key="p.id"
            @click="emit('add', p)"
            :disabled="loading || p.stock === 0"
            class="product-card group relative flex h-[96px] flex-col overflow-hidden rounded-lg border px-1.5 pt-1 pb-5 text-left transition active:scale-[0.985]"
            :class="[
              p.stock === 0
                ? 'cursor-not-allowed border-white/6 bg-white/4 text-slate-500'
                : 'border-white/10 bg-white/6 text-white hover:border-cyan-300/30 hover:bg-white/10',
            ]"
          >
            <div
              class="flex flex-1 items-center justify-center rounded bg-black/10 px-1"
            >
              <img
                v-if="hasValidImage(p)"
                :src="p.image_url"
                :alt="p.name"
                class="h-full max-h-[58px] w-full object-contain transition duration-300 group-hover:scale-[1.03]"
                loading="lazy"
                @error="onImageError(p.id)"
              />
              <span
                v-else
                class="block text-center text-[clamp(0.84rem,0.9vw+0.3rem,1.08rem)] font-semibold leading-tight text-white"
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

            <div class="absolute bottom-1 left-1.5 right-1.5 flex items-center justify-between gap-2">
              <div
                v-if="hasValidImage(p)"
                class="min-w-0 truncate text-[0.72rem] font-semibold text-slate-200"
              >
                {{ p.name }}
              </div>
              <span
                class="shrink-0 rounded-full border border-cyan-300/20 bg-cyan-400/12 px-2 py-0.5 text-[0.72rem] font-semibold text-cyan-100"
              >
                {{ displayPrice(p) }} €
              </span>
            </div>
          </button>
        </div>
      </section>
    </div>

    <p v-else class="mt-6 rounded-2xl border border-dashed border-white/12 bg-white/4 py-10 text-center italic text-slate-400">
      Keine Produkte vorhanden.
    </p>
  </div>
</template>

<style scoped>
.product-grid-shell {
  background: rgba(2, 6, 23, 0.12);
}

.product-card {
  box-shadow: 0 10px 28px rgba(15, 23, 42, 0.14);
  backdrop-filter: blur(10px);
}

.product-card:hover {
  transform: translateY(-1px);
}

::-webkit-scrollbar {
  width: 5px;
}
::-webkit-scrollbar-thumb {
  background-color: rgba(148, 163, 184, 0.35);
  border-radius: 3px;
}
</style>
