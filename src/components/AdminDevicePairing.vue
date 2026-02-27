<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useToast } from "@/composables/useToast";
import { adminRpc } from "@/lib/adminApi";

type KioskDevice = {
  id: string;
  name: string;
  active: boolean;
  last_seen_at: string | null;
};

const { show: showToast } = useToast();

const loading = ref(false);
const creatingDevice = ref(false);
const creating = ref<Record<string, boolean>>({});
const devices = ref<KioskDevice[]>([]);
const ttlMinutes = ref(5);
const newDeviceName = ref("");
const newDeviceKey = ref("");
const newDeviceActive = ref(true);
const lastPairCode = ref<{
  pairing_code: string;
  expires_at: string;
  device_id: string;
  device_name: string;
} | null>(null);

async function loadDevices() {
  loading.value = true;
  try {
    const data = await adminRpc("list_kiosk_devices");
    devices.value = ((data as any[]) ?? []).map((d: any) => ({
      id: d.id,
      name: String(d.name ?? ""),
      active: Boolean(d.active),
      last_seen_at: d.last_seen_at ?? null,
    }));
  } catch (err) {
    console.error("[AdminDevicePairing.loadDevices]", err);
    showToast("⚠️ Geräte konnten nicht geladen werden");
  } finally {
    loading.value = false;
  }
}

async function createDevice() {
  const name = newDeviceName.value.trim();
  const key = newDeviceKey.value.trim();

  if (!name) {
    showToast("⚠️ Gerätename fehlt");
    return;
  }
  if (key.length < 4) {
    showToast("⚠️ Device Key muss mindestens 4 Zeichen haben");
    return;
  }

  creatingDevice.value = true;
  try {
    const data = await adminRpc("create_kiosk_device", {
      name,
      device_key: key,
      active: newDeviceActive.value,
    });
    const row = Array.isArray(data) ? data[0] : data;
    if (!row?.id) throw new Error("Gerät konnte nicht angelegt werden");

    newDeviceName.value = "";
    newDeviceKey.value = "";
    newDeviceActive.value = true;
    await loadDevices();
    showToast("✅ Gerät angelegt");
  } catch (err: any) {
    console.error("[AdminDevicePairing.createDevice]", err);
    showToast(`⚠️ Gerät anlegen fehlgeschlagen: ${String(err?.message ?? "Unbekannter Fehler")}`);
  } finally {
    creatingDevice.value = false;
  }
}

async function createPairCode(device: KioskDevice) {
  creating.value[device.id] = true;
  try {
    const data = await adminRpc("create_device_pairing_code", {
      device_id: device.id,
      ttl_minutes: ttlMinutes.value,
    });
    const row = Array.isArray(data) ? data[0] : data;
    if (!row?.pairing_code) throw new Error("Kein Pairing-Code zurückgegeben");
    lastPairCode.value = {
      pairing_code: String(row.pairing_code),
      expires_at: String(row.expires_at),
      device_id: String(row.device_id),
      device_name: String(row.device_name),
    };
    showToast("✅ Pairing-Code erstellt");
  } catch (err: any) {
    console.error("[AdminDevicePairing.createPairCode]", err);
    showToast(`⚠️ Pairing-Code fehlgeschlagen: ${String(err?.message ?? "Unbekannter Fehler")}`);
  } finally {
    creating.value[device.id] = false;
  }
}

async function copyPairCode() {
  if (!lastPairCode.value?.pairing_code) return;
  try {
    await navigator.clipboard.writeText(lastPairCode.value.pairing_code);
    showToast("✅ Code kopiert");
  } catch {
    showToast("⚠️ Konnte Code nicht kopieren");
  }
}

onMounted(loadDevices);
</script>

