<script setup lang="ts">
import { ref, onMounted, watch, computed } from "vue";
import { fetchMemberBookingsCached } from "@/utils/memberBookingsCache";

const props = defineProps<{
  memberId: string;
  onClose?: () => void;
}>();

const viewMode = ref<"day" | "month">("day");
const currentDate = ref(new Date());
const bookings = ref<any[]>([]);
const loading = ref(false);

function formatDateLabel() {
  return viewMode.value === "day"
    ? currentDate.value.toLocaleDateString("de-DE", {
        weekday: "short",
        day: "2-digit",
        month: "short",
      })
    : currentDate.value.toLocaleDateString("de-DE", {
        month: "long",
        year: "numeric",
      });
}

function changePeriod(delta: number) {
  const d = new Date(currentDate.value);
  if (viewMode.value === "day") d.setDate(d.getDate() + delta);
  else d.setMonth(d.getMonth() + delta);
  currentDate.value = d;
}

async function loadBookings() {
  loading.value = true;

  const start =
    viewMode.value === "day"
      ? new Date(
          currentDate.value.getFullYear(),
          currentDate.value.getMonth(),
          currentDate.value.getDate()
        )
      : new Date(
          currentDate.value.getFullYear(),
          currentDate.value.getMonth(),
          1
        );

  const end =
    viewMode.value === "day"
      ? new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1)
      : new Date(start.getFullYear(), start.getMonth() + 1, 1);

  try {
    const deviceToken = localStorage.getItem("device_token");
    if (!deviceToken) throw new Error("Kein Geräte-Token gefunden");

    const result = await fetchMemberBookingsCached({
      token: deviceToken,
      memberId: props.memberId,
      start: start.toISOString(),
      end: end.toISOString(),
    });

    // 🔹 Unterschiedliche Struktur je nach Modus
    if (viewMode.value === "day") {
      // Flatten der gruppierten Daten → Einzelbuchungen
      bookings.value = result.flatMap((g: any) => g.items || []);
    } else {
      // Monatsansicht: gruppierte Struktur direkt übernehmen
      bookings.value = result;
    }
  } catch (err) {
    console.error("[loadBookings]", err);
    bookings.value = [];
  } finally {
    loading.value = false;
  }
}

// === Summenberechnung ===
const totalSum = computed(() =>
  viewMode.value === "month"
    ? bookings.value.reduce((sum, g) => sum + (g.total || 0), 0)
    : bookings.value.reduce((sum, tx) => sum + (tx.amount || 0), 0)
);

onMounted(loadBookings);
watch([currentDate, viewMode], loadBookings);
</script>

