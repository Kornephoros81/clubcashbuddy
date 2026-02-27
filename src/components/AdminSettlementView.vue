<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useToast } from "@/composables/useToast";
import BaseModal from "@/components/BaseModal.vue";
import { adminRpc } from "@/lib/adminApi";

const { show: showToast } = useToast();
const loading = ref(false);
const members = ref<any[]>([]);
const showConfirmModal = ref(false);

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

// 🔄 Monatsabschluss ausführen
async function performSettlement() {
  showConfirmModal.value = false;
  loading.value = true;
  try {
    await adminRpc("perform_monthly_settlement");

    showToast("✅ Monatsabschluss erfolgreich durchgeführt");
    await loadMembers();
  } catch (err) {
    console.error(err);
    showToast("⚠️ Fehler beim Monatsabschluss");
  } finally {
    loading.value = false;
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
          @click="showConfirmModal = true"
          class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition"
          :disabled="loading"
        >
          Monatsabschluss durchführen
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
          </tr>
        </tbody>
      </table>
    </div>

    <!-- 🧩 Bestätigungs-Modal -->
    <BaseModal
      :show="showConfirmModal"
      title="Monatsabschluss bestätigen"
      confirm-label="Abschließen"
      cancel-label="Abbrechen"
      :danger="true"
      @close="showConfirmModal = false"
      @confirm="performSettlement"
    >
      <p>
        Möchtest du wirklich den Monatsabschluss durchführen?<br />
        Alle negativen Kontostände werden auf <strong>0 €</strong> gesetzt 
        (Guthaben bleibt bestehen) und der Abschluss wird gespeichert.
      </p>
    </BaseModal>
  </div>
</template>

<style scoped>
table {
  border-collapse: collapse;
}
</style>
