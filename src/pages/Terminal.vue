<script setup lang="ts">
import { ref, watch, onMounted, onUnmounted, provide, nextTick } from "vue";
import { useTerminalLogic } from "@/composables/useTerminalLogic";
import DeviceAuthDialog from "@/components/DeviceAuthDialog.vue";
import MemberPicker from "@/components/Terminal/MemberPicker.vue";
import ProductGrid from "@/components/Terminal/ProductGrid.vue";
import BookingList from "@/components/Terminal/BookingList.vue";
import MemberBookings from "@/components/Terminal/MemberBookings.vue";
import GuestSettlementModal from "@/components/Terminal/GuestSettlementModal.vue";
import GuestPartialSettlementModal from "@/components/Terminal/GuestPartialSettlementModal.vue";
import FreeAmountModal from "@/components/Terminal/FreeAmountModal.vue";
import OfflineStatus from "@/components/Terminal/OfflineStatus.vue";
import BaseModal from "@/components/BaseModal.vue";
import { useBranding } from "@/composables/useBranding";

const terminalLogic = useTerminalLogic();
const {
  auth,
  store,
  selectedMember,
  confirmedBookings,
  queuedBookings,
  totalToday,
  loading,
  toast,
  openMember,
  closeMember,
  addProduct,
  addFree,
  undoBooking,
  showToast,
  loadBookings,
  refreshTerminalSnapshot,
} = terminalLogic;
provide("terminalLogic", terminalLogic);
const { appTitle, logoUrl, loadBrandingPublic, DEFAULT_LOGO_URL } = useBranding();

function onLogoError(event: Event) {
  const target = event.target as HTMLImageElement | null;
  if (target) target.src = DEFAULT_LOGO_URL;
}

// Gast hinzufügen
const showAddGuestModal = ref(false);
const guestFirstname = ref("");
const guestLastname = ref("");

async function addGuest() {
  if (!guestFirstname.value.trim() && !guestLastname.value.trim()) {
    showToast("Bitte Vor- oder Nachname angeben");
    return;
  }
  try {
    const res = await fetch("/api/device-add-guest", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${auth.token}`,
      },
      body: JSON.stringify({
        firstname: guestFirstname.value.trim(),
        lastname: guestLastname.value.trim(),
      }),
    });
    if (auth.handleAuthStatus(res.status)) return;
    if (!res.ok) throw new Error(await res.text());
    const { data } = await res.json();
    const newGuestId = data?.id;

    showToast(`Gast ${data.firstname} ${data.lastname} hinzugefügt`);
    guestFirstname.value = "";
    guestLastname.value = "";
    showAddGuestModal.value = false;

    await refreshTerminalSnapshot();

    if (newGuestId) {
      await openMember(newGuestId);
    }
  } catch (err) {
    console.error("[addGuest]", err);
    showToast("⚠️ Fehler beim Anlegen des Gasts");
  }
}

// Inaktivität
const inactivityTimeout = ref<NodeJS.Timeout | null>(null);
const INACTIVITY_LIMIT_MS = 60000;
function resetInactivityTimer() {
  if (inactivityTimeout.value) clearTimeout(inactivityTimeout.value);
  if (!selectedMember.value) return;
  inactivityTimeout.value = setTimeout(closeMember, INACTIVITY_LIMIT_MS);
}
function setupInactivityTracking() {
  ["click", "touchstart", "keydown"].forEach((ev) =>
    window.addEventListener(ev, resetInactivityTimer)
  );
  resetInactivityTimer();
}
function cleanupInactivityTracking() {
  ["click", "touchstart", "keydown"].forEach((ev) =>
    window.removeEventListener(ev, resetInactivityTimer)
  );
  if (inactivityTimeout.value) clearTimeout(inactivityTimeout.value);
}
watch(selectedMember, (nv) =>
  nv ? setupInactivityTracking() : cleanupInactivityTracking()
);
onUnmounted(() => cleanupInactivityTracking());

onMounted(async () => {
  try {
    await loadBrandingPublic();
  } catch (err) {
    console.error("[Terminal.branding]", err);
  }
});

// Modals/Overlays
const showPartialModal = ref(false);
const showBookings = ref(false);
const showSettleModal = ref(false);
const showFreeAmount = ref(false);

// Gäste abrechnen
async function settleGuest() {
  if (!selectedMember.value?.is_guest) return;
  try {
    const res = await fetch("/api/device-settle-guest", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${auth.token}`,
      },
      body: JSON.stringify({ member_id: selectedMember.value.id }),
    });
    if (auth.handleAuthStatus(res.status)) return;
    if (!res.ok) throw new Error(await res.text());
    showToast("✅ Gast erfolgreich abgerechnet");
    closeMember();
    await refreshTerminalSnapshot();
  } catch {
    showToast("⚠️ Fehler beim Abrechnen des Gastes");
  }
}
async function confirmGuestSettlement() {
  await settleGuest();
  showSettleModal.value = false;
}
async function addFreeAndClose(
  amount: number,
  note: string,
  transactionType: "sale_free_amount" | "cash_withdrawal"
) {
  await addFree(amount, note, transactionType);
  showFreeAmount.value = false;
}

