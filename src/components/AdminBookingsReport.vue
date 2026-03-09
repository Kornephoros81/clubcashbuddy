<script setup lang="ts">
import { ref, computed, onMounted, watch } from "vue";
import { useRoute } from "vue-router";
import { useToast } from "@/composables/useToast";
import Datepicker from "@vuepic/vue-datepicker";
import BaseModal from "@/components/BaseModal.vue";
import "@vuepic/vue-datepicker/dist/main.css";
import { adminRpc } from "@/lib/adminApi";
import { exportReportAsPdf } from "@/utils/reportExport";

type BookingItem = {
  id: string;
  member_id: string;
  member_name: string;
  member_active: boolean;
  device_name: string;
  product_id: string | null;
  product_name: string;
  transaction_type:
    | "sale_product"
    | "sale_free_amount"
    | "cash_withdrawal"
    | "credit_adjustment";
  created_at: string;
  settled_at: string | null;
  amount: number;
  note: string | null;
};

type SortKey = "member_name" | "product_name" | "created_at";

type GroupedReportRow = {
  member_id: string;
  member_name: string;
  member_active: boolean;
  items: Array<{
    id: string;
    amount: number;
    note: string | null;
    created_at: string;
    settled_at: string | null;
    product_id: string | null;
    product_name: string | null;
    device_name?: string | null;
    transaction_type?:
      | "sale_product"
      | "sale_free_amount"
      | "cash_withdrawal"
      | "credit_adjustment"
      | null;
  }>;
};

const { show: showToast } = useToast();
const route = useRoute();

const loading = ref(false);
const cancelling = ref(false);
const error = ref<string | null>(null);
const bookings = ref<BookingItem[]>([]);

const selectedMemberId = ref<string>("");
const selectedProductId = ref<string>("");
const selectedTransactionType = ref<string>("");
const sortKey = ref<SortKey>("created_at");
const sortDirection = ref<"asc" | "desc">("desc");

const bookingToCancel = ref<BookingItem | null>(null);
const showCancelModal = ref(false);

const today = new Date();
const sevenDaysAgo = new Date();
sevenDaysAgo.setDate(today.getDate() - 7);
const startDate = ref<Date>(sevenDaysAgo);
const endDate = ref<Date>(today);
const suppressDateReload = ref(false);

function getLocalDayRange(date: Date, isEnd = false) {
  const d = new Date(date);
  if (!isEnd) d.setHours(0, 0, 0, 0);
  else d.setHours(23, 59, 59, 999);
  return d.toISOString();
}

function queryValue(v: unknown): string | null {
  if (Array.isArray(v)) return v[0] ? String(v[0]) : null;
  if (typeof v === "string" && v.trim()) return v;
  return null;
}

function applyQueryFilters() {
  const qStart = queryValue(route.query.start);
  const qEnd = queryValue(route.query.end);
  const qMember = queryValue(route.query.member_id);
  const qProduct = queryValue(route.query.product_id);
  const qType = queryValue(route.query.transaction_type);

  if (qStart) {
    const d = new Date(qStart);
    if (!Number.isNaN(d.getTime())) startDate.value = d;
  }
  if (qEnd) {
    const d = new Date(qEnd);
    if (!Number.isNaN(d.getTime())) endDate.value = d;
  }
  if (qMember) selectedMemberId.value = qMember;
  if (qProduct) selectedProductId.value = qProduct;
  if (qType) selectedTransactionType.value = qType;
}

const transactionTypeOptions = [
  { value: "", label: "Alle Typen" },
  { value: "sale_product", label: "Produktverkauf" },
  { value: "sale_free_amount", label: "Freier Verkauf" },
  { value: "cash_withdrawal", label: "Bar-Entnahme" },
  { value: "credit_adjustment", label: "Guthabenbuchung" },
];

function transactionTypeLabel(v: BookingItem["transaction_type"]) {
  if (v === "cash_withdrawal") return "Bar-Entnahme";
  if (v === "credit_adjustment") return "Guthabenbuchung";
  if (v === "sale_free_amount") return "Freier Verkauf";
  return "Produktverkauf";
}

const memberOptions = computed(() => {
  const map = new Map<string, string>();
  for (const b of bookings.value) {
    if (!map.has(b.member_id)) map.set(b.member_id, b.member_name);
  }
  return Array.from(map.entries())
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name, "de"));
});

const productOptions = computed(() => {
  const map = new Map<string, string>();
  for (const b of bookings.value) {
    if (!b.product_id) continue;
    if (!map.has(b.product_id)) map.set(b.product_id, b.product_name);
  }
  return Array.from(map.entries())
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name, "de"));
});

