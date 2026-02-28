<template>
  <div class="min-h-screen flex flex-col items-center justify-center bg-gray-50">
    <div class="bg-white shadow-xl rounded-2xl p-8 w-full max-w-md">
      <h1 class="text-3xl font-bold text-center text-primary mb-6">
        🔑 Admin Login
      </h1>

      <form @submit.prevent="login" class="space-y-4">
        <div>
          <label for="email" class="block text-gray-700 mb-1">Benutzername</label>
          <input
            id="email"
            v-model="email"
            type="text"
            required
            placeholder="admin"
            class="w-full border border-gray-300 rounded-lg px-3 py-2 focus:ring-2 focus:ring-primary focus:outline-none"
          />
        </div>

        <div>
          <label for="password" class="block text-gray-700 mb-1">Passwort</label>
          <input
            id="password"
            v-model="password"
            type="password"
            required
            placeholder="••••••••"
            class="w-full border border-gray-300 rounded-lg px-3 py-2 focus:ring-2 focus:ring-primary focus:outline-none"
          />
        </div>

        <button
          type="submit"
          class="w-full bg-primary hover:bg-primary/90 text-white font-semibold py-2 rounded-lg transition"
          :disabled="loading"
        >
          <span v-if="!loading">Anmelden</span>
          <span v-else>⏳ Bitte warten...</span>
        </button>
      </form>

      <p v-if="error" class="text-red-600 text-center mt-4">{{ error }}</p>

      <!-- 🏠 Zurück-Link -->
      <div class="text-center mt-6">
        <RouterLink
          to="/terminal"
          class="text-sm text-gray-500 hover:text-primary underline"
        >
          ← Zurück zum Terminal
        </RouterLink>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useAppAuthStore } from "@/stores/useAppAuthStore";

const email = ref("");
const password = ref("");
const loading = ref(false);
const error = ref<string | null>(null);

const router = useRouter();
const route = useRoute();
const authStore = useAppAuthStore();

function getPostLoginRedirect() {
  const rawRedirect = route.query.redirect;
  const redirect = Array.isArray(rawRedirect) ? rawRedirect[0] : rawRedirect;

  if (typeof redirect === "string" && redirect.startsWith("/admin/")) {
    return redirect;
  }
  return "/admin/dashboard";
}

async function login() {
  error.value = null;
  loading.value = true;
  try {
    await authStore.loginAdmin(email.value.trim(), password.value);
    await router.push(getPostLoginRedirect());
  } catch (e: any) {
    error.value = "❌ " + (e?.message || "Login fehlgeschlagen");
  } finally {
    loading.value = false;
  }
}
</script>

<style scoped>
.text-primary {
  color: #2563eb; /* Tailwind blue-600 */
}
.bg-primary {
  background-color: #2563eb;
}
</style>