async function onBackToMembers() {
  closeMember();
  await refreshTerminalSnapshot();
}

function reloadPage() {
  if (typeof window !== "undefined" && window.location) {
    window.location.reload();
  }
}

// Mitglieds-PIN (UI-only Schutz)
const showPinModal = ref(false);
const pinInput = ref("");
const pinError = ref("");
const pinInputRef = ref<HTMLInputElement | null>(null);
const pendingMemberId = ref<string | null>(null);
const pinRequiredMap = ref<Record<string, boolean>>({});
const pinChecking = ref(false);

async function handleMemberSelect(memberId: string) {
  pinError.value = "";
  pinInput.value = "";
  pendingMemberId.value = null;

  if (!isOnline.value) {
    await openMember(memberId);
    return;
  }

  const known = pinRequiredMap.value[memberId];
  if (known === false) {
    await openMember(memberId);
    return;
  }

  try {
    const res = await fetch("/api/member-pin-status", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${auth.token}`,
      },
      body: JSON.stringify({ member_id: memberId }),
    });
    if (auth.handleAuthStatus(res.status)) return;
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error || `HTTP ${res.status}`);

    const hasPin = Boolean(body?.has_pin);
    pinRequiredMap.value[memberId] = hasPin;

    if (!hasPin) {
      await openMember(memberId);
      return;
    }

    pendingMemberId.value = memberId;
    showPinModal.value = true;
  } catch (e) {
    console.error("[pin] read failed:", e);
    showToast("⚠️ PIN-Status konnte nicht geladen werden");
    return;
  }
}

async function confirmPin() {
  if (pinChecking.value) return;
  const memberId = pendingMemberId.value;
  if (!memberId) {
    showPinModal.value = false;
    return;
  }

  const entered = pinInput.value.replace(/\D/g, "").slice(0, 4);
  if (entered.length !== 4) {
    return;
  }

  pinChecking.value = true;
  try {
    const res = await fetch("/api/member-pin-verify", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${auth.token}`,
      },
      body: JSON.stringify({
        member_id: memberId,
        pin: entered,
      }),
    });
    if (auth.handleAuthStatus(res.status)) return;
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error || `HTTP ${res.status}`);

    if (!body?.ok) {
      pinError.value = "PIN ist falsch";
      pinInput.value = "";
      pinChecking.value = false;
      return;
    }
  } catch (e) {
    console.error("[pin] compare failed:", e);
    pinError.value = "PIN konnte nicht geprüft werden";
    pinInput.value = "";
    pinChecking.value = false;
    return;
  }

  pinInput.value = "";
  pinError.value = "";
  showPinModal.value = false;
  pinChecking.value = false;
  await openMember(memberId);
}

function onPinInput() {
  pinInput.value = pinInput.value.replace(/\D/g, "").slice(0, 4);
  pinError.value = "";
  if (pinInput.value.length === 4) {
    void confirmPin();
  }
}

function closePinModal() {
  showPinModal.value = false;
  pinInput.value = "";
  pinError.value = "";
  pendingMemberId.value = null;
  pinChecking.value = false;
}

watch(showPinModal, async (isOpen) => {
  if (!isOpen) return;
  await nextTick();
  pinInputRef.value?.focus();
});
</script>

