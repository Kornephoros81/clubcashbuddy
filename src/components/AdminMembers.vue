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
const selectedMember = ref<any | null>(null);
type DetailTab = "details" | "pin" | "credit" | "archive";
const detailTab = ref<DetailTab>("details");
const detailDraft = ref({
  firstname: "",
  lastname: "",
  active: false,
});
const detailSaving = ref(false);
const creditSaving = ref(false);
const creditAmount = ref<number>(0);
const creditComment = ref("");

const detailTabs = [
  { id: "details", label: "Stammdaten" },
  { id: "pin", label: "PIN" },
  { id: "credit", label: "Guthaben" },
  { id: "archive", label: "Archiv" },
] as const;

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

function memberName(member: any) {
  return `${member?.firstname ?? ""} ${member?.lastname ?? ""}`.trim();
}

function memberStatus(member: any) {
  return member?.active ? "Aktiv" : "Inaktiv";
}

const filteredMembers = computed(() => {
  const query = searchTerm.value.trim().toLocaleLowerCase("de-DE");
  return store.members.filter((member) => {
    const fullName = memberName(member).toLocaleLowerCase("de-DE");
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
    if (selectedMember.value?.id) {
      const fresh = store.members.find((m) => m.id === selectedMember.value.id);
      if (fresh) {
        openMemberDetails(fresh, detailTab.value);
      } else {
        closeMemberDetails();
      }
    }
  } catch (err) {
    console.error("[queue-synced][members]", err);
  }
}

function onPinInput(memberId: string, event: Event) {
  const target = event.target as HTMLInputElement | null;
  pinDrafts.value[memberId] = normalizePin(target?.value ?? "");
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
      showToast(`✅ PIN für ${memberName(member)} entfernt`);
      return;
    }

    await adminRpc("upsert_member_pin", {
      member_id: member.id,
      pin_plain: pin,
    });

    storedPins.value[member.id] = pin;
    pinDrafts.value[member.id] = pin;
    showToast(`✅ PIN für ${memberName(member)} gespeichert`);
  } catch (err) {
    console.error("[savePin]", err);
    showToast("⚠️ Fehler beim Speichern der PIN");
  } finally {
    pinSaving.value[member.id] = false;
  }
}

function openMemberDetails(member: any, tab: DetailTab = "details") {
  selectedMember.value = { ...member };
  detailDraft.value = {
    firstname: member.firstname ?? "",
    lastname: member.lastname ?? "",
    active: Boolean(member.active),
  };
  detailTab.value = tab;
  creditAmount.value = 0;
  creditComment.value = "";
  if (!(member.id in pinDrafts.value)) {
    pinDrafts.value[member.id] = storedPins.value[member.id] ?? "";
  }
}

function closeMemberDetails() {
  selectedMember.value = null;
  detailTab.value = "details";
  creditAmount.value = 0;
  creditComment.value = "";
}

async function saveSelectedMember() {
  const m = selectedMember.value;
  if (!m) return;
  if (!detailDraft.value.firstname.trim() || !detailDraft.value.lastname.trim()) {
    showToast("⚠️ Vor- und Nachname sind erforderlich");
    return;
  }

  detailSaving.value = true;
  try {
    const updated = await store.updateMember({
      ...m,
      firstname: detailDraft.value.firstname,
      lastname: detailDraft.value.lastname,
      active: detailDraft.value.active,
    });
    selectedMember.value = { ...updated };
    detailDraft.value = {
      firstname: updated.firstname ?? "",
      lastname: updated.lastname ?? "",
      active: Boolean(updated.active),
    };
    showToast(`💾 Änderungen für ${memberName(updated)} gespeichert`);
  } catch (err) {
    console.error("[saveSelectedMember]", err);
    showToast("⚠️ Fehler beim Speichern");
  } finally {
    detailSaving.value = false;
  }
}

