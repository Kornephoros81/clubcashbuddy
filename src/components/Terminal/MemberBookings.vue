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
      class="fixed right-0 top-0 h-full w-full max-w-md bg-white shadow-2xl z-50 flex flex-col"
    >
      <!-- Header -->
      <div class="p-4 border-b flex justify-between items-center">
        <h3 class="text-lg font-semibold text-primary">📅 Buchungsübersicht</h3>
        <button
          @click="onClose?.()"
          class="text-gray-500 hover:text-gray-800 text-xl leading-none"
        >
          ×
        </button>
      </div>

      <!-- Steuerleiste -->
      <div class="flex items-center justify-between p-4 border-b bg-gray-50">
        <button @click="changePeriod(-1)" class="text-primary text-xl">‹</button>

        <div class="text-center">
          <div class="font-medium text-lg flex flex-col items-center">
            <span>{{ formatDateLabel() }}</span>

            <!-- Gesamtsumme oben -->
            <span
              v-if="!loading && bookings.length > 0"
              :class="totalSum < 0 ? 'text-red-600' : 'text-green-600'"
              class="text-sm font-semibold"
            >
              {{ (totalSum / 100).toFixed(2) }} €
            </span>
          </div>

          <select
            v-model="viewMode"
            class="mt-2 border rounded px-2 py-1 text-sm bg-white"
          >
          <option value="month">Monat</option>
            <option value="day">Tag</option>
            
          </select>
        </div>

        <button @click="changePeriod(1)" class="text-primary text-xl">›</button>
      </div>

      <!-- Inhalt -->
      <div class="flex-1 overflow-y-auto p-4">
        <div v-if="loading" class="text-center text-gray-400 py-8">
          Lade Buchungen …
        </div>

        <!-- Monatsansicht (gruppiert von Server) -->
        <template v-else-if="viewMode === 'month'">
          <div
            v-for="g in bookings"
            :key="g.local_day"
            class="mb-6 border-b border-gray-100 pb-3"
          >
            <div class="flex justify-between items-center mb-2">
              <h4 class="text-sm font-semibold text-gray-600">
                {{
                  new Date(g.local_day).toLocaleDateString("de-DE", {
                    weekday: "short",
                    day: "2-digit",
                    month: "short",
                  })
                }}
              </h4>
              <span
                class="text-sm font-semibold"
                :class="g.total < 0 ? 'text-red-500' : 'text-green-600'"
              >
                {{ (g.total / 100).toFixed(2) }} €
              </span>
            </div>

            <ul class="divide-y divide-gray-100">
              <li
                v-for="b in g.items"
                :key="b.id"
                class="py-2 flex justify-between items-center"
              >
                <div>
                  <p class="font-medium">
                    {{ b.product_name || b.note || "Freier Betrag" }}
                  </p>
                  <p class="text-xs text-gray-400">
                    {{
                      new Date(b.created_at).toLocaleTimeString("de-DE", {
                        hour: "2-digit",
                        minute: "2-digit",
                      })
                    }}
                  </p>
                </div>
                <span
                  class="font-semibold"
                  :class="b.amount < 0 ? 'text-red-500' : 'text-green-600'"
                >
                  {{ (b.amount / 100).toFixed(2) }} €
                </span>
              </li>
            </ul>
          </div>

          <!-- Monats-Gesamtsumme -->
          <div
            v-if="bookings.length > 0"
            class="text-right text-base font-semibold mt-6 border-t pt-3"
            :class="totalSum < 0 ? 'text-red-600' : 'text-green-600'"
          >
            Gesamt: {{ (totalSum / 100).toFixed(2) }} €
          </div>
        </template>

        <!-- Tagesansicht (flach) -->
        <template v-else>
          <ul class="divide-y divide-gray-200">
            <li
              v-for="b in bookings"
              :key="b.id"
              class="py-2 flex justify-between items-center"
            >
              <div>
                <p class="font-medium">
                  {{ b.products?.name || b.product_name || b.note || "Freier Betrag" }}
                </p>
                <p class="text-xs text-gray-400">
                  {{
                    new Date(b.created_at).toLocaleTimeString("de-DE", {
                      hour: "2-digit",
                      minute: "2-digit",
                    })
                  }}
                </p>
              </div>
              <span
                class="font-semibold"
                :class="b.amount < 0 ? 'text-red-500' : 'text-green-600'"
              >
                {{ (b.amount / 100).toFixed(2) }} €
              </span>
            </li>
          </ul>

          <div
            v-if="bookings.length > 0"
            class="text-right text-base font-semibold mt-4 border-t pt-3"
            :class="totalSum < 0 ? 'text-red-600' : 'text-green-600'"
          >
            Gesamt: {{ (totalSum / 100).toFixed(2) }} €
          </div>
        </template>

        <div
          v-if="!loading && bookings.length === 0"
          class="text-center text-gray-400 py-8"
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