<template>
  <DeviceAuthDialog v-if="!auth.authenticated" />

  <div v-else class="min-h-screen flex flex-col bg-gray-50 text-gray-800">
    <OfflineStatus />

    <!-- HEADER -->
    <header
      class="flex flex-col bg-white shadow-sm sticky top-0 z-40 border-b border-gray-200"
    >
      <!-- Topbar -->
      <div class="flex items-center justify-between px-4 py-2">
        <h1
          @click="reloadPage"
          class="text-lg md:text-xl font-semibold text-primary flex items-center gap-2 cursor-pointer select-none hover:text-blue-700 transition-colors"
        >
          <img
            :src="logoUrl"
            :alt="`${appTitle} Logo`"
            class="h-8 w-8 object-contain"
            @error="onLogoError"
          />
          <span>{{ appTitle }}</span>
        </h1>

        <div class="flex items-center gap-2">
          <RouterLink
            to="/admin/dashboard"
            class="bg-gray-200 text-gray-800 text-sm px-3 py-2 rounded-md hover:bg-gray-300 transition"
          >
            🔧 Admin
          </RouterLink>
          <button
            @click="showAddGuestModal = true"
            class="bg-green-600 text-white text-sm px-3 py-2 rounded-md hover:bg-green-700 transition"
          >
            ➕ Gast anlegen
          </button>
          <RouterLink
            v-if="auth.authenticated"
            to="/stock-refill"
            class="bg-blue-600 text-white text-sm px-3 py-2 rounded-md hover:bg-blue-700 transition"
          >
            📦 Nachfüllen
          </RouterLink>
        </div>
      </div>

      <!-- Statuszeile -->
      <div
        v-if="selectedMember"
        class="flex items-center justify-between bg-blue-50 border-t border-blue-200 px-4 py-3 text-blue-900"
      >
        <button
          @click="onBackToMembers"
          class="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-md font-medium shadow hover:bg-blue-700 active:scale-[0.97] transition-transform"
        >
          ← Zurück
        </button>
        <div class="flex-1 text-center">
          <span
            class="block text-lg md:text-xl font-semibold leading-tight truncate"
          >
            {{ selectedMember.name }}
          </span>
        </div>
      </div>
    </header>

    <!-- Toast -->
    <transition name="fade">
      <div
        v-if="toast"
        class="fixed bottom-6 left-1/2 -translate-x-1/2 bg-accent text-gray-900 font-semibold py-2 px-6 rounded-full shadow-lg z-50"
      >
        {{ toast }}
      </div>
    </transition>

    <!-- MAIN -->
    <main
      class="flex-1 max-w-7xl mx-auto w-full px-3 md:px-6 py-3 overflow-hidden"
    >
      <!-- Member-Auswahl -->
      <div v-if="!selectedMember" class="flex flex-col h-[calc(100vh-8rem)]">
        <!-- MemberPicker direkt hier, nicht im Footer -->
        <MemberPicker @select="handleMemberSelect" class="flex-1" />
      </div>

      <!-- Buchungsansicht -->
      <div
        v-else
        class="flex flex-col lg:flex-row gap-4 h-[calc(100vh-9rem)] overflow-hidden"
      >
        <!-- Produktbereich -->
        <div class="flex-1 flex flex-col overflow-hidden">
          <ProductGrid
            :products="store.products"
            :loading="loading"
            :isGuest="selectedMember?.is_guest"
            @add="addProduct"
            class="flex-1 overflow-hidden"
          />
        </div>

        <!-- Sidebar -->
        <aside
          class="relative w-full lg:w-[26%] flex flex-col bg-white rounded-xl border border-gray-200 shadow-sm min-h-0"
        >
          <div class="flex-1 min-h-0 overflow-y-auto space-y-3 p-2">
            <section>
              <div
                class="px-2 pb-1 text-xs font-semibold uppercase tracking-wide text-gray-500"
              >
                Heute gebucht
              </div>
              <BookingList
                :bookings="confirmedBookings"
                :totalToday="totalToday"
                :loading="loading"
                :showTotal="false"
                @undo="undoBooking"
              />
            </section>

            <section>
              <div
                class="px-2 pb-1 text-xs font-semibold uppercase tracking-wide text-amber-700"
              >
                Neu
              </div>
              <BookingList
                :bookings="queuedBookings"
                :totalToday="0"
                :loading="loading"
                :showTotal="false"
                @undo="undoBooking"
              />
            </section>
          </div>

          <div
            class="shrink-0 flex justify-between items-center px-3 py-2 text-base font-semibold text-gray-700 bg-blue-50 border-t border-blue-200"
          >
            <span>Summe heute</span>
            <span>{{ (totalToday / 100).toFixed(2) }} €</span>
          </div>

          <div
            class="shrink-0 grid grid-cols-2 border-t border-gray-300 bg-white"
          >
            <button
              @click="showBookings = true"
              class="h-12 bg-gray-200 text-gray-800 font-medium text-sm border border-gray-300 hover:bg-gray-300 transition"
            >
              📅 Übersicht
            </button>
            <button
              @click="showFreeAmount = true"
              class="h-12 bg-blue-600 text-white font-medium text-sm border border-blue-700 hover:bg-blue-700 transition"
            >
              💶 Freier Betrag
            </button>
            <button
              v-if="selectedMember?.is_guest && !selectedMember?.settled"
              @click="showPartialModal = true"
              class="h-12 bg-yellow-500 text-white font-medium text-sm border border-yellow-600 hover:bg-yellow-600 transition"
            >
              💰 Teilabrechnung
            </button>
            <button
              v-if="selectedMember?.is_guest && !selectedMember?.settled"
              @click="showSettleModal = true"
              class="h-12 bg-red-600 text-white font-medium text-sm border border-red-700 hover:bg-red-700 transition"
            >
              🧾 Abrechnung
            </button>
            <div
              v-else
              class="h-12 bg-gray-50 border border-transparent col-span-2"
            ></div>
          </div>
        </aside>
      </div>
    </main>

    <!-- FOOTER -->
    <footer
      class="bg-white border-t border-gray-200 shadow-inner py-2 px-4 sticky bottom-0 z-20"
    ></footer>
  </div>

  <!-- Overlays/Modals (fehlten zuvor) -->
  <transition name="fade">
    <div v-if="showBookings && selectedMember" class="fixed inset-0 z-50 flex">
      <div
        class="flex-1 bg-black/50 backdrop-blur-sm"
        @click="showBookings = false"
      ></div>
      <MemberBookings
        :member-id="selectedMember.id"
        :member-name="selectedMember.name"
        :is-guest="selectedMember.is_guest"
        :settled="selectedMember.settled"
        @close="showBookings = false"
      />
    </div>
  </transition>

  <GuestSettlementModal
    v-if="selectedMember"
    :show="showSettleModal"
    :member-id="selectedMember.id"
    :member-name="selectedMember.name"
    @close="showSettleModal = false"
    @confirm="confirmGuestSettlement"
    @open-partial="
      () => {
        showSettleModal = false;
        showPartialModal = true;
      }
    "
  />

  <GuestPartialSettlementModal
    v-if="selectedMember"
    :show="showPartialModal"
    :member-id="selectedMember.id"
    :member-name="selectedMember.name"
    @close="showPartialModal = false"
    @confirm="
      async (result) => {
        showPartialModal = false;
        const guestEnded = !!result?.guestEnded;
        showToast(
          guestEnded
            ? '✅ Teilabrechnung erfolgreich, Gast beendet'
            : '✅ Teilabrechnung erfolgreich'
        );
        const id = selectedMember?.id;
        if (id) {
          if (guestEnded) {
            closeMember();
            await refreshTerminalSnapshot();
          } else {
            await loadBookings(id);
            await refreshTerminalSnapshot();
          }
        }
      }
    "
  />

  <FreeAmountModal
    :show="showFreeAmount"
    @close="showFreeAmount = false"
    @confirm="addFreeAndClose"
  />

  <!-- Gast-Modal -->
  <BaseModal
    :show="showAddGuestModal"
    title="Neuen Gast anlegen"
    @close="showAddGuestModal = false"
    @confirm="addGuest"
  >
    <div class="space-y-3">
      <label class="block text-sm font-medium text-gray-600">Vorname</label>
      <input
        v-model="guestFirstname"
        class="w-full border rounded-md p-2 text-sm focus:ring-1 focus:ring-primary"
        placeholder="Vorname"
      />
      <label class="block text-sm font-medium text-gray-600">Nachname</label>
      <input
        v-model="guestLastname"
        class="w-full border rounded-md p-2 text-sm focus:ring-1 focus:ring-primary"
        placeholder="Nachname"
      />
    </div>
  </BaseModal>

  <transition name="fade">
    <div
      v-if="showPinModal"
      class="fixed inset-0 flex items-center justify-center bg-black/40 z-50"
    >
      <div
        class="bg-white rounded-2xl shadow-xl w-full max-w-sm p-6 space-y-4 border border-gray-200"
      >
        <h3 class="text-lg font-semibold text-primary">PIN</h3>
        <input
          ref="pinInputRef"
          v-model="pinInput"
          type="tel"
          inputmode="numeric"
          pattern="[0-9]*"
          maxlength="4"
          autocomplete="off"
          class="w-full border rounded-md p-2 text-sm focus:ring-1 focus:ring-primary"
          placeholder="0000"
          @input="onPinInput"
        />
        <p v-if="pinError" class="text-sm text-red-600">{{ pinError }}</p>
        <div class="flex justify-end">
          <button
            @click="closePinModal"
            class="px-4 py-2 text-gray-600 bg-gray-100 rounded-md hover:bg-gray-200"
          >
            Abbrechen
          </button>
        </div>
      </div>
    </div>
  </transition>
</template>

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.25s, transform 0.25s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
  transform: scale(0.97);
}
</style>

