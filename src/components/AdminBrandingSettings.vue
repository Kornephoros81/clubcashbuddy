<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useToast } from "@/composables/useToast";
import { useBranding } from "@/composables/useBranding";
import { useAppAuthStore } from "@/stores/useAppAuthStore";

const { show: showToast } = useToast();
const { appTitle, logoUrl, loadBrandingAdmin, saveBrandingAdmin, DEFAULT_LOGO_URL } = useBranding();
const auth = useAppAuthStore();

const loading = ref(false);
const saving = ref(false);
const uploading = ref(false);
const formTitle = ref("");
const formLogoUrl = ref("");

function onPreviewLogoError(event: Event) {
  const target = event.target as HTMLImageElement | null;
  if (target) target.src = DEFAULT_LOGO_URL;
}

function syncFormFromState() {
  formTitle.value = appTitle.value;
  formLogoUrl.value = logoUrl.value === DEFAULT_LOGO_URL ? "" : logoUrl.value;
}

async function fileToDataUrl(file: File): Promise<string> {
  return await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error("Datei konnte nicht gelesen werden"));
    reader.onload = () => {
      const result = String(reader.result || "");
      if (!result.startsWith("data:image/")) {
        reject(new Error("Nur Bilddateien sind erlaubt"));
        return;
      }
      resolve(result);
    };
    reader.readAsDataURL(file);
  });
}

async function loadSettings() {
  loading.value = true;
  try {
    await loadBrandingAdmin();
    syncFormFromState();
  } catch (err) {
    console.error("[AdminBrandingSettings.load]", err);
    showToast("⚠️ Branding konnte nicht geladen werden");
  } finally {
    loading.value = false;
  }
}

async function saveSettings() {
  saving.value = true;
  try {
    await saveBrandingAdmin({
      app_title: formTitle.value,
      logo_url: formLogoUrl.value.trim(),
    });
    syncFormFromState();
    showToast("✅ Branding gespeichert");
  } catch (err) {
    console.error("[AdminBrandingSettings.save]", err);
    showToast("⚠️ Branding konnte nicht gespeichert werden");
  } finally {
    saving.value = false;
  }
}

async function onLogoFileChange(event: Event) {
  const input = event.target as HTMLInputElement | null;
  const file = input?.files?.[0];
  if (!file) return;

  auth.initFromStorage();
  if (!auth.adminToken) {
    showToast("⚠️ Nicht angemeldet");
    return;
  }

  uploading.value = true;
  try {
    const imageDataUrl = await fileToDataUrl(file);
    const res = await fetch("/api/admin-branding-logo", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${auth.adminToken}`,
      },
      body: JSON.stringify({ image_data_url: imageDataUrl }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error || "Upload fehlgeschlagen");

    const nextLogoUrl = String(body?.data?.logo_url ?? "").trim();
    formLogoUrl.value = nextLogoUrl;
    await saveBrandingAdmin({
      app_title: formTitle.value,
      logo_url: nextLogoUrl,
    });
    syncFormFromState();
    showToast("✅ Logo hochgeladen");
  } catch (err) {
    console.error("[AdminBrandingSettings.uploadLogo]", err);
    showToast("⚠️ Logo-Upload fehlgeschlagen");
  } finally {
    if (input) input.value = "";
    uploading.value = false;
  }
}

async function removeLogo() {
  auth.initFromStorage();
  if (!auth.adminToken) {
    showToast("⚠️ Nicht angemeldet");
    return;
  }

  uploading.value = true;
  try {
    const res = await fetch("/api/admin-branding-logo", {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${auth.adminToken}`,
      },
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error || "Logo konnte nicht entfernt werden");

    formLogoUrl.value = "";
    await saveBrandingAdmin({
      app_title: formTitle.value,
      logo_url: "",
    });
    syncFormFromState();
    showToast("✅ Logo entfernt");
  } catch (err) {
    console.error("[AdminBrandingSettings.removeLogo]", err);
    showToast("⚠️ Logo konnte nicht entfernt werden");
  } finally {
    uploading.value = false;
  }
}

onMounted(loadSettings);
</script>

<template>
  <div class="space-y-6">
    <div class="flex justify-between items-center">
      <h2 class="text-xl font-semibold text-primary">🏷️ Branding</h2>
      <RouterLink
        to="/admin/dashboard"
        class="text-sm text-gray-500 hover:text-primary underline"
      >
        ← Zurück zum Dashboard
      </RouterLink>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-5 space-y-5">
      <div v-if="loading" class="text-sm text-gray-500">Lade Branding…</div>

      <template v-else>
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Überschrift</label>
          <input
            v-model="formTitle"
            type="text"
            class="w-full max-w-xl border rounded-md px-3 py-2 text-sm"
            placeholder="ClubCashBuddy"
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Logo</label>
          <div class="flex flex-wrap items-center gap-3">
            <label
              class="px-3 py-2 rounded-lg border border-gray-300 text-sm text-gray-700 hover:bg-gray-50 transition cursor-pointer"
            >
              {{ uploading ? "Lädt…" : "Logo hochladen" }}
              <input
                type="file"
                accept="image/png,image/jpeg,image/webp,image/gif,image/svg+xml"
                class="hidden"
                :disabled="uploading"
                @change="onLogoFileChange"
              />
            </label>
            <button
              type="button"
              class="px-3 py-2 rounded-lg border border-gray-300 text-sm text-gray-700 hover:bg-gray-50 transition"
              :disabled="uploading"
              @click="removeLogo"
            >
              Logo entfernen
            </button>
          </div>
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Logo-URL (optional)</label>
          <input
            v-model="formLogoUrl"
            type="text"
            class="w-full max-w-xl border rounded-md px-3 py-2 text-sm"
            placeholder="https://…/logo.png"
          />
          <p class="mt-1 text-xs text-gray-500">Kann nach Upload manuell überschrieben werden.</p>
        </div>

        <div class="rounded-xl border border-gray-200 bg-gray-50 p-4">
          <div class="text-xs uppercase text-gray-500 mb-2">Vorschau</div>
          <div class="flex items-center gap-3">
            <img
              :src="formLogoUrl.trim() || DEFAULT_LOGO_URL"
              alt="Logo Vorschau"
              class="h-10 w-10 object-contain rounded bg-white border border-gray-200"
              @error="onPreviewLogoError"
            />
            <div class="text-lg font-semibold text-primary">
              {{ formTitle.trim() || "ClubCashBuddy" }}
            </div>
          </div>
        </div>

        <div class="flex gap-3">
          <button
            @click="saveSettings"
            :disabled="saving"
            class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition disabled:opacity-60"
          >
            {{ saving ? "Speichert…" : "Speichern" }}
          </button>
          <button
            @click="syncFormFromState"
            type="button"
            class="px-4 py-2 rounded-lg border border-gray-300 text-gray-700 hover:bg-gray-50 transition"
          >
            Zurücksetzen
          </button>
        </div>
      </template>
    </div>
  </div>
</template>


