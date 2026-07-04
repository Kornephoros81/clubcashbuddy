<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted } from "vue";
import { useAdminMembersStore } from "@/stores/useAdminMembersStore";
import { useToast } from "@/composables/useToast";
import { useModal } from "@/composables/useModal";
import BaseModal from "@/components/BaseModal.vue";
import { adminRpc } from "@/lib/adminApi";
import { useAppAuthStore } from "@/stores/useAppAuthStore";

const store = useAdminMembersStore();
const { show: showToast } = useToast();
const { confirm } = useModal();

const showNewMemberModal = ref(false);
const showCreditModal = ref(false);
const modalMember = ref<any | null>(null);
const modalAmount = ref<number>(0);
const modalComment = ref("");
const newFirstname = ref("");
const newLastname = ref("");
const showArchivedMembers = ref(false);
const archivedCandidates = ref<any[]>([]);
const showArchivedCandidateModal = ref(false);
const creatingNewDespiteCandidates = ref(false);
const pinDrafts = ref<Record<string, string>>({});
const storedPins = ref<Record<string, string>>({});
const showPinPlain = ref<Record<string, boolean>>({});
const pinSaving = ref<Record<string, boolean>>({});
const searchTerm = ref("");
const activeFilter = ref<"all" | "active" | "inactive">("all");

function formatEuro(cents: number | null | undefined) {
  return `${((Number(cents ?? 0) || 0) / 100).toFixed(2)} €`;
}

