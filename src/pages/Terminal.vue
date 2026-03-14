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
  isOnline,
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

  const member = store.members.find((m) => m.id === memberId);
  if (typeof member?.has_pin === "boolean") {
    pinRequiredMap.value[memberId] = member.has_pin;
    if (!member.has_pin) {
      await openMember(memberId);
      return;
    }

    pendingMemberId.value = memberId;
    showPinModal.value = true;
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

  <div v-else class="app-shell min-h-screen flex flex-col text-gray-800">
    <OfflineStatus />

    <!-- HEADER -->
    <header
      class="sticky top-0 z-40 px-3 pt-3"
    >
      <div class="glass-panel-strong rounded-[28px] px-4 py-3">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-center gap-3 min-w-0">
            <button
              @click="reloadPage"
              class="flex items-center gap-3 rounded-2xl bg-white/80 px-3 py-1.5 shadow-sm transition hover:bg-white"
            >
              <img
                :src="logoUrl"
                :alt="`${appTitle} Logo`"
                class="h-9 w-9 object-contain rounded-xl bg-slate-50 p-1"
                @error="onLogoError"
              />
              <h1
                class="display-brand truncate text-xl md:text-[1.65rem] font-semibold text-primary text-left"
              >
                {{ appTitle }}
              </h1>
            </button>
          </div>

          <div class="flex flex-wrap items-center justify-end gap-2">
          <RouterLink
            to="/admin/dashboard"
            class="button-outline-strong rounded-2xl border-slate-300 bg-white px-4 py-2.5 text-sm font-semibold text-slate-700 transition hover:border-slate-400 hover:bg-slate-50"
          >
            Admin
          </RouterLink>
          <button
            @click="showAddGuestModal = true"
            class="button-outline-strong rounded-2xl border-emerald-700 bg-emerald-600 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-emerald-700"
          >
            Gast anlegen
          </button>
          <RouterLink
            v-if="auth.authenticated"
            to="/stock-refill"
            class="button-outline-strong rounded-2xl border-blue-800 bg-primary px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-blue-800"
          >
            Nachfüllen
          </RouterLink>
          </div>
        </div>

        <!-- Statuszeile -->
        <div
          v-if="selectedMember"
          class="mt-2 grid grid-cols-[auto_1fr_auto] items-center gap-2 rounded-[22px] border border-blue-100 bg-gradient-to-r from-blue-50 via-white to-blue-50 px-2.5 py-2 text-blue-950"
        >
          <button
            @click="onBackToMembers"
            class="button-outline-strong flex items-center gap-2 rounded-2xl border-blue-800 bg-primary px-3.5 py-2 text-sm font-semibold text-white hover:bg-blue-800 active:scale-[0.98] transition-transform"
          >
            ← Zurück
          </button>
          <div class="min-w-0 text-center">
            <div class="text-[0.62rem] font-bold uppercase tracking-[0.18em] text-blue-500">
              Aktives Mitglied
            </div>
            <span
              class="block text-base md:text-[1.15rem] font-semibold leading-tight truncate"
            >
              {{ selectedMember.name }}
            </span>
          </div>
          <div
            class="justify-self-end rounded-2xl bg-white/85 px-2.5 py-1.5 text-right shadow-sm"
          >
            <div class="text-[0.62rem] font-bold uppercase tracking-[0.14em] text-slate-500">
              Heute
            </div>
            <div class="text-sm md:text-[0.95rem] font-semibold text-slate-900">
              {{ (totalToday / 100).toFixed(2) }} €
            </div>
          </div>
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
      class="flex-1 max-w-[1500px] mx-auto w-full px-3 pb-3 overflow-hidden"
    >
      <!-- Member-Auswahl -->
      <div v-if="!selectedMember" class="flex flex-col h-[calc(100vh-7.75rem)] xl:h-[calc(100vh-7.35rem)]">
        <!-- MemberPicker direkt hier, nicht im Footer -->
        <MemberPicker @select="handleMemberSelect" class="flex-1" />
      </div>

      <!-- Buchungsansicht -->
      <div
        v-else
        class="grid grid-cols-1 xl:grid-cols-[minmax(0,1fr)_20.5rem] 2xl:grid-cols-[minmax(0,1fr)_22rem] gap-3 xl:gap-2.5 h-[calc(100vh-9.3rem)] xl:h-[calc(100vh-8.95rem)] overflow-hidden"
      >
        <!-- Produktbereich -->
        <div class="glass-panel rounded-[30px] flex flex-col overflow-hidden">
          <ProductGrid
            :products="store.products"
            :loading="loading"
            :isGuest="selectedMember?.is_guest"
            @add="addProduct"
            class="flex-1 overflow-hidden px-3 py-3"
          />
        </div>

        <!-- Sidebar -->
        <aside
          class="glass-panel relative w-full flex flex-col rounded-[30px] min-h-0 overflow-hidden"
        >
          <div class="soft-scrollbar touch-scroll flex-1 min-h-0 overflow-y-auto space-y-3 p-3">
            <section>
              <div class="px-1 pb-2">
                <div class="section-chip">Heute gebucht</div>
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
              <div class="px-1 pb-2">
                <div class="section-chip !text-amber-700 !border-amber-200 !bg-amber-50/90">
                  Neu
                </div>
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
            class="shrink-0 flex justify-between items-center px-4 py-3 text-base font-semibold text-slate-800 bg-gradient-to-r from-blue-50 to-white border-t border-slate-200"
          >
            <span>Summe heute</span>
            <span class="rounded-full bg-white px-3 py-1 shadow-sm">{{ (totalToday / 100).toFixed(2) }} €</span>
          </div>

          <div
            class="shrink-0 grid grid-cols-2 gap-2 border-t border-slate-200 bg-white/75 p-3"
          >
            <button
              @click="showBookings = true"
              class="button-outline-strong h-12 xl:h-11 rounded-2xl border-slate-300 bg-slate-100 text-slate-800 font-semibold text-sm hover:bg-slate-200 transition"
            >
              Übersicht
            </button>
            <button
              @click="showFreeAmount = true"
              class="button-outline-strong h-12 xl:h-11 rounded-2xl border-blue-800 bg-primary text-white font-semibold text-sm hover:bg-blue-800 transition"
            >
              Freier Betrag
            </button>
            <button
              v-if="selectedMember?.is_guest && !selectedMember?.settled"
              @click="showPartialModal = true"
              class="button-outline-strong h-12 xl:h-11 rounded-2xl border-amber-700 bg-amber-500 text-white font-semibold text-sm hover:bg-amber-600 transition"
            >
              Teilabrechnung
            </button>
            <button
              v-if="selectedMember?.is_guest && !selectedMember?.settled"
              @click="showSettleModal = true"
              class="button-outline-strong h-12 xl:h-11 rounded-2xl border-red-800 bg-red-600 text-white font-semibold text-sm hover:bg-red-700 transition"
            >
              Abrechnung
            </button>
            <div
              v-else
              class="h-12 rounded-2xl bg-slate-50 border border-transparent col-span-2"
            ></div>
          </div>
        </aside>
      </div>
    </main>

    <!-- FOOTER -->
    <footer
      class="sticky bottom-0 z-20 px-3 pb-3"
    >
      <div class="glass-panel rounded-[24px] h-3 border-transparent shadow-none bg-white/35"></div>
    </footer>
  </div>

  <!-- Overlays/Modals (fehlten zuvor) -->
  <transition name="fade">
    <div v-if="showBookings && selectedMember" class="fixed inset-0 z-50 flex">
      <div
        class="flex-1 bg-slate-950/45 backdrop-blur-sm"
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
        class="w-full border border-slate-300 rounded-2xl p-3 text-sm focus:ring-1 focus:ring-primary"
        placeholder="Vorname"
      />
      <label class="block text-sm font-medium text-gray-600">Nachname</label>
        <input
          v-model="guestLastname"
        class="w-full border border-slate-300 rounded-2xl p-3 text-sm focus:ring-1 focus:ring-primary"
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
        class="glass-panel-strong rounded-[28px] w-full max-w-sm p-6 space-y-4"
      >
        <div>
          <div class="section-chip mb-2">Sicherheit</div>
          <h3 class="display-brand text-xl font-semibold text-primary">PIN</h3>
        </div>
        <input
          ref="pinInputRef"
          v-model="pinInput"
          type="tel"
          inputmode="numeric"
          pattern="[0-9]*"
          maxlength="4"
          autocomplete="off"
          class="w-full border border-slate-300 rounded-2xl p-3 text-lg tracking-[0.45em] text-center font-semibold focus:ring-1 focus:ring-primary"
          placeholder="0000"
          @input="onPinInput"
        />
        <p v-if="pinError" class="text-sm text-red-600">{{ pinError }}</p>
        <div class="flex justify-end">
          <button
            @click="closePinModal"
            class="button-outline-strong rounded-2xl border-slate-300 bg-white px-4 py-2 text-slate-600 font-medium hover:bg-slate-50"
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

