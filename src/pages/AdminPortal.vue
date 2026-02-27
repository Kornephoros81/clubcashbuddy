<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useRouter } from "vue-router";
import { useAppAuthStore } from "@/stores/useAppAuthStore";
import { useBranding } from "@/composables/useBranding";

const router = useRouter();
const authStore = useAppAuthStore();
const loading = ref(false);
const showReports = ref(false);
const showAdmin = ref(false);
const { appTitle, logoUrl, loadBrandingAdmin } = useBranding();

function onLogoError(event: Event) {
  const target = event.target as HTMLImageElement | null;
  if (target) target.src = "/icons/icon-192.png";
}

function toggleAdminMenu() {
  const next = !showAdmin.value;
  showAdmin.value = next;
  if (next) showReports.value = false;
}

function toggleReportsMenu() {
  const next = !showReports.value;
  showReports.value = next;
  if (next) showAdmin.value = false;
}

async function logout() {
  loading.value = true;
  await authStore.logoutAdmin();
  router.push("/");
}

onMounted(async () => {
  try {
    await loadBrandingAdmin();
  } catch (err) {
    console.error("[AdminPortal.branding]", err);
  }
});
</script>

<template>
  <div class="min-h-screen bg-gray-50 flex flex-col">
    <!-- Navbar -->
    <header
      class="bg-primary text-white shadow-md px-6 py-3 flex justify-between items-center relative"
    >
      <h1 class="text-xl font-semibold flex items-center gap-2">
        <img
          :src="logoUrl"
          :alt="`${appTitle} Logo`"
          class="h-8 w-8 object-contain"
          @error="onLogoError"
        />
        <span>{{ appTitle }} – Adminportal</span>
      </h1>

      <nav class="flex gap-6 text-sm items-center relative">
        <!-- 🏠 Dashboard -->
        <RouterLink to="/admin/dashboard" class="hover:underline">
          Dashboard
        </RouterLink>

        <!-- 📁 Verwaltung Dropdown -->
        <div class="relative">
          <button
            @click="toggleAdminMenu"
            class="hover:underline flex items-center gap-1"
          >
            ⚙️ Verwaltung
            <span class="text-xs" :class="{ 'rotate-180': showAdmin }">▼</span>
          </button>
          <div
            v-if="showAdmin"
            class="absolute right-0 mt-2 w-56 bg-white text-gray-800 rounded-md shadow-lg border border-gray-200 z-50"
            @mouseleave="showAdmin = false"
          >
            <RouterLink
              to="/admin/members"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showAdmin = false"
              >👥 Mitglieder</RouterLink
            >
            <RouterLink
              to="/admin/products"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showAdmin = false"
              >🧃 Artikel</RouterLink
            >
            <RouterLink
              to="/admin/storage"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showAdmin = false"
            >
              📦 Lagerverwaltung
            </RouterLink>
            <RouterLink
              to="/admin/bookings-report"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showAdmin = false"
            >
              🧾 Buchungsübersicht
            </RouterLink>
            <RouterLink
              to="/admin/branding"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showAdmin = false"
            >
              🏷️ Branding
            </RouterLink>
            <RouterLink
              to="/admin/users"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showAdmin = false"
            >
              👤 Admin-Benutzer
            </RouterLink>
            <RouterLink
              to="/admin/device-pairing"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showAdmin = false"
            >
              🔐 Geräte koppeln
            </RouterLink>
          </div>
        </div>

        <!-- 📊 Berichte Dropdown -->
        <div class="relative">
          <button
            @click="toggleReportsMenu"
            class="hover:underline flex items-center gap-1"
          >
            📊 Berichte
            <span class="text-xs" :class="{ 'rotate-180': showReports }"
              >▼</span
            >
          </button>
          <div
            v-if="showReports"
            class="absolute right-0 mt-2 w-56 bg-white text-gray-800 rounded-md shadow-lg border border-gray-200 z-50"
            @mouseleave="showReports = false"
          >
            <RouterLink
              to="/admin/inventory-report"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showReports = false"
              >📦 Inventurabgleich</RouterLink
            >
            <RouterLink
              to="/admin/stock-adjustments-report"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showReports = false"
              >📉 Fehlbestände & Anpassungen</RouterLink
            >
            <RouterLink
              to="/admin/fridge-refills-report"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showReports = false"
              >🧊 Kühlschrank-Auffüllungen</RouterLink
            >
            <RouterLink
              to="/admin/cancellations-report"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showReports = false"
              >↩️ Storno-Report</RouterLink
            >
            <RouterLink
              to="/admin/revenue-report"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showReports = false"
              >💶 Umsatzreport</RouterLink
            >
            <RouterLink
              to="/admin/settlements-report"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showReports = false"
              >📒 Abrechnungsprotokoll</RouterLink
            >
            <RouterLink
              to="/admin/settlement"
              class="block px-4 py-2 hover:bg-gray-100"
              @click="showReports = false"
              >📘 Monatsabschluss</RouterLink
            >
          </div>
        </div>

        <!-- 🔄 Terminal -->
        <RouterLink
          to="/"
          class="ml-2 bg-white/20 px-3 py-1 rounded hover:bg-white/30 transition"
        >
          🏠 Terminal
        </RouterLink>

        <!-- 🚪 Logout -->
        <button
          @click="logout"
          class="bg-white/20 px-3 py-1 rounded hover:bg-white/30 transition"
          :disabled="loading"
        >
          {{ loading ? "…" : "Abmelden" }}
        </button>
      </nav>
    </header>

    <!-- Seiteninhalt -->
    <main class="flex-1 p-6">
      <RouterView />
    </main>
  </div>
</template>

<style scoped>
nav a.router-link-exact-active {
  text-decoration: underline;
  font-weight: 600;
}
button span {
  transition: transform 0.2s ease;
}
button span.rotate-180 {
  transform: rotate(180deg);
}
</style>