<template>
  <transition name="slide">
    <aside
      class="glass-panel-strong fixed right-0 top-0 h-full w-full max-w-[28rem] xl:max-w-[26rem] 2xl:max-w-[30rem] z-50 flex flex-col rounded-l-[30px] overflow-hidden"
    >
      <!-- Header -->
      <div class="p-4 border-b border-white/10 flex justify-between items-center bg-white/[0.03]">
        <div>
          <div class="section-chip mb-2">Historie</div>
          <h3 class="display-brand text-xl font-semibold text-cyan-100">Buchungsübersicht</h3>
        </div>
        <button
          @click="onClose?.()"
          class="flex h-11 w-11 items-center justify-center rounded-full border border-white/10 bg-white/[0.04] text-slate-300 hover:text-white text-xl leading-none"
        >
          ×
        </button>
      </div>

      <!-- Steuerleiste -->
      <div class="flex items-center justify-between gap-3 p-4 border-b border-white/10 bg-black/10">
        <button @click="changePeriod(-1)" class="flex h-11 w-11 items-center justify-center rounded-full border border-white/10 bg-white/[0.04] text-cyan-100 text-xl shadow-sm">‹</button>

        <div class="text-center min-w-0">
          <div class="font-medium text-lg flex flex-col items-center text-slate-100">
            <span>{{ formatDateLabel() }}</span>

            <!-- Gesamtsumme oben -->
            <span
              v-if="!loading && bookings.length > 0"
              :class="totalSum < 0 ? 'text-rose-200' : 'text-emerald-100'"
              class="mt-1 rounded-full px-3 py-1 text-sm font-semibold"
              :style="{
                backgroundColor: totalSum < 0 ? 'var(--danger-soft)' : 'var(--success-soft)',
              }"
            >
              {{ (totalSum / 100).toFixed(2) }} €
            </span>
          </div>

          <select
            v-model="viewMode"
            class="mt-3 rounded-full border border-white/10 px-3 py-1.5 text-sm bg-white/[0.04] text-slate-100 font-medium"
          >
            <option value="month">Monat</option>
            <option value="day">Tag</option>
          </select>
        </div>

        <button @click="changePeriod(1)" class="flex h-11 w-11 items-center justify-center rounded-full border border-white/10 bg-white/[0.04] text-cyan-100 text-xl shadow-sm">›</button>
      </div>

      <!-- Inhalt -->
      <div class="soft-scrollbar touch-scroll flex-1 overflow-y-auto overscroll-contain p-4 xl:p-3.5 bg-transparent">
        <div v-if="loading" class="text-center text-slate-400 py-8">
          Lade Buchungen …
        </div>

        <!-- Monatsansicht (gruppiert von Server) -->
        <template v-else-if="viewMode === 'month'">
          <div
            v-for="g in bookings"
            :key="g.local_day"
            class="mb-4 xl:mb-3 rounded-[24px] border border-white/10 bg-white/[0.04] p-4 xl:p-3.5 shadow-[0_10px_28px_rgba(0,0,0,0.22)]"
          >
            <div class="flex justify-between items-center mb-2">
              <h4 class="text-sm font-semibold text-slate-300">
                {{
                  new Date(g.local_day).toLocaleDateString("de-DE", {
                    weekday: "short",
                    day: "2-digit",
                    month: "short",
                  })
                }}
              </h4>
              <span
                class="rounded-full px-3 py-1 text-sm font-semibold"
                :class="g.total < 0 ? 'text-rose-200' : 'text-emerald-100'"
                :style="{
                  backgroundColor: g.total < 0 ? 'var(--danger-soft)' : 'var(--success-soft)',
                }"
              >
                {{ (g.total / 100).toFixed(2) }} €
              </span>
            </div>

            <ul class="divide-y divide-white/6">
              <li
                v-for="b in g.items"
                :key="b.id"
                class="py-2 xl:py-1.5 flex justify-between items-center"
              >
                <div>
                  <p class="font-medium text-slate-100">
                    {{ b.product_name || b.note || "Freier Betrag" }}
                  </p>
                  <p class="text-xs text-slate-500">
                    {{
                      new Date(b.created_at).toLocaleTimeString("de-DE", {
                        hour: "2-digit",
                        minute: "2-digit",
                      })
                    }}
                  </p>
                </div>
                <span
                  class="rounded-full px-2.5 py-1 xl:px-2 xl:py-0.5 text-xs xl:text-[0.68rem] font-semibold"
                  :class="b.amount < 0 ? 'text-rose-200' : 'text-emerald-100'"
                  :style="{
                    backgroundColor: b.amount < 0 ? 'var(--danger-soft)' : 'var(--success-soft)',
                  }"
                >
                  {{ (b.amount / 100).toFixed(2) }} €
                </span>
              </li>
            </ul>
          </div>

          <!-- Monats-Gesamtsumme -->
          <div
            v-if="bookings.length > 0"
            class="text-right text-base font-semibold mt-6 border-t border-white/10 pt-3"
            :class="totalSum < 0 ? 'text-rose-200' : 'text-emerald-100'"
          >
            Gesamt: {{ (totalSum / 100).toFixed(2) }} €
          </div>
        </template>

        <!-- Tagesansicht (flach) -->
        <template v-else>
          <ul class="overflow-hidden rounded-[24px] border border-white/10 bg-white/[0.04] divide-y divide-white/6 shadow-[0_10px_28px_rgba(0,0,0,0.22)]">
            <li
              v-for="b in bookings"
              :key="b.id"
              class="px-4 xl:px-3.5 py-3 xl:py-2.5 flex justify-between items-center gap-3"
            >
              <div>
                <p class="font-medium text-slate-100">
                  {{ b.products?.name || b.product_name || b.note || "Freier Betrag" }}
                </p>
                <p class="text-xs text-slate-500">
                  {{
                    new Date(b.created_at).toLocaleTimeString("de-DE", {
                      hour: "2-digit",
                      minute: "2-digit",
                    })
                  }}
                </p>
              </div>
              <span
                class="rounded-full px-2.5 xl:px-2 py-1 xl:py-0.5 text-xs xl:text-[0.68rem] font-semibold whitespace-nowrap"
                :class="b.amount < 0 ? 'text-rose-200' : 'text-emerald-100'"
                :style="{
                  backgroundColor: b.amount < 0 ? 'var(--danger-soft)' : 'var(--success-soft)',
                }"
              >
                {{ (b.amount / 100).toFixed(2) }} €
              </span>
            </li>
          </ul>

          <div
            v-if="bookings.length > 0"
            class="text-right text-base font-semibold mt-4 border-t border-white/10 pt-3"
            :class="totalSum < 0 ? 'text-rose-200' : 'text-emerald-100'"
          >
            Gesamt: {{ (totalSum / 100).toFixed(2) }} €
          </div>
        </template>

        <div
          v-if="!loading && bookings.length === 0"
          class="text-center text-slate-400 py-8"
        >
          Keine Buchungen im gewählten Zeitraum.
        </div>
      </div>
    </aside>
  </transition>
</template>

<style scoped>
.slide-enter-active,
.slide-leave-active {
  transition: transform 0.3s ease;
}
.slide-enter-from,
.slide-leave-to {
  transform: translateX(100%);
}
</style>
