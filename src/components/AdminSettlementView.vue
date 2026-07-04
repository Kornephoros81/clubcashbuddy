<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useToast } from "@/composables/useToast";
import BaseModal from "@/components/BaseModal.vue";
import { adminRpc } from "@/lib/adminApi";

const { show: showToast } = useToast();
const loading = ref(false);
const members = ref<any[]>([]);
const showConfirmModal = ref(false);
const settlementTarget = ref<any | null>(null);
const settlingMemberId = ref<string | null>(null);

// 🧾 Mitglieder laden
async function loadMembers() {
  loading.value = true;
  try {
    const rows = await adminRpc("list_members_balances");

    members.value = ((rows as any[]) ?? []).map((m) => ({
      ...m,
      name: `${m.lastname ?? ""}, ${m.firstname ?? ""}`
        .trim()
        .replace(/^,|,$/g, ""),
    }));
  } catch (err) {
    console.error(err);
    showToast("⚠️ Fehler beim Laden der Mitglieder");
  } finally {
    loading.value = false;
  }
}

function openSettlementConfirm(member: any | null = null) {
  settlementTarget.value = member;
  showConfirmModal.value = true;
}

// 🔄 Monatsabschluss ausführen
async function performSettlement() {
  const target = settlementTarget.value;
  showConfirmModal.value = false;
  if (target?.id) {
    settlingMemberId.value = target.id;
  } else {
    loading.value = true;
  }
  try {
    if (target?.id) {
      await adminRpc("perform_member_settlement", { member_id: target.id });
    } else {
      await adminRpc("perform_monthly_settlement");
    }

    showToast(
      target?.id
        ? `✅ ${target.name} erfolgreich abgerechnet`
        : "✅ Monatsabschluss erfolgreich durchgeführt"
    );
    await loadMembers();
  } catch (err) {
    console.error(err);
    showToast("⚠️ Fehler beim Monatsabschluss");
  } finally {
    loading.value = false;
    settlingMemberId.value = null;
    settlementTarget.value = null;
  }
}

// 💾 CSV Export (Clientseitig)
function exportCsv() {
  if (!members.value.length) {
    showToast("ℹ️ Keine Daten zum Exportieren");
    return;
  }

  const headers = ["Nachname", "Vorname", "Saldo (€)"];
  const rows = members.value.map((m) => [
    m.lastname ?? "",
    m.firstname ?? "",
    (m.balance / 100).toFixed(2).replace(".", ","),
  ]);

  const csvContent = [headers, ...rows].map((r) => r.join(";")).join("\n");

  // 🔧 UTF-8 BOM hinzufügen → Excel erkennt das Encoding korrekt
  const bom = "\uFEFF";
  const blob = new Blob([bom + csvContent], {
    type: "text/csv;charset=utf-8;",
  });

  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  const today = new Date().toISOString().split("T")[0];
  a.href = url;
  a.download = `vereinskasse-monatsabschluss-${today}.csv`;
  a.click();
  URL.revokeObjectURL(url);

  showToast("💾 CSV-Datei wurde heruntergeladen");
}

onMounted(loadMembers);
</script>

<template>
  <div class="space-y-6">
    <!-- Header -->
    <div class="flex justify-between items-center">
      <h2 class="text-xl font-semibold text-primary">📘 Monatsabschluss</h2>
      <div class="flex gap-3">
        <button
          @click="exportCsv"
          class="bg-gray-700 text-white px-4 py-2 rounded-lg shadow hover:bg-gray-600 transition"
          :disabled="loading"
        >
          CSV exportieren
        </button>
        <button
          @click="openSettlementConfirm(null)"
          class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition"
          :disabled="loading"
        >
          Alle abrechnen
        </button>
      </div>
    </div>

    <!-- Ladezustand -->
    <div v-if="loading" class="text-center py-10 text-gray-500">
      ⏳ Daten werden geladen...
    </div>

    <!-- Tabelle -->
    <div
      v-else
      class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200"
    >
      <table class="min-w-full text-sm text-gray-700">
        <thead
          class="bg-primary/10 text-primary uppercase text-xs font-semibold"
        >
          <tr>
            <th class="px-4 py-3 text-left">Mitglied</th>
            <th class="px-4 py-3 text-right">Kontostand (€)</th>
            <th class="px-4 py-3 text-right">Letzte Abrechnung</th>
            <th class="px-4 py-3 text-center">Aktion</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="m in members"
            :key="m.id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">{{ m.name }}</td>

            <!-- 💰 Dynamische Farbe -->
            <td
              class="px-4 py-2 text-right font-mono"
              :class="{
                'text-green-600': m.balance > 0,
                'text-red-600': m.balance < 0,
                'text-gray-700': m.balance === 0,
              }"
            >
              {{ (m.balance / 100).toFixed(2) }}
            </td>

            <td class="px-4 py-2 text-right text-gray-500">
              {{
                m.last_settled_at
                  ? new Date(m.last_settled_at).toLocaleDateString("de-DE")
                  : "—"
              }}
            </td>

            <td class="px-4 py-2 text-center">
              <button
                @click="openSettlementConfirm(m)"
                class="bg-primary/10 text-primary px-3 py-1 rounded-md hover:bg-primary/20 text-sm font-medium disabled:opacity-50"
                :disabled="loading || settlingMemberId === m.id"
              >
                Abrechnen
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- 🧩 Bestätigungs-Modal -->
    <BaseModal
      :show="showConfirmModal"
      :title="settlementTarget ? 'Mitglied abrechnen' : 'Monatsabschluss bestätigen'"
      confirm-label="Abschließen"
      cancel-label="Abbrechen"
      :danger="true"
      @close="showConfirmModal = false"
      @confirm="performSettlement"
    >
      <p v-if="settlementTarget">
        Möchtest du <strong>{{ settlementTarget.name }}</strong> abrechnen?<br />
        Ein negativer Kontostand wird auf <strong>0 €</strong> gesetzt,
        Guthaben bleibt bestehen.
      </p>
      <p v-else>
        Möchtest du wirklich alle Mitglieder abrechnen?<br />
        Negative Kontostände werden auf
        <strong>0 €</strong> gesetzt, Guthaben bleibt bestehen.
      </p>
    </BaseModal>
  </div>
</template>

<style scoped>
table {
  border-collapse: collapse;
}
</style>
