<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useRouter } from "vue-router";
import { supabase } from "@/supabase";

const router = useRouter();

const loading = ref(false);
const errorMsg = ref("");
const successMsg = ref("");
const recoveryReady = ref(false);

const newPassword = ref("");
const confirmPassword = ref("");

onMounted(async () => {
  try {
    const url = new URL(window.location.href);
    const code = url.searchParams.get("code");
    const type = url.searchParams.get("type");
    const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    const accessToken = hashParams.get("access_token");
    const refreshToken = hashParams.get("refresh_token");

    // Supabase Recovery-Link (PKCE): ?code=...&type=recovery
    if (code && type === "recovery") {
      const { error } = await supabase.auth.exchangeCodeForSession(code);
      if (error) {
        errorMsg.value = "Reset-Link ungültig oder abgelaufen.";
        return;
      }
    }

    // Legacy/Hash-Link: #access_token=...&refresh_token=...
    if (accessToken && refreshToken) {
      const { error } = await supabase.auth.setSession({
        access_token: accessToken,
        refresh_token: refreshToken,
      });
      if (error) {
        errorMsg.value = "Reset-Link ungültig oder abgelaufen.";
        return;
      }
    }

    const { data } = await supabase.auth.getSession();
    if (!data.session) {
      errorMsg.value =
        "Keine Recovery-Session gefunden. Bitte neuen Reset-Link anfordern.";
      return;
    }

    recoveryReady.value = true;
  } catch (err: any) {
    errorMsg.value = "Fehler beim Verarbeiten des Reset-Links.";
    console.error("[ResetPassword]", err);
  }
});


async function updatePassword() {
  if (!recoveryReady.value) {
    errorMsg.value = "Recovery-Session fehlt. Bitte neuen Reset-Link anfordern.";
    return;
  }
  if (!newPassword.value || newPassword.value.length < 6) {
    errorMsg.value = "Das Passwort muss mindestens 6 Zeichen lang sein.";
    return;
  }
  if (newPassword.value !== confirmPassword.value) {
    errorMsg.value = "Die Passwörter stimmen nicht überein.";
    return;
  }

  loading.value = true;
  errorMsg.value = "";
  successMsg.value = "";

  try {
    const { error } = await supabase.auth.updateUser({
      password: newPassword.value,
    });

    if (error) {
      errorMsg.value = "Fehler beim Ändern des Passworts: " + error.message;
    } else {
      successMsg.value = "✅ Passwort erfolgreich geändert!";
      setTimeout(() => router.push("/login"), 1200);
    }
  } catch (err: any) {
    errorMsg.value = "Unerwarteter Fehler: " + err.message;
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <div
    class="min-h-screen flex flex-col items-center justify-center bg-gray-100 text-gray-800 p-6"
  >
    <div class="w-full max-w-md bg-white rounded-2xl shadow-lg p-8 space-y-4">
      <h1 class="text-2xl font-bold text-center text-primary">
        🔒 Passwort zurücksetzen
      </h1>

      <p class="text-center text-gray-500 text-sm">
        Bitte gib dein neues Passwort ein und bestätige es.
      </p>

      <div class="space-y-3">
        <input
          v-model="newPassword"
          type="password"
          placeholder="Neues Passwort"
          class="w-full p-3 border rounded-lg focus:ring-2 focus:ring-primary focus:outline-none"
          :class="{ 'border-red-500': errorMsg.includes('mindestens') }"
        />

        <input
          v-model="confirmPassword"
          type="password"
          placeholder="Passwort bestätigen"
          class="w-full p-3 border rounded-lg focus:ring-2 focus:ring-primary focus:outline-none"
          :class="{ 'border-red-500': errorMsg.includes('überein') }"
        />
      </div>

      <button
        @click="updatePassword"
        :disabled="loading || !recoveryReady"
        class="w-full bg-primary text-white font-semibold py-3 rounded-lg hover:bg-primary/90 transition disabled:opacity-50"
      >
        {{ loading ? "Speichere …" : "Passwort ändern" }}
      </button>

      <p v-if="errorMsg" class="text-red-600 text-sm text-center">
        {{ errorMsg }}
      </p>
      <p v-if="successMsg" class="text-green-600 text-sm text-center">
        {{ successMsg }}
      </p>
    </div>
  </div>
</template>

<style scoped>
.text-primary {
  @apply text-green-700;
}
.bg-primary {
  @apply bg-green-600;
}
</style>
