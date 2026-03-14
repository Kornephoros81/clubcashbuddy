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

function setViewMode(mode: "day" | "month") {
  viewMode.value = mode;
}

onMounted(loadBookings);
watch([currentDate, viewMode], loadBookings);
</script>

<template>
  <transition name="slide">
    <aside
      class="glass-panel-strong fixed right-0 top-0 h-full w-full max-w-[28rem] xl:max-w-[26rem] 2xl:max-w-[30rem] z-50 flex flex-col rounded-l-[30px] overflow-hidden"
    >
      <!-- Header -->
      <div class="p-4 border-b border-slate-300 flex justify-between items-center bg-white/85">
        <div>
          <div class="section-chip mb-2">Historie</div>
          <h3 class="display-brand text-xl font-semibold text-primary">Buchungsübersicht</h3>
        </div>
        <button
          @click="onClose?.()"
          class="button-outline-strong flex h-11 w-11 items-center justify-center rounded-full border-slate-300 bg-white text-slate-500 hover:text-slate-800 text-xl leading-none"
        >
          ×
        </button>
      </div>

      <!-- Steuerleiste -->
      <div class="flex items-center justify-between gap-3 p-4 border-b border-slate-300 bg-slate-50/85">
        <button @click="changePeriod(-1)" class="button-outline-strong flex h-11 w-11 items-center justify-center rounded-full border-slate-300 bg-white text-primary text-xl">‹</button>

        <div class="text-center min-w-0">
          <div class="font-medium text-lg flex flex-col items-center">
            <span>{{ formatDateLabel() }}</span>

            <!-- Gesamtsumme oben -->
            <span
              v-if="!loading && bookings.length > 0"
              :class="totalSum < 0 ? 'text-red-600' : 'text-green-600'"
              class="mt-1 rounded-full px-3 py-1 text-sm font-semibold"
              :style="{
                backgroundColor: totalSum < 0 ? 'var(--danger-soft)' : 'var(--success-soft)',
              }"
            >
              {{ (totalSum / 100).toFixed(2) }} €
            </span>
          </div>

          <div class="mt-3 inline-flex rounded-full border border-slate-300 bg-white p-1 shadow-sm">
            <button
              @click="setViewMode('day')"
              class="rounded-full px-4 py-1.5 text-sm font-medium transition"
              :class="
                viewMode === 'day'
                  ? 'bg-primary text-white'
                  : 'text-slate-700 hover:bg-slate-100'
              "
            >
              Tag
            </button>
            <button
              @click="setViewMode('month')"
              class="rounded-full px-4 py-1.5 text-sm font-medium transition"
              :class="
                viewMode === 'month'
                  ? 'bg-primary text-white'
                  : 'text-slate-700 hover:bg-slate-100'
              "
            >
              Monat
            </button>
          </div>
        </div>

        <button @click="changePeriod(1)" class="button-outline-strong flex h-11 w-11 items-center justify-center rounded-full border-slate-300 bg-white text-primary text-xl">›</button>
      </div>

      <!-- Inhalt -->
      <div class="soft-scrollbar touch-scroll flex-1 overflow-y-auto overscroll-contain p-4 xl:p-3.5 bg-white/45">
        <div v-if="loading" class="text-center text-slate-400 py-8">
          Lade Buchungen …
        </div>

        <!-- Monatsansicht (gruppiert von Server) -->
        <template v-else-if="viewMode === 'month'">
          <div
            v-for="g in bookings"
            :key="g.local_day"
            class="mb-4 xl:mb-3 rounded-[24px] border border-slate-300 bg-white p-4 xl:p-3.5 shadow-[0_10px_28px_rgba(15,23,42,0.06)]"
          >
            <div class="flex justify-between items-center mb-2">
              <h4 class="text-sm font-semibold text-slate-600">
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
                :class="g.total < 0 ? 'text-red-500' : 'text-green-600'"
                :style="{
                  backgroundColor: g.total < 0 ? 'var(--danger-soft)' : 'var(--success-soft)',
                }"
              >
                {{ (g.total / 100).toFixed(2) }} €
              </span>
            </div>

            <ul class="divide-y divide-slate-200">
              <li
                v-for="b in g.items"
                :key="b.id"
                class="py-2 xl:py-1.5 flex justify-between items-center"
              >
                <div>
                  <p class="font-medium text-slate-800">
                    {{ b.product_name || b.note || "Freier Betrag" }}
                  </p>
                  <p class="text-xs text-slate-400">
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
                  :class="b.amount < 0 ? 'text-red-500' : 'text-green-600'"
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
            class="text-right text-base font-semibold mt-6 border-t border-slate-300 pt-3"
            :class="totalSum < 0 ? 'text-red-600' : 'text-green-600'"
          >
            Gesamt: {{ (totalSum / 100).toFixed(2) }} €
          </div>
        </template>

        <!-- Tagesansicht (flach) -->
        <template v-else>
          <ul class="overflow-hidden rounded-[24px] border border-slate-300 bg-white divide-y divide-slate-200 shadow-[0_10px_28px_rgba(15,23,42,0.06)]">
            <li
              v-for="b in bookings"
              :key="b.id"
              class="px-4 xl:px-3.5 py-3 xl:py-2.5 flex justify-between items-center gap-3"
            >
              <div>
                <p class="font-medium text-slate-800">
                  {{ b.products?.name || b.product_name || b.note || "Freier Betrag" }}
                </p>
                <p class="text-xs text-slate-400">
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
                :class="b.amount < 0 ? 'text-red-500' : 'text-green-600'"
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
            class="text-right text-base font-semibold mt-4 border-t border-slate-300 pt-3"
            :class="totalSum < 0 ? 'text-red-600' : 'text-green-600'"
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