<template>
  <div class="space-y-6">
    <div class="flex justify-between items-center">
      <h2 class="text-xl font-semibold text-primary">🔐 Geräte koppeln</h2>
      <RouterLink to="/admin/dashboard" class="text-sm text-gray-500 hover:text-primary underline">
        ← Zurück zum Dashboard
      </RouterLink>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4 flex items-end gap-4">
      <div>
        <label class="block text-sm font-medium text-gray-600 mb-1">Code gültig (Minuten)</label>
        <input
          v-model.number="ttlMinutes"
          type="number"
          min="1"
          max="60"
          class="border rounded-md px-3 py-2 text-sm w-32"
        />
      </div>
      <button
        @click="loadDevices"
        class="px-4 py-2 rounded-lg border border-gray-300 text-gray-700 hover:bg-gray-50 transition"
      >
        Aktualisieren
      </button>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-4">
      <div class="text-sm font-medium text-gray-700 mb-3">Neues Gerät anlegen</div>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-3 items-end">
        <div class="md:col-span-2">
          <label class="block text-sm font-medium text-gray-600 mb-1">Gerätename</label>
          <input
            v-model.trim="newDeviceName"
            type="text"
            maxlength="120"
            class="w-full border rounded-md px-3 py-2 text-sm"
            placeholder="z. B. Theke links"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-gray-600 mb-1">Device Key</label>
          <input
            v-model.trim="newDeviceKey"
            type="text"
            maxlength="120"
            class="w-full border rounded-md px-3 py-2 text-sm"
            placeholder="mind. 4 Zeichen"
          />
        </div>
        <div class="flex items-center gap-2">
          <input id="new-device-active" v-model="newDeviceActive" type="checkbox" class="h-4 w-4" />
          <label for="new-device-active" class="text-sm text-gray-700">Aktiv</label>
        </div>
      </div>
      <div class="mt-3">
        <button
          @click="createDevice"
          :disabled="creatingDevice"
          class="bg-primary text-white px-4 py-2 rounded-lg hover:bg-primary/90 transition disabled:opacity-60"
        >
          {{ creatingDevice ? "Wird angelegt…" : "Gerät anlegen" }}
        </button>
      </div>
    </div>

    <div v-if="lastPairCode" class="bg-amber-50 border border-amber-200 rounded-2xl p-4">
      <div class="text-sm text-amber-800 font-medium">Aktueller Pairing-Code (einmalig nutzbar)</div>
      <div class="mt-2 flex flex-wrap items-center gap-3">
        <code class="text-2xl tracking-widest font-bold text-amber-900">{{ lastPairCode.pairing_code }}</code>
        <button
          @click="copyPairCode"
          class="px-3 py-1.5 rounded-md border border-amber-300 text-amber-900 hover:bg-amber-100 transition"
        >
          Kopieren
        </button>
      </div>
      <div class="text-xs text-amber-800 mt-2">
        Gerät: {{ lastPairCode.device_name }} · gültig bis:
        {{ new Date(lastPairCode.expires_at).toLocaleString("de-DE") }}
      </div>
    </div>

    <div class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200">
      <table class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Gerät</th>
            <th class="px-4 py-3 text-center">Aktiv</th>
            <th class="px-4 py-3 text-left">Letzte Aktivität</th>
            <th class="px-4 py-3 text-right">Aktion</th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="loading">
            <td colspan="4" class="px-4 py-6 text-center text-gray-500">Lade Geräte…</td>
          </tr>
          <tr
            v-for="device in devices"
            :key="device.id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">{{ device.name }}</td>
            <td class="px-4 py-2 text-center">
              <span
                class="px-2 py-1 rounded-full text-xs font-semibold"
                :class="device.active ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600'"
              >
                {{ device.active ? "Ja" : "Nein" }}
              </span>
            </td>
            <td class="px-4 py-2">
              {{ device.last_seen_at ? new Date(device.last_seen_at).toLocaleString("de-DE") : "-" }}
            </td>
            <td class="px-4 py-2 text-right">
              <button
                @click="createPairCode(device)"
                :disabled="!device.active || !!creating[device.id]"
                class="bg-primary text-white px-3 py-1.5 rounded-md hover:bg-primary/90 transition disabled:opacity-60"
              >
                {{ creating[device.id] ? "…" : "Pairing-Code erstellen" }}
              </button>
            </td>
          </tr>
          <tr v-if="!loading && devices.length === 0">
            <td colspan="4" class="px-4 py-6 text-center text-gray-400 italic">Keine Geräte gefunden</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
