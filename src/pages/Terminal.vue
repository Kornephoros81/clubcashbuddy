<script setup lang="ts">
import { ref, watch, onMounted, onUnmounted, provide, nextTick, computed } from "vue";
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
  bookedTodayIds,
  pendingQueueCount,
  failedQueueCount,
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

const queueBadgeText = computed(() => {
  if (failedQueueCount.value > 0) {
    return `${failedQueueCount.value} Fehler`;
  }
  if (!isOnline.value) {
    return "Offline";
  }
  if (pendingQueueCount.value > 0) {
    return `${pendingQueueCount.value} in Queue`;
  }
  return "Live";
});
const queueBadgeClass = computed(() => {
  if (failedQueueCount.value > 0) {
    return "bg-rose-500/15 text-rose-100 ring-1 ring-rose-300/30";
  }
  if (!isOnline.value) {
    return "bg-amber-500/15 text-amber-50 ring-1 ring-amber-300/30";
  }
  if (pendingQueueCount.value > 0) {
    return "bg-sky-500/15 text-sky-50 ring-1 ring-sky-300/30";
  }
  return "bg-emerald-500/15 text-emerald-50 ring-1 ring-emerald-300/30";
});
const selectedMemberInitials = computed(() => {
  const name = String(selectedMember.value?.name ?? "").trim();
  if (!name) return "CC";
  return name
    .split(/[,\s]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part.charAt(0).toUpperCase())
    .join("");
});

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

  <div
    v-else
    class="terminal-shell min-h-screen flex flex-col text-slate-100"
  >
    <OfflineStatus />

    <header
      class="sticky top-0 z-40 border-b border-white/10 bg-slate-950/72 backdrop-blur-xl"
    >
      <div class="mx-auto flex w-full max-w-[1600px] flex-col gap-3 px-4 py-3 md:px-6 xl:px-8">
        <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
          <button
            @click="reloadPage"
            class="flex max-w-full items-center gap-3 rounded-2xl border border-white/10 bg-white/8 px-3 py-2 text-left shadow-[0_12px_40px_rgba(15,23,42,0.26)] transition hover:bg-white/12"
          >
            <span class="flex h-11 w-11 items-center justify-center rounded-xl bg-white/90 shadow-inner shadow-slate-200/60">
              <img
                :src="logoUrl"
                :alt="`${appTitle} Logo`"
                class="h-8 w-8 object-contain"
                @error="onLogoError"
              />
            </span>
            <span class="min-w-0">
              <span class="block terminal-wordmark truncate text-lg md:text-xl text-white">
                {{ appTitle }}
              </span>
            </span>
          </button>

          <div class="flex flex-wrap items-center gap-2 text-sm">
            <span class="rounded-full border border-white/10 bg-white/8 px-3 py-1.5 text-slate-200">
              {{ auth.deviceName || "Terminal" }}
            </span>
            <span class="rounded-full border border-white/10 bg-white/8 px-3 py-1.5 text-slate-200">
              {{ isOnline ? "Online bereit" : "Offline aktiv" }}
            </span>
            <span
              v-if="selectedMember"
              class="rounded-full border border-white/10 bg-white/8 px-3 py-1.5 text-slate-200"
            >
              {{ selectedMember.is_guest ? "Gast" : "Mitglied" }}
            </span>
            <span
              class="inline-flex items-center rounded-full px-3 py-1.5 text-sm font-semibold"
              :class="queueBadgeClass"
            >
              {{ queueBadgeText }}
            </span>
            <RouterLink
              to="/admin/dashboard"
              class="terminal-action-button terminal-action-button--ghost"
            >
              Admin
            </RouterLink>
            <button
              @click="showAddGuestModal = true"
              class="terminal-action-button terminal-action-button--accent"
            >
              Gast anlegen
            </button>
            <RouterLink
              v-if="auth.authenticated"
              to="/stock-refill"
              class="terminal-action-button terminal-action-button--primary"
            >
              Nachfuellen
            </RouterLink>
          </div>
        </div>

        <div
          v-if="selectedMember"
          class="terminal-selected-member flex items-center justify-between gap-3 rounded-2xl px-3 py-2.5"
        >
          <div class="flex items-center gap-4 min-w-0">
            <span
              class="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-white/12 text-sm font-semibold text-white ring-1 ring-white/15"
            >
              {{ selectedMemberInitials }}
            </span>
            <div class="min-w-0">
              <div class="truncate text-lg font-semibold text-white md:text-xl">
                {{ selectedMember.name }}
              </div>
            </div>
          </div>

          <div class="flex items-center gap-3">
            <div class="rounded-xl border border-white/10 bg-white/8 px-3 py-2 text-right">
              <div class="text-xs text-cyan-100/65">Heute</div>
              <div class="text-lg font-semibold text-white">{{ (totalToday / 100).toFixed(2) }} €</div>
            </div>
            <button
              @click="onBackToMembers"
              class="terminal-action-button terminal-action-button--light"
            >
              Zurueck zur Auswahl
            </button>
          </div>
        </div>
      </div>
    </header>

    <transition name="fade">
      <div
        v-if="toast"
        class="fixed bottom-6 left-1/2 z-50 -translate-x-1/2 rounded-full border border-white/10 bg-slate-950/92 px-6 py-3 font-semibold text-white shadow-[0_18px_60px_rgba(15,23,42,0.45)] backdrop-blur-xl"
      >
        {{ toast }}
      </div>
    </transition>

    <main
      class="mx-auto flex w-full max-w-[1600px] flex-1 px-3 py-3 md:px-6 xl:px-8"
    >
      <div
        v-if="!selectedMember"
        class="w-full overflow-hidden rounded-[1.6rem] border border-white/10 bg-slate-950/45 shadow-[0_24px_90px_rgba(15,23,42,0.26)] backdrop-blur-xl"
      >
        <MemberPicker @select="handleMemberSelect" class="h-[calc(100vh-7.8rem)]" />
      </div>

      <div
        v-else
        class="grid w-full gap-4 xl:grid-cols-[minmax(0,1fr)_330px]"
      >
        <div
          class="overflow-hidden rounded-[1.6rem] border border-white/10 bg-slate-950/45 shadow-[0_24px_90px_rgba(15,23,42,0.26)] backdrop-blur-xl"
        >
          <ProductGrid
            :products="store.products"
            :loading="loading"
            :isGuest="selectedMember?.is_guest"
            @add="addProduct"
            class="h-full"
          />
        </div>

        <aside
          class="relative flex min-h-0 flex-col overflow-hidden rounded-[1.6rem] border border-white/10 bg-slate-950/58 shadow-[0_24px_90px_rgba(15,23,42,0.28)] backdrop-blur-xl"
        >
          <div class="flex-1 min-h-0 overflow-y-auto space-y-4 px-3 py-3">
            <section>
              <div
                class="px-1 pb-1 text-[0.72rem] font-semibold uppercase tracking-[0.2em] text-slate-400"
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
                class="px-1 pb-1 text-[0.72rem] font-semibold uppercase tracking-[0.2em] text-amber-300/85"
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
            class="terminal-totalbar shrink-0 flex items-center justify-between gap-3 px-4 py-3"
          >
            <div class="text-sm font-semibold text-white">
              {{ (totalToday / 100).toFixed(2) }} €
            </div>
            <div class="text-right text-xs text-cyan-50/70">
              <div>{{ confirmedBookings.length }} bestaetigt</div>
              <div>{{ queuedBookings.length }} neu</div>
            </div>
          </div>

          <div
            class="grid shrink-0 grid-cols-2 gap-2 border-t border-white/10 bg-black/10 p-3"
          >
            <button
              @click="showBookings = true"
              class="terminal-action-button terminal-action-button--ghost h-12 justify-center"
            >
              Uebersicht
            </button>
            <button
              @click="showFreeAmount = true"
              class="terminal-action-button terminal-action-button--primary h-12 justify-center"
            >
              Freier Betrag
            </button>
            <button
              v-if="selectedMember?.is_guest && !selectedMember?.settled"
              @click="showPartialModal = true"
              class="terminal-action-button h-12 justify-center bg-amber-500/90 text-amber-950 hover:bg-amber-400"
            >
              Teilabrechnung
            </button>
            <button
              v-if="selectedMember?.is_guest && !selectedMember?.settled"
              @click="showSettleModal = true"
              class="terminal-action-button h-12 justify-center bg-rose-500/90 text-white hover:bg-rose-400"
            >
              Abrechnung
            </button>
            <div
              v-else
              class="col-span-2 h-12 rounded-xl border border-dashed border-white/10 bg-white/5"
            ></div>
          </div>
        </aside>
      </div>
    </main>
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
.terminal-shell {
  background:
    radial-gradient(circle at top left, rgba(56, 189, 248, 0.16), transparent 28%),
    radial-gradient(circle at top right, rgba(45, 212, 191, 0.14), transparent 24%),
    linear-gradient(160deg, #020617 0%, #0f172a 48%, #111827 100%);
}

.terminal-wordmark {
  font-family: "Georgia", "Times New Roman", serif;
  letter-spacing: 0.01em;
}

.terminal-selected-member {
  background:
    linear-gradient(135deg, rgba(14, 116, 144, 0.42), rgba(15, 23, 42, 0.4)),
    rgba(255, 255, 255, 0.04);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08);
}

.terminal-totalbar {
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.04), rgba(255, 255, 255, 0.02)),
    rgba(15, 23, 42, 0.38);
}

.terminal-action-button {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  border-radius: 1rem;
  padding: 0.72rem 0.95rem;
  font-size: 0.86rem;
  font-weight: 600;
  transition:
    transform 0.2s ease,
    background-color 0.2s ease,
    border-color 0.2s ease,
    box-shadow 0.2s ease;
}

.terminal-action-button:hover {
  transform: translateY(-1px);
}

.terminal-action-button--ghost {
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(255, 255, 255, 0.06);
  color: #e2e8f0;
}

.terminal-action-button--primary {
  background: linear-gradient(135deg, #38bdf8, #0f766e);
  color: white;
  box-shadow: 0 16px 40px rgba(8, 145, 178, 0.25);
}

.terminal-action-button--accent {
  background: linear-gradient(135deg, #f59e0b, #fb7185);
  color: #fff7ed;
  box-shadow: 0 16px 40px rgba(251, 113, 133, 0.24);
}

.terminal-action-button--light {
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(255, 255, 255, 0.08);
  color: white;
}

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