const filteredBookings = computed(() => {
  return bookings.value.filter((b) => {
    const matchesMember =
      !selectedMemberId.value || b.member_id === selectedMemberId.value;
    const matchesProduct =
      !selectedProductId.value || b.product_id === selectedProductId.value;
    const matchesType =
      !selectedTransactionType.value || b.transaction_type === selectedTransactionType.value;
    return matchesMember && matchesProduct && matchesType;
  });
});

const sortedBookings = computed(() => {
  const result = [...filteredBookings.value];
  const direction = sortDirection.value === "asc" ? 1 : -1;

  result.sort((a, b) => {
    if (sortKey.value === "created_at") {
      return (
        (new Date(a.created_at).getTime() - new Date(b.created_at).getTime()) *
        direction
      );
    }

    const valueA = a[sortKey.value];
    const valueB = b[sortKey.value];
    return valueA.localeCompare(valueB, "de") * direction;
  });

  return result;
});

const bookingsTotalAmountEuro = computed(
  () => sortedBookings.value.reduce((sum, booking) => sum + Number(booking.amount ?? 0), 0) / 100,
);

function toggleSort(key: SortKey) {
  if (sortKey.value === key) {
    sortDirection.value = sortDirection.value === "asc" ? "desc" : "asc";
    return;
  }

  sortKey.value = key;
  sortDirection.value = key === "created_at" ? "desc" : "asc";
}

function sortIndicator(key: SortKey) {
  if (sortKey.value !== key) return "↕";
  return sortDirection.value === "asc" ? "▲" : "▼";
}

async function loadBookings() {
  if (!startDate.value || !endDate.value) {
    showToast("⚠️ Bitte Start- und Enddatum auswählen");
    return;
  }

  loading.value = true;
  error.value = null;
  bookings.value = [];

  try {
    const data = await adminRpc("get_all_bookings_grouped", {
      start: getLocalDayRange(startDate.value, false),
      end: getLocalDayRange(endDate.value, true),
    });
    const rows = ((data as any[]) ?? []) as GroupedReportRow[];
    const flattened: BookingItem[] = [];

    for (const row of rows) {
      const items = Array.isArray(row.items) ? row.items : [];
      for (const item of items) {
        flattened.push({
          id: item.id,
          member_id: row.member_id,
          member_name: row.member_name,
          member_active: !!row.member_active,
          device_name: item.device_name || "-",
          product_id: item.product_id,
          product_name: item.product_name || item.note || "Freier Betrag",
          transaction_type:
            item.transaction_type
            ?? (Number(item.amount ?? 0) > 0
              ? "credit_adjustment"
              : item.product_id
                ? "sale_product"
                : "sale_free_amount"),
          created_at: item.created_at,
          settled_at: item.settled_at,
          amount: item.amount,
          note: item.note,
        });
      }
    }

    bookings.value = flattened.sort(
      (a, b) =>
        new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
    );
  } catch (err) {
    console.error("[AdminBookingsReport]", err);
    error.value = "Fehler beim Laden der Buchungen";
    showToast("⚠️ Fehler beim Laden der Buchungen");
  } finally {
    loading.value = false;
  }
}

function askCancel(booking: BookingItem) {
  if (booking.settled_at) {
    showToast("⚠️ Bereits abgerechnete Buchungen können nicht storniert werden");
    return;
  }
  if (!booking.member_active) {
    showToast("⚠️ Buchungen von inaktiven Mitgliedern können nicht storniert werden");
    return;
  }
  bookingToCancel.value = booking;
  showCancelModal.value = true;
}

async function confirmCancel() {
  const booking = bookingToCancel.value;
  if (!booking) return;

  showCancelModal.value = false;
  cancelling.value = true;

  try {
    await adminRpc("cancel_transaction", {
      cancel_tx_id: booking.id,
      member_id: booking.member_id,
      product_id: booking.product_id,
      note: booking.note,
    });

    showToast("✅ Buchung wurde storniert");
    await loadBookings();
  } catch (err) {
    console.error("[AdminBookingsReport.cancel]", err);
    showToast("⚠️ Storno fehlgeschlagen");
  } finally {
    cancelling.value = false;
    bookingToCancel.value = null;
  }
}

onMounted(async () => {
  suppressDateReload.value = true;
  applyQueryFilters();
  suppressDateReload.value = false;
  await loadBookings();
});

watch([startDate, endDate], async () => {
  if (suppressDateReload.value) return;
  if (!startDate.value || !endDate.value) return;
  await loadBookings();
});