function formatDateTime(value: string | null | undefined) {
  if (!value) return "-";
  return new Date(value).toLocaleString("de-DE", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

const filteredMembers = computed(() => {
  const query = searchTerm.value.trim().toLocaleLowerCase("de-DE");
  return store.members.filter((member) => {
    const fullName = `${member.firstname ?? ""} ${member.lastname ?? ""}`
      .trim()
      .toLocaleLowerCase("de-DE");
    const matchesSearch = !query || fullName.includes(query);
    const matchesActive =
      activeFilter.value === "all"
        ? true
        : activeFilter.value === "active"
          ? Boolean(member.active)
          : !member.active;
    return matchesSearch && matchesActive;
  });
});

// ✅ Initial Load (wartet auf gültige Session)
onMounted(async () => {
  await store.initMembers();
  await loadMemberPins();

  if (typeof window !== "undefined") {
    window.addEventListener("queue-synced", onQueueSynced as EventListener);
  }
});

onUnmounted(() => {
  if (typeof window !== "undefined") {
    window.removeEventListener("queue-synced", onQueueSynced as EventListener);
  }
});

function normalizePin(input: string) {
  return (input || "").replace(/[^A-Za-z0-9]/g, "").slice(0, 4);
}

async function loadMemberPins() {
  try {
    const data = await adminRpc("list_member_pins");
    const nextStored: Record<string, string> = {};
    for (const row of (data as any[]) ?? []) {
      nextStored[row.member_id] = normalizePin(String(row.pin_plain ?? ""));
    }
    storedPins.value = nextStored;

    const nextDrafts: Record<string, string> = {};
    for (const m of store.members) {
      nextDrafts[m.id] = nextStored[m.id] ?? "";
    }
    pinDrafts.value = nextDrafts;
  } catch (error) {
    console.error("[loadMemberPins]", error);
    showToast("⚠️ PINs konnten nicht geladen werden");
  }
}

async function onQueueSynced() {
  try {
    await store.loadMembers();
    await loadMemberPins();
  } catch (err) {
    console.error("[queue-synced][members]", err);
  }
}

function onPinInput(memberId: string, value: string) {
  pinDrafts.value[memberId] = normalizePin(value);
}

function onPinInputEvent(memberId: string, event: Event) {
  const target = event.target as HTMLInputElement | null;
  onPinInput(memberId, target?.value ?? "");
}

function togglePin(memberId: string) {
  showPinPlain.value[memberId] = !showPinPlain.value[memberId];
}

async function savePin(member: any) {
  const pin = normalizePin(pinDrafts.value[member.id] ?? "");
  if (pin.length > 0 && pin.length !== 4) {
    showToast("⚠️ PIN muss 4-stellig alphanumerisch sein");
    return;
  }

  pinSaving.value[member.id] = true;
  try {
    if (pin.length === 0) {
      await adminRpc("delete_member_pin", { member_id: member.id });

      delete storedPins.value[member.id];
      pinDrafts.value[member.id] = "";
      showToast(`✅ PIN für ${member.firstname} ${member.lastname} entfernt`);
      return;
    }

    await adminRpc("upsert_member_pin", {
      member_id: member.id,
      pin_plain: pin,
    });

    storedPins.value[member.id] = pin;
    pinDrafts.value[member.id] = pin;
    showToast(`✅ PIN für ${member.firstname} ${member.lastname} gespeichert`);
  } catch (err) {
    console.error("[savePin]", err);
    showToast("⚠️ Fehler beim Speichern der PIN");
  } finally {
    pinSaving.value[member.id] = false;
  }
}

// --- Mitglied hinzufügen ---
async function createNewMember() {
  await store.addMember(newFirstname.value, newLastname.value);
  await loadMemberPins();
  showToast("✅ Mitglied erfolgreich angelegt");
  newFirstname.value = "";
  newLastname.value = "";
  showNewMemberModal.value = false;
  showArchivedCandidateModal.value = false;
  archivedCandidates.value = [];
}

async function confirmAddMember() {
  try {
    if (!newFirstname.value.trim() || !newLastname.value.trim()) {
      showToast("⚠️ Vor- und Nachname sind erforderlich");
      return;
    }

    const candidates = await store.findArchivedCandidates(
      newFirstname.value,
      newLastname.value
    );
    if (candidates.length > 0) {
      archivedCandidates.value = candidates;
      showArchivedCandidateModal.value = true;
      return;
    }

    await createNewMember();
  } catch (err) {
    console.error("[add]", err);
    showToast("⚠️ Fehler beim Anlegen des Mitglieds");
  }
}

async function createDespiteArchivedCandidates() {
  creatingNewDespiteCandidates.value = true;
  try {
    await createNewMember();
  } catch (err) {
    console.error("[add.despiteCandidates]", err);
    showToast("⚠️ Fehler beim Anlegen des Mitglieds");
  } finally {
    creatingNewDespiteCandidates.value = false;
  }
}

async function reactivateArchivedMember(member: any) {
  try {
    await store.restoreArchivedMember(member.id);
    await loadMemberPins();
    showToast(`✅ ${member.firstname} ${member.lastname} reaktiviert`);
    newFirstname.value = "";
    newLastname.value = "";
    showNewMemberModal.value = false;
    showArchivedCandidateModal.value = false;
    archivedCandidates.value = [];
  } catch (err) {
    console.error("[reactivateArchivedMember]", err);
    showToast("⚠️ Fehler beim Reaktivieren des Mitglieds");
  }
}

// --- Mitglied speichern ---
async function save(m: any) {
  try {
    await store.updateMember(m);
    showToast(`💾 Änderungen für ${m.firstname} ${m.lastname} gespeichert`);
  } catch (err) {
    console.error("[save]", err);
    showToast("⚠️ Fehler beim Speichern");
  }
}

function archiveErrorMessage(err: unknown) {
  const message = String((err as any)?.message ?? err ?? "");
  const openMatch = message.match(/ARCHIVE_OPEN_TRANSACTIONS:(\d+)/);
  if (openMatch) {
    const count = Number(openMatch[1] ?? 0);
    return `Mitglied kann nicht archiviert werden, weil noch ${count} offene Buchung${count === 1 ? "" : "en"} vorhanden ${count === 1 ? "ist" : "sind"}.`;
  }

  const balanceMatch = message.match(/ARCHIVE_BALANCE_NOT_ZERO:([-]?\d+)/);
  if (balanceMatch) {
    return `Mitglied kann nicht archiviert werden, weil der Saldo noch ${formatEuro(Number(balanceMatch[1]))} beträgt.`;
  }

  return message || "Fehler beim Archivieren des Mitglieds";
}

// --- Mitglied archivieren ---
async function archiveMember(m: any) {
  const ok = await confirm(
    "Mitglied archivieren",
    `Soll das Mitglied "${m.firstname} ${m.lastname}" archiviert werden? Es verschwindet aus der normalen Mitgliederliste, bleibt aber in Berichten erhalten.`,
    { danger: true }
  );
  if (!ok) return;

  try {
    await store.archiveMember(m.id);
    showToast(`🗄️ ${m.firstname} ${m.lastname} archiviert`);
  } catch (err) {
    console.error("[archiveMember]", err);
    showToast(`⚠️ ${archiveErrorMessage(err)}`);
  }
}

async function toggleArchivedMembers() {
  showArchivedMembers.value = !showArchivedMembers.value;
  if (showArchivedMembers.value) {
    try {
      await store.loadArchivedMembers();
    } catch (err) {
      console.error("[loadArchivedMembers]", err);
      showToast("⚠️ Archivierte Mitglieder konnten nicht geladen werden");
    }
  }
}

async function restoreArchivedMember(member: any) {
  const ok = await confirm(
    "Archivierung aufheben",
    `Soll "${member.firstname} ${member.lastname}" wieder in die Mitgliederliste aufgenommen werden? Das Mitglied bleibt danach zunächst inaktiv.`,
    { danger: false }
  );
  if (!ok) return;

  try {
    await store.restoreArchivedMember(member.id);
    await loadMemberPins();
    showToast(`✅ ${member.firstname} ${member.lastname} wiederhergestellt`);
  } catch (err) {
    console.error("[restoreArchivedMember]", err);
    showToast("⚠️ Fehler beim Wiederherstellen des Mitglieds");
  }
}

// --- Guthabenbuchung ---
function openCreditModal(member: any) {
  modalMember.value = member;
  modalAmount.value = 0;
  modalComment.value = "";
  showCreditModal.value = true;
}

function closeCreditModal() {
  showCreditModal.value = false;
  modalMember.value = null;
  modalAmount.value = 0;
  modalComment.value = "";
}

async function confirmCredit() {
  const m = modalMember.value;
  if (!m || modalAmount.value <= 0) {
    showToast("⚠️ Bitte Betrag in € eingeben");
    return;
  }

  const cents = Math.round(modalAmount.value * 100);
  try {
    const authStore = useAppAuthStore();
    const adminName = authStore.adminUser || "Unbekannt";
    const timestamp = new Date().toLocaleString("sv-SE").replace("T", " ");
    const note =
      modalComment.value.trim().length > 0
        ? modalComment.value.trim()
        : `Admin-Guthabenbuchung ${adminName} ${timestamp}`;

    await adminRpc("book_free_amount", {
      member_id: m.id,
      amount_cents: cents,
      note,
    });

    showToast(
      `💶 ${modalAmount.value.toFixed(2)} € für ${m.firstname} ${
        m.lastname
      } gebucht`
    );
    closeCreditModal();
    await store.loadMembers();
  } catch (err) {
    console.error("[credit]", err);
    showToast("⚠️ Fehler bei der Guthabenbuchung");
  }
}
</script>

<template>
  <div class="space-y-6">
    <!-- Header -->
    <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-3">
      <h2 class="text-xl font-semibold text-primary">Mitgliederverwaltung</h2>
      <div class="flex flex-col sm:flex-row gap-2 w-full sm:w-auto">
        <button
          @click="toggleArchivedMembers"
          class="bg-gray-100 text-gray-700 px-4 py-2 rounded-lg shadow-sm border border-gray-200 hover:bg-gray-200 transition w-full sm:w-auto"
        >
          {{ showArchivedMembers ? "Archiv ausblenden" : "Archivierte Mitglieder" }}
        </button>
        <button
          @click="showNewMemberModal = true"
          class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition w-full sm:w-auto"
        >
          + Mitglied
        </button>
      </div>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4">
      <div class="grid grid-cols-1 md:grid-cols-[minmax(0,1fr)_220px] gap-3">
        <div>
          <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Suche</label>
          <input
            v-model="searchTerm"
            type="text"
            placeholder="Name suchen"
            class="w-full border rounded-md px-3 py-2 text-sm"
          />
        </div>
        <div>
          <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Status</label>
          <select
            v-model="activeFilter"
            class="w-full border rounded-md px-3 py-2 text-sm"
          >
            <option value="all">Alle</option>
            <option value="active">Nur aktiv</option>
            <option value="inactive">Nur inaktiv</option>
          </select>
        </div>
      </div>
      <div class="mt-3 text-xs text-gray-500">
        {{ filteredMembers.length }} von {{ store.members.length }} Mitgliedern sichtbar
      </div>
    </div>

    <div
      v-if="showArchivedMembers"
      class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-3"
    >
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold text-gray-900">Archivierte Mitglieder</h3>
        <button
          @click="store.loadArchivedMembers()"
          class="text-sm px-3 py-1.5 rounded-md bg-gray-100 hover:bg-gray-200 text-gray-700"
          :disabled="store.archivedLoading"
        >
          Aktualisieren
        </button>
      </div>

      <div v-if="store.archivedLoading" class="text-sm text-gray-500 py-4">
        Archiv wird geladen...
      </div>
      <div
        v-else-if="store.archivedMembers.length === 0"
        class="text-sm text-gray-500 py-4"
      >
        Keine archivierten Mitglieder vorhanden
      </div>
      <div v-else class="overflow-x-auto">
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-gray-50 text-gray-500 uppercase text-xs font-semibold">
            <tr>
              <th class="px-3 py-2 text-left">Name</th>
              <th class="px-3 py-2 text-right">Saldo</th>
              <th class="px-3 py-2 text-left">Archiviert</th>
              <th class="px-3 py-2 text-left">Letzte Buchung</th>
              <th class="px-3 py-2 text-center">Aktion</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="m in store.archivedMembers"
              :key="m.id"
              class="border-t"
            >
              <td class="px-3 py-2 font-medium">{{ m.firstname }} {{ m.lastname }}</td>
              <td
                class="px-3 py-2 text-right font-mono"
                :class="m.balance < 0 ? 'text-red-600' : 'text-green-700'"
              >
                {{ formatEuro(m.balance) }}
              </td>
              <td class="px-3 py-2">{{ formatDateTime(m.archived_at) }}</td>
              <td class="px-3 py-2">{{ formatDateTime(m.last_booking_at) }}</td>
              <td class="px-3 py-2 text-center">
                <button
                  @click="restoreArchivedMember(m)"
                  class="bg-primary/10 text-primary px-3 py-1 rounded-md hover:bg-primary/20 text-sm font-medium"
                >
                  Reaktivieren
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <!-- Ladezustand -->
    <div v-if="store.loading" class="text-center py-10 text-gray-500">
      ⏳ Mitglieder werden geladen...
    </div>

    <!-- Tabelle -->
    <div v-else class="space-y-4">
      <div class="lg:hidden space-y-4">
        <div
          v-for="m in filteredMembers"
          :key="m.id"
          class="bg-white rounded-2xl shadow border border-gray-200 p-4 space-y-4"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <div class="text-base font-semibold text-gray-900">
                {{ m.firstname }} {{ m.lastname }}
              </div>
              <div
                class="text-sm font-mono mt-1"
                :class="m.balance < 0 ? 'text-red-600' : 'text-green-700'"
              >
                {{ (m.balance / 100).toFixed(2) }} €
              </div>
            </div>
            <label class="inline-flex items-center gap-2 text-sm text-gray-600">
              <input
                type="checkbox"
                v-model="m.active"
                class="scale-125 accent-primary"
              />
              Aktiv
            </label>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Vorname</label>
              <input
                v-model="m.firstname"
                class="w-full border rounded-md px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Nachname</label>
              <input
                v-model="m.lastname"
                class="w-full border rounded-md px-3 py-2 text-sm"
              />
            </div>
          </div>

          <div>
            <div class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-2">PIN</div>
            <div class="flex flex-wrap items-center gap-2">
              <input
                :type="showPinPlain[m.id] ? 'text' : 'password'"
                :value="pinDrafts[m.id] ?? ''"
                maxlength="4"
                class="w-24 border rounded-md px-3 py-2 text-sm"
                placeholder="----"
                @input="onPinInputEvent(m.id, $event)"
              />
              <button
                @click="togglePin(m.id)"
                class="bg-gray-100 text-gray-700 px-3 py-2 rounded-md hover:bg-gray-200 text-sm"
                title="PIN anzeigen/verstecken"
              >
                {{ showPinPlain[m.id] ? "🙈" : "👁️" }}
              </button>
              <button
                @click="savePin(m)"
                :disabled="pinSaving[m.id]"
                class="bg-blue-100 text-blue-700 px-3 py-2 rounded-md hover:bg-blue-200 text-sm font-medium disabled:opacity-50"
              >
                PIN speichern
              </button>
            </div>
            <div class="mt-2 text-xs text-gray-500">
              {{ storedPins[m.id] ? "PIN gesetzt" : "kein PIN" }}
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
            <button
              @click="save(m)"
              class="bg-primary/10 text-primary px-3 py-2 rounded-md hover:bg-primary/20 text-sm font-medium"
            >
              💾 Speichern
            </button>
            <button
              @click="openCreditModal(m)"
              class="bg-green-100 text-green-700 px-3 py-2 rounded-md hover:bg-green-200 text-sm font-medium"
            >
              ➕ Guthaben
            </button>
            <button
              @click="archiveMember(m)"
              class="bg-amber-100 text-amber-800 px-3 py-2 rounded-md hover:bg-amber-200 text-sm font-medium"
            >
              🗄️ Archivieren
            </button>
          </div>
        </div>
      </div>

      <div
        class="hidden lg:block bg-white rounded-2xl shadow overflow-x-auto border border-gray-200"
      >
      <table class="min-w-full text-sm text-gray-700">
        <thead
          class="bg-primary/10 text-primary uppercase text-xs font-semibold"
        >
          <tr>
            <th class="px-4 py-3 text-left">Vorname</th>
            <th class="px-4 py-3 text-left">Nachname</th>
            <th class="px-4 py-3 text-right">Saldo (€)</th>
            <th class="px-4 py-3 text-left">PIN</th>
            <th class="px-4 py-3 text-center">Aktiv</th>
            <th class="px-4 py-3 text-center">Aktionen</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="m in filteredMembers"
            :key="m.id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">
              <input
                v-model="m.firstname"
                class="w-full border rounded-md px-2 py-1 text-sm"
              />
            </td>
            <td class="px-4 py-2">
              <input
                v-model="m.lastname"
                class="w-full border rounded-md px-2 py-1 text-sm"
              />
            </td>
            <td
              class="px-4 py-2 text-right font-mono"
              :class="m.balance < 0 ? 'text-red-600' : 'text-green-700'"
            >
              {{ (m.balance / 100).toFixed(2) }} €
            </td>
            <td class="px-4 py-2">
              <div class="flex items-center gap-2">
                <input
                  :type="showPinPlain[m.id] ? 'text' : 'password'"
                  :value="pinDrafts[m.id] ?? ''"
                  maxlength="4"
                  class="w-24 border rounded-md px-2 py-1 text-sm"
                  placeholder="----"
                  @input="onPinInputEvent(m.id, $event)"
                />
                <button
                  @click="togglePin(m.id)"
                  class="bg-gray-100 text-gray-700 px-2 py-1 rounded-md hover:bg-gray-200 text-sm"
                  title="PIN anzeigen/verstecken"
                >
                  {{ showPinPlain[m.id] ? "🙈" : "👁️" }}
                </button>
                <button
                  @click="savePin(m)"
                  :disabled="pinSaving[m.id]"
                  class="bg-blue-100 text-blue-700 px-2 py-1 rounded-md hover:bg-blue-200 text-sm font-medium disabled:opacity-50"
                >
                  PIN speichern
                </button>
              </div>
              <div class="mt-1 text-xs text-gray-500">
                {{ storedPins[m.id] ? "PIN gesetzt" : "kein PIN" }}
              </div>
            </td>
            <td class="px-4 py-2 text-center">
              <input
                type="checkbox"
                v-model="m.active"
                class="scale-125 accent-primary"
              />
            </td>
            <td class="px-4 py-2 text-center space-x-2">
              <button
                @click="save(m)"
                class="bg-primary/10 text-primary px-3 py-1 rounded-md hover:bg-primary/20 text-sm font-medium"
              >
                💾 Speichern
              </button>
              <button
                @click="openCreditModal(m)"
                class="bg-green-100 text-green-700 px-3 py-1 rounded-md hover:bg-green-200 text-sm font-medium"
              >
                ➕ Guthaben
              </button>
              <button
                @click="archiveMember(m)"
                class="bg-amber-100 text-amber-800 px-3 py-1 rounded-md hover:bg-amber-200 text-sm font-medium"
              >
                🗄️ Archivieren
              </button>
            </td>
          </tr>
          <tr v-if="filteredMembers.length === 0">
            <td colspan="6" class="text-center py-6 text-gray-400 italic">
              Keine Mitglieder für den gewählten Filter
            </td>
          </tr>
        </tbody>
      </table>
      </div>
    </div>

    <!-- Neues Mitglied Modal -->
    <BaseModal
      :show="showNewMemberModal"
      title="Neues Mitglied anlegen"
      @close="showNewMemberModal = false"
      @confirm="confirmAddMember"
    >
      <div class="space-y-3">
        <label class="block text-sm font-medium text-gray-600">Vorname</label>
        <input
          v-model="newFirstname"
          type="text"
          class="w-full border rounded-md p-2 text-sm focus:ring-1 focus:ring-primary"
          placeholder="Vorname"
        />

        <label class="block text-sm font-medium text-gray-600">Nachname</label>
        <input
          v-model="newLastname"
          type="text"
          class="w-full border rounded-md p-2 text-sm focus:ring-1 focus:ring-primary"
          placeholder="Nachname"
        />
      </div>
    </BaseModal>

    <BaseModal
      :show="showArchivedCandidateModal"
      title="Archivierte Treffer gefunden"
      confirmLabel="Trotzdem neu anlegen"
      cancelLabel="Zurück"
      @close="showArchivedCandidateModal = false"
      @confirm="createDespiteArchivedCandidates"
    >
      <div class="space-y-4">
        <p>
          Es gibt archivierte Mitglieder mit diesem Namen. Wähle ein Mitglied zum Reaktivieren
          oder lege bewusst ein neues Mitglied an.
        </p>
        <div class="space-y-2 max-h-72 overflow-y-auto">
          <div
            v-for="m in archivedCandidates"
            :key="m.id"
            class="border rounded-lg p-3 space-y-2"
          >
            <div class="font-semibold text-gray-900">
              {{ m.firstname }} {{ m.lastname }}
            </div>
            <div class="text-xs text-gray-500 space-y-1">
              <div>Archiviert: {{ formatDateTime(m.archived_at) }}</div>
              <div>Letzte Buchung: {{ formatDateTime(m.last_booking_at) }}</div>
              <div>Saldo: {{ formatEuro(m.balance) }}</div>
            </div>
            <button
              @click="reactivateArchivedMember(m)"
              class="w-full bg-primary/10 text-primary px-3 py-2 rounded-md hover:bg-primary/20 text-sm font-medium"
            >
              Dieses Mitglied reaktivieren
            </button>
          </div>
        </div>
        <div v-if="creatingNewDespiteCandidates" class="text-xs text-gray-500">
          Mitglied wird angelegt...
        </div>
      </div>
    </BaseModal>

    <!-- Guthaben Modal -->
    <BaseModal
      :show="showCreditModal"
      title="Guthabenbuchung"
      @close="closeCreditModal"
      @confirm="confirmCredit"
    >
      <div class="space-y-3">
        <p class="text-gray-600">
          Guthaben für:
          <span class="font-semibold">
            {{ modalMember?.firstname }} {{ modalMember?.lastname }}
          </span>
        </p>

        <label class="block text-sm font-medium text-gray-600"
          >Betrag (€)</label
        >
        <input
          v-model.number="modalAmount"
          type="number"
          step="0.01"
          min="0"
          placeholder="z. B. 10.00"
          class="w-full border rounded-md p-2 text-sm focus:ring-1 focus:ring-primary"
        />

        <label class="block text-sm font-medium text-gray-600"
          >Kommentar (optional)</label
        >
        <textarea
          v-model="modalComment"
          rows="3"
          placeholder="z. B. Rückzahlung oder Ausgleich"
          class="w-full border rounded-md p-2 text-sm focus:ring-1 focus:ring-primary"
        ></textarea>
      </div>
    </BaseModal>
  </div>
</template>