async function bookSelectedCredit() {
  const m = selectedMember.value;
  if (!m || creditAmount.value <= 0) {
    showToast("⚠️ Bitte Betrag in € eingeben");
    return;
  }

  creditSaving.value = true;
  const cents = Math.round(creditAmount.value * 100);
  const amountLabel = creditAmount.value.toFixed(2);
  try {
    const authStore = useAppAuthStore();
    const adminName = authStore.adminUser || "Unbekannt";
    const timestamp = new Date().toLocaleString("sv-SE").replace("T", " ");
    const note =
      creditComment.value.trim().length > 0
        ? creditComment.value.trim()
        : `Admin-Guthabenbuchung ${adminName} ${timestamp}`;

    await adminRpc("book_free_amount", {
      member_id: m.id,
      amount_cents: cents,
      note,
    });

    await store.loadMembers();
    const updated = store.members.find((member) => member.id === m.id);
    if (updated) openMemberDetails(updated, "credit");

    showToast(`💶 ${amountLabel} € für ${memberName(m)} gebucht`);
    creditAmount.value = 0;
    creditComment.value = "";
  } catch (err) {
    console.error("[bookSelectedCredit]", err);
    showToast("⚠️ Fehler bei der Guthabenbuchung");
  } finally {
    creditSaving.value = false;
  }
}

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
      showNewMemberModal.value = false;
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
    const restored = await store.restoreArchivedMember(member.id);
    await loadMemberPins();
    showToast(`✅ ${memberName(restored)} reaktiviert`);
    newFirstname.value = "";
    newLastname.value = "";
    showNewMemberModal.value = false;
    showArchivedCandidateModal.value = false;
    archivedCandidates.value = [];
    openMemberDetails(restored);
  } catch (err) {
    console.error("[reactivateArchivedMember]", err);
    showToast("⚠️ Fehler beim Reaktivieren des Mitglieds");
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

async function archiveMember(member: any) {
  const ok = await confirm(
    "Mitglied archivieren",
    `Soll das Mitglied "${memberName(member)}" archiviert werden? Es verschwindet aus der normalen Mitgliederliste, bleibt aber in Berichten erhalten.`,
    { danger: true }
  );
  if (!ok) return false;

  try {
    await store.archiveMember(member.id);
    showToast(`🗄️ ${memberName(member)} archiviert`);
    return true;
  } catch (err) {
    console.error("[archiveMember]", err);
    showToast(`⚠️ ${archiveErrorMessage(err)}`);
    return false;
  }
}

async function archiveSelectedMember() {
  const m = selectedMember.value;
  if (!m) return;
  const archived = await archiveMember(m);
  if (archived) closeMemberDetails();
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
    `Soll "${memberName(member)}" wieder in die Mitgliederliste aufgenommen werden? Das Mitglied bleibt danach zunächst inaktiv.`,
    { danger: false }
  );
  if (!ok) return;

  try {
    const restored = await store.restoreArchivedMember(member.id);
    await loadMemberPins();
    showToast(`✅ ${memberName(restored)} wiederhergestellt`);
    openMemberDetails(restored);
  } catch (err) {
    console.error("[restoreArchivedMember]", err);
    showToast("⚠️ Fehler beim Wiederherstellen des Mitglieds");
  }
}
</script>

