<script setup lang="ts">
import { computed, ref } from "vue";

const props = defineProps<{
  products: any[];
  loading?: boolean;
  isGuest?: boolean;
}>();
const emit = defineEmits<{ (e: "add", product: any): void }>();
const brokenImagesById = ref<Record<string, boolean>>({});
const activeCategory = ref<string>("all");

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

const categoryChips = computed(() => [
  { id: "all", label: "Alle", count: props.products.length },
  ...groupedProducts.value.map(([category, items]) => ({
    id: category,
    label: category,
    count: items.length,
  })),
]);

const visibleGroups = computed(() =>
  activeCategory.value === "all"
    ? groupedProducts.value
    : groupedProducts.value.filter(([category]) => category === activeCategory.value)
);
</script>

<template>
  <div class="product-grid-shell flex h-full flex-col overflow-y-auto px-4 py-4 md:px-5">
    <div class="mb-5 flex items-end justify-between gap-4 border-b border-white/10 pb-4">
      <div>
        <div class="text-[0.68rem] uppercase tracking-[0.3em] text-cyan-100/55">Katalog</div>
        <div class="product-grid-display mt-2 text-3xl text-white md:text-4xl">Schnellauswahl</div>
      </div>
      <div class="hidden rounded-2xl border border-white/10 bg-white/6 px-4 py-3 text-right md:block">
        <div class="text-[0.68rem] uppercase tracking-[0.22em] text-slate-400">Positionen</div>
        <div class="mt-1 text-2xl font-semibold text-white">{{ products.length }}</div>
      </div>
    </div>

    <div v-if="groupedProducts.length" class="mb-5 flex gap-2 overflow-x-auto pb-2">
      <button
        v-for="chip in categoryChips"
        :key="chip.id"
        @click="activeCategory = chip.id"
        class="category-chip inline-flex items-center gap-2 rounded-full border px-3 py-2 text-sm font-semibold transition"
        :class="
          activeCategory === chip.id
            ? 'border-cyan-300/35 bg-cyan-400/16 text-white'
            : 'border-white/10 bg-white/6 text-slate-300 hover:border-white/20 hover:bg-white/10'
        "
      >
        <span>{{ chip.label }}</span>
        <span class="rounded-full bg-black/15 px-2 py-0.5 text-[0.72rem] text-slate-200/85">
          {{ chip.count }}
        </span>
      </button>
    </div>

    <div v-if="visibleGroups.length" class="space-y-6 pr-2">
      <section
        v-for="([category, items], groupIndex) in visibleGroups"
        :key="category"
        class="space-y-3"
        :style="{ animationDelay: `${groupIndex * 70}ms` }"
      >
        <div class="product-section-head flex items-center gap-4">
          <div class="h-px flex-1 bg-white/10"></div>
          <div
            class="rounded-full border border-white/10 bg-white/6 px-3 py-1 text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-slate-300"
          >
            {{ category }}
          </div>
          <div class="h-px flex-1 bg-white/10"></div>
        </div>

        <div
          class="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5"
        >
          <button
            v-for="(p, itemIndex) in items"
            :key="p.id"
            @click="emit('add', p)"
            :disabled="loading || p.stock === 0"
            class="product-card group relative flex min-h-[168px] flex-col overflow-hidden rounded-[1.6rem] border p-3 text-left transition active:scale-[0.985]"
            :style="{ animationDelay: `${groupIndex * 70 + itemIndex * 22}ms` }"
            :class="[
              p.stock === 0
                ? 'cursor-not-allowed border-white/6 bg-white/4 text-slate-500'
                : 'border-white/10 bg-white/6 text-white hover:border-cyan-300/30 hover:bg-white/10',
            ]"
          >
            <div
              class="flex min-h-[92px] flex-1 items-center justify-center rounded-[1.15rem] border border-white/8 bg-black/10 px-2"
            >
              <img
                v-if="hasValidImage(p)"
                :src="p.image_url"
                :alt="p.name"
                class="h-full max-h-[78px] w-full object-contain transition duration-300 group-hover:scale-[1.04]"
                loading="lazy"
                @error="onImageError(p.id)"
              />
              <span
                v-else
                class="block text-center text-[clamp(0.95rem,0.9vw+0.45rem,1.18rem)] font-semibold leading-tight text-white"
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

            <div class="mt-4 flex items-end justify-between gap-3">
              <div class="min-w-0">
                <div
                  v-if="hasValidImage(p)"
                  class="truncate text-sm font-semibold text-white"
                >
                  {{ p.name }}
                </div>
                <div class="mt-1 text-[0.7rem] uppercase tracking-[0.18em] text-slate-400">
                  {{ props.isGuest ? "Gastpreis" : "Mitglied" }}
                </div>
              </div>
              <span
                class="shrink-0 rounded-full border border-cyan-300/20 bg-cyan-400/12 px-2.5 py-1 text-sm font-semibold text-cyan-100"
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
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.03), transparent 28%),
    rgba(2, 6, 23, 0.12);
}

.product-grid-display {
  font-family: "Georgia", "Times New Roman", serif;
  line-height: 0.95;
  letter-spacing: -0.03em;
}

.product-card {
  box-shadow: 0 22px 70px rgba(15, 23, 42, 0.18);
  backdrop-filter: blur(14px);
  animation: product-card-rise 0.42s ease both;
}

.product-card:hover {
  transform: translateY(-2px);
}

.product-section-head {
  animation: section-fade 0.45s ease both;
}

.category-chip {
  box-shadow: 0 10px 30px rgba(15, 23, 42, 0.12);
}

@keyframes product-card-rise {
  from {
    opacity: 0;
    transform: translateY(16px) scale(0.985);
  }
  to {
    opacity: 1;
    transform: translateY(0) scale(1);
  }
}

@keyframes section-fade {
  from {
    opacity: 0;
    transform: translateY(10px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

::-webkit-scrollbar {
  width: 5px;
}
::-webkit-scrollbar-thumb {
  background-color: rgba(148, 163, 184, 0.35);
  border-radius: 3px;
}
</style>