async function exportPdf() {
  try {
    await exportReportAsPdf("admin-bookings-report", "Buchungsuebersicht");
  } catch (err) {
    console.error("[AdminBookingsReport.exportPdf]", err);
    showToast("⚠️ PDF-Export fehlgeschlagen");
  }
}
</script>

<template>
  <div class="space-y-6" data-report-id="admin-bookings-report">
    <div class="flex flex-col lg:flex-row justify-between items-start lg:items-center gap-3">
      <h2 class="text-xl font-semibold text-primary">🧾 Buchungsübersicht</h2>
      <div class="flex flex-col sm:flex-row items-stretch sm:items-center gap-3 no-print w-full lg:w-auto">
        <button
          @click="exportPdf"
          class="text-sm px-3 py-2 rounded-lg border border-gray-300 text-gray-700 hover:bg-gray-50 transition"
        >
          Drucken
        </button>
        <RouterLink
          to="/admin/dashboard"
          class="text-sm text-gray-500 hover:text-primary underline py-2"
        >
          ← Zurück zum Dashboard
        </RouterLink>
      </div>
    </div>

    <div
      class="bg-white rounded-2xl shadow border border-gray-200 p-4 grid grid-cols-1 md:grid-cols-2 xl:grid-cols-5 gap-4 items-end"
    >
      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">
          Startdatum
        </label>
        <Datepicker
          v-model="startDate"
          :enable-time-picker="false"
          :format="'dd.MM.yyyy'"
          :auto-apply="true"
          :close-on-auto-apply="true"
          :config="{ keepActionRow: true }"
          :action-row="{ showNow: true, nowBtnLabel: 'Heute', showSelect: false, showCancel: false }"
        />
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">
          Enddatum
        </label>
        <Datepicker
          v-model="endDate"
          :enable-time-picker="false"
          :format="'dd.MM.yyyy'"
          :auto-apply="true"
          :close-on-auto-apply="true"
          :config="{ keepActionRow: true }"
          :action-row="{ showNow: true, nowBtnLabel: 'Heute', showSelect: false, showCancel: false }"
        />
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">
          Mitglied
        </label>
        <select
          v-model="selectedMemberId"
          class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"
        >
          <option value="">Alle Mitglieder</option>
          <option v-for="member in memberOptions" :key="member.id" :value="member.id">
            {{ member.name }}
          </option>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">
          Produkt
        </label>
        <select
          v-model="selectedProductId"
          class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"
        >
          <option value="">Alle Produkte</option>
          <option v-for="product in productOptions" :key="product.id" :value="product.id">
            {{ product.name }}
          </option>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">
          Typ
        </label>
        <select
          v-model="selectedTransactionType"
          class="h-[38px] min-w-[220px] rounded-md border border-gray-300 px-3"
        >
          <option v-for="opt in transactionTypeOptions" :key="opt.value || 'all'" :value="opt.value">
            {{ opt.label }}
          </option>
        </select>
      </div>

      <div class="xl:self-end">
        <button
          @click="loadBookings"
          class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition w-full"
          :disabled="loading || cancelling"
        >
          Aktualisieren
        </button>
      </div>
    </div>

    <div v-if="loading" class="text-center py-10 text-gray-500">
      ⏳ Buchungen werden geladen...
    </div>
    <div v-else-if="error" class="text-center py-10 text-red-500">
      {{ error }}
    </div>

    <div v-else class="space-y-4">
      <div class="lg:hidden space-y-3">
        <div
          v-for="booking in sortedBookings"
          :key="booking.id"
          class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <div class="text-base font-semibold text-gray-900">{{ booking.member_name }}</div>
              <div class="text-sm text-gray-500 mt-1">{{ booking.product_name }}</div>
            </div>
            <div class="text-right">
              <div class="text-sm font-semibold" :class="booking.amount < 0 ? 'text-red-700' : 'text-emerald-700'">
                {{ (booking.amount / 100).toFixed(2) }} €
              </div>
              <div class="text-xs text-gray-500 mt-1">{{ transactionTypeLabel(booking.transaction_type) }}</div>
            </div>
          </div>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 text-sm text-gray-600">
            <div>Device: {{ booking.device_name }}</div>
            <div>
              {{
                new Date(booking.created_at).toLocaleString("de-DE", {
                  day: "2-digit",
                  month: "2-digit",
                  year: "numeric",
                  hour: "2-digit",
                  minute: "2-digit",
                })
              }}
            </div>
          </div>
          <button
            @click="askCancel(booking)"
            class="w-full px-3 py-2 rounded-md transition text-sm font-medium"
            :class="
              booking.settled_at || !booking.member_active
                ? 'bg-gray-300 text-gray-600 cursor-not-allowed'
                : 'bg-red-600 text-white hover:bg-red-700'
            "
            :disabled="cancelling || !!booking.settled_at || !booking.member_active"
          >
            Stornieren
          </button>
        </div>
        <div v-if="sortedBookings.length === 0" class="bg-white rounded-2xl shadow border border-gray-200 p-6 text-center text-gray-400 italic">
          Keine Buchungen für den gewählten Filter
        </div>
      </div>

      <div
        class="hidden lg:block bg-white rounded-2xl shadow overflow-x-auto border border-gray-200"
      >
      <table class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">
              <button
                type="button"
                class="inline-flex items-center gap-1 hover:underline"
                @click="toggleSort('member_name')"
              >
                Mitglied <span>{{ sortIndicator("member_name") }}</span>
              </button>
            </th>
            <th class="px-4 py-3 text-left">
              <button
                type="button"
                class="inline-flex items-center gap-1 hover:underline"
                @click="toggleSort('product_name')"
              >
                Produkt <span>{{ sortIndicator("product_name") }}</span>
              </button>
            </th>
            <th class="px-4 py-3 text-left">Typ</th>
            <th class="px-4 py-3 text-left">Device</th>
            <th class="px-4 py-3 text-left">
              <button
                type="button"
                class="inline-flex items-center gap-1 hover:underline"
                @click="toggleSort('created_at')"
              >
                Zeitstempel <span>{{ sortIndicator("created_at") }}</span>
              </button>
            </th>
            <th class="px-4 py-3 text-right">Betrag (€)</th>
            <th class="px-4 py-3 text-right">Aktion</th>
          </tr>
        </thead>
        <tbody>
          <template v-if="sortedBookings.length">
            <tr
              v-for="booking in sortedBookings"
              :key="booking.id"
              class="border-t hover:bg-primary/5 transition"
            >
              <td class="px-4 py-2">{{ booking.member_name }}</td>
              <td class="px-4 py-2">{{ booking.product_name }}</td>
              <td class="px-4 py-2">{{ transactionTypeLabel(booking.transaction_type) }}</td>
              <td class="px-4 py-2">{{ booking.device_name }}</td>
              <td class="px-4 py-2">
                {{
                  new Date(booking.created_at).toLocaleString("de-DE", {
                    day: "2-digit",
                    month: "2-digit",
                    year: "numeric",
                    hour: "2-digit",
                    minute: "2-digit",
                  })
                }}
              </td>
              <td class="px-4 py-2 text-right">
                {{ (booking.amount / 100).toFixed(2) }}
              </td>
              <td class="px-4 py-2 text-right">
                <button
                  @click="askCancel(booking)"
                  class="px-3 py-1 rounded-md transition"
                  :class="
                    booking.settled_at || !booking.member_active
                      ? 'bg-gray-300 text-gray-600 cursor-not-allowed'
                      : 'bg-red-600 text-white hover:bg-red-700'
                  "
                  :disabled="cancelling || !!booking.settled_at || !booking.member_active"
                >
                  Stornieren
                </button>
              </td>
            </tr>
          </template>
          <tr v-else>
            <td colspan="7" class="text-center py-6 text-gray-400 italic">
              Keine Buchungen für den gewählten Filter
            </td>
          </tr>
        </tbody>
        <tfoot v-if="sortedBookings.length" class="bg-gray-50 border-t-2 border-gray-300">
          <tr class="font-semibold">
            <td class="px-4 py-3" colspan="5">Gesamt ({{ sortedBookings.length }} Buchungen)</td>
            <td
              class="px-4 py-3 text-right"
              :class="bookingsTotalAmountEuro < 0 ? 'text-red-700' : bookingsTotalAmountEuro > 0 ? 'text-emerald-700' : 'text-gray-700'"
            >
              {{ bookingsTotalAmountEuro.toFixed(2) }}
            </td>
            <td class="px-4 py-3 text-right">-</td>
          </tr>
        </tfoot>
      </table>
      </div>
    </div>

    <BaseModal
      :show="showCancelModal"
      title="Buchung stornieren"
      confirm-label="Stornieren"
      cancel-label="Abbrechen"
      :danger="true"
      @close="showCancelModal = false"
      @confirm="confirmCancel"
    >
      <p v-if="bookingToCancel">
        Buchung für <strong>{{ bookingToCancel.member_name }}</strong> mit
        <strong>{{ bookingToCancel.product_name }}</strong> wirklich stornieren?
      </p>
    </BaseModal>
  </div>
</template>

<style scoped>
table {
  border-collapse: collapse;
}
</style>