<template>
  <div class="space-y-6">
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
              <td class="px-3 py-2 font-medium">{{ memberName(m) }}</td>
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

    <div v-if="store.loading" class="text-center py-10 text-gray-500">
      ⏳ Mitglieder werden geladen...
    </div>

    <div v-else class="space-y-4">
      <div class="lg:hidden space-y-3">
        <div
          v-for="m in filteredMembers"
          :key="m.id"
          class="bg-white rounded-2xl shadow border border-gray-200 p-4"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="text-base font-semibold text-gray-900 truncate">
                {{ memberName(m) }}
              </div>
              <div
                class="text-sm font-mono mt-1"
                :class="m.balance < 0 ? 'text-red-600' : 'text-green-700'"
              >
                {{ formatEuro(m.balance) }}
              </div>
              <div class="mt-2 flex items-center gap-2 text-xs text-gray-500">
                <span
                  class="inline-flex rounded-full px-2 py-0.5 font-medium"
                  :class="m.active ? 'bg-green-50 text-green-700' : 'bg-gray-100 text-gray-600'"
                >
                  {{ memberStatus(m) }}
                </span>
                <span>{{ storedPins[m.id] ? "PIN gesetzt" : "kein PIN" }}</span>
              </div>
            </div>
            <button
              @click="openMemberDetails(m)"
              class="bg-primary/10 text-primary px-3 py-2 rounded-md hover:bg-primary/20 text-sm font-medium"
            >
              Bearbeiten
            </button>
          </div>
        </div>
      </div>

      <div
        class="hidden lg:block bg-white rounded-2xl shadow overflow-x-auto border border-gray-200"
      >
        <table class="min-w-full text-sm text-gray-700">
          <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
            <tr>
              <th class="px-4 py-3 text-left">Name</th>
              <th class="px-4 py-3 text-right">Saldo</th>
              <th class="px-4 py-3 text-left">PIN</th>
              <th class="px-4 py-3 text-center">Status</th>
              <th class="px-4 py-3 text-center">Aktion</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="m in filteredMembers"
              :key="m.id"
              class="border-t hover:bg-primary/5 transition-colors"
            >
              <td class="px-4 py-3 font-medium text-gray-900">
                {{ memberName(m) }}
              </td>
              <td
                class="px-4 py-3 text-right font-mono"
                :class="m.balance < 0 ? 'text-red-600' : 'text-green-700'"
              >
                {{ formatEuro(m.balance) }}
              </td>
              <td class="px-4 py-3 text-gray-500">
                {{ storedPins[m.id] ? "gesetzt" : "kein PIN" }}
              </td>
              <td class="px-4 py-3 text-center">
                <span
                  class="inline-flex rounded-full px-2.5 py-1 text-xs font-medium"
                  :class="m.active ? 'bg-green-50 text-green-700' : 'bg-gray-100 text-gray-600'"
                >
                  {{ memberStatus(m) }}
                </span>
              </td>
              <td class="px-4 py-3 text-center">
                <button
                  @click="openMemberDetails(m)"
                  class="bg-primary/10 text-primary px-3 py-1 rounded-md hover:bg-primary/20 text-sm font-medium"
                >
                  Bearbeiten
                </button>
              </td>
            </tr>
            <tr v-if="filteredMembers.length === 0">
              <td colspan="5" class="text-center py-6 text-gray-400 italic">
                Keine Mitglieder für den gewählten Filter
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <div
      v-if="selectedMember"
      class="fixed inset-0 z-50 bg-black/40"
      @click.self="closeMemberDetails"
    >
      <aside
        class="ml-auto flex h-full w-full max-w-2xl flex-col bg-white shadow-2xl"
      >
        <div class="border-b border-gray-200 p-4 sm:p-5">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <h3 class="text-lg font-semibold text-gray-900 truncate">
                {{ memberName(selectedMember) }}
              </h3>
              <div class="mt-1 flex flex-wrap items-center gap-2 text-sm text-gray-500">
                <span>{{ formatEuro(selectedMember.balance) }}</span>
                <span
                  class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium"
                  :class="selectedMember.active ? 'bg-green-50 text-green-700' : 'bg-gray-100 text-gray-600'"
                >
                  {{ memberStatus(selectedMember) }}
                </span>
              </div>
            </div>
            <button
              @click="closeMemberDetails"
              class="rounded-md px-3 py-2 text-sm text-gray-500 hover:bg-gray-100"
              title="Schließen"
            >
              Schließen
            </button>
          </div>

          <div class="mt-4 grid grid-cols-2 sm:grid-cols-4 gap-2">
            <button
              v-for="tab in detailTabs"
              :key="tab.id"
              @click="detailTab = tab.id"
              class="rounded-md px-3 py-2 text-sm font-medium border"
              :class="
                detailTab === tab.id
                  ? 'bg-primary text-white border-primary'
                  : 'bg-white text-gray-700 border-gray-200 hover:bg-gray-50'
              "
            >
              {{ tab.label }}
            </button>
          </div>
        </div>

        <div class="flex-1 overflow-y-auto p-4 sm:p-5">
          <div v-if="detailTab === 'details'" class="space-y-5">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Vorname</label>
                <input
                  v-model="detailDraft.firstname"
                  class="w-full border rounded-md px-3 py-2 text-sm"
                />
              </div>
              <div>
                <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Nachname</label>
                <input
                  v-model="detailDraft.lastname"
                  class="w-full border rounded-md px-3 py-2 text-sm"
                />
              </div>
            </div>

            <label class="inline-flex items-center gap-3 text-sm text-gray-700">
              <input
                type="checkbox"
                v-model="detailDraft.active"
                class="scale-125 accent-primary"
              />
              Mitglied ist aktiv
            </label>

            <div class="flex justify-end">
              <button
                @click="saveSelectedMember"
                :disabled="detailSaving"
                class="bg-primary text-white px-4 py-2 rounded-md hover:bg-primary/90 text-sm font-medium disabled:opacity-50"
              >
                Speichern
              </button>
            </div>
          </div>

          <div v-else-if="detailTab === 'pin'" class="space-y-5">
            <div>
              <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">PIN</label>
              <div class="flex flex-wrap items-center gap-2">
                <input
                  :type="showPinPlain[selectedMember.id] ? 'text' : 'password'"
                  :value="pinDrafts[selectedMember.id] ?? ''"
                  maxlength="4"
                  class="w-28 border rounded-md px-3 py-2 text-sm"
                  placeholder="----"
                  @input="onPinInput(selectedMember.id, $event)"
                />
                <button
                  @click="togglePin(selectedMember.id)"
                  class="bg-gray-100 text-gray-700 px-3 py-2 rounded-md hover:bg-gray-200 text-sm"
                  title="PIN anzeigen/verstecken"
                >
                  {{ showPinPlain[selectedMember.id] ? "🙈" : "👁️" }}
                </button>
                <button
                  @click="savePin(selectedMember)"
                  :disabled="pinSaving[selectedMember.id]"
                  class="bg-primary/10 text-primary px-3 py-2 rounded-md hover:bg-primary/20 text-sm font-medium disabled:opacity-50"
                >
                  PIN speichern
                </button>
              </div>
              <div class="mt-2 text-xs text-gray-500">
                {{ storedPins[selectedMember.id] ? "PIN gesetzt" : "kein PIN" }}
              </div>
            </div>
          </div>

          <div v-else-if="detailTab === 'credit'" class="space-y-5">
            <div>
              <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Betrag (€)</label>
              <input
                v-model.number="creditAmount"
                type="number"
                step="0.01"
                min="0"
                placeholder="z. B. 10.00"
                class="w-full border rounded-md px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label class="block text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">Kommentar</label>
              <textarea
                v-model="creditComment"
                rows="4"
                placeholder="z. B. Rückzahlung oder Ausgleich"
                class="w-full border rounded-md px-3 py-2 text-sm"
              ></textarea>
            </div>
            <div class="flex justify-end">
              <button
                @click="bookSelectedCredit"
                :disabled="creditSaving"
                class="bg-green-600 text-white px-4 py-2 rounded-md hover:bg-green-700 text-sm font-medium disabled:opacity-50"
              >
                Guthaben buchen
              </button>
            </div>
          </div>

          <div v-else class="space-y-5">
            <div class="rounded-md border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
              Archivierte Mitglieder verschwinden aus der normalen Mitgliederliste und aus dem Terminal.
              Buchungen und Berichte bleiben erhalten. Archivieren ist nur bei Saldo 0 und ohne offene Buchungen möglich.
            </div>
            <div class="flex justify-end">
              <button
                @click="archiveSelectedMember"
                class="bg-amber-100 text-amber-800 px-4 py-2 rounded-md hover:bg-amber-200 text-sm font-medium"
              >
                Mitglied archivieren
              </button>
            </div>
          </div>
        </div>
      </aside>
    </div>

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
              {{ memberName(m) }}
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
  </div>
</template>
