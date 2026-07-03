<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useAppAuthStore } from "@/stores/useAppAuthStore";
import { useBranding } from "@/composables/useBranding";

const router = useRouter();
const route = useRoute();
const authStore = useAppAuthStore();
const loading = ref(false);
const showMasterData = ref(false);
const showActions = ref(false);
const showReports = ref(false);
const showSystem = ref(false);
const showMobileMenu = ref(false);
const { appTitle, logoUrl, loadBrandingAdmin } = useBranding();

const masterDataLinks = [
  { to: "/admin/members", label: "Mitglieder", icon: "👥" },
  { to: "/admin/products", label: "Artikel", icon: "🧃" },
  { to: "/admin/product-categories", label: "Kategorien", icon: "🧩" },
];

const actionLinks = [
  { to: "/admin/storage", label: "Lagerverwaltung", icon: "📦" },
  { to: "/admin/bookings-report", label: "Buchungsübersicht", icon: "🧾" },
  { to: "/admin/inventory-report", label: "Inventurabgleich", icon: "📦" },
  { to: "/admin/settlement", label: "Monatsabschluss", icon: "📘" },
];

const reportLinks = [
  { to: "/admin/stock-adjustments-report", label: "Fehlbestände & Anpassungen", icon: "📉" },
  { to: "/admin/fridge-refills-report", label: "Kühlschrank-Auffüllungen", icon: "🧊" },
  { to: "/admin/cancellations-report", label: "Storno-Report", icon: "↩️" },
  { to: "/admin/revenue-report", label: "Umsatzreport", icon: "💶" },
  { to: "/admin/complimentary-report", label: "Freigetränke", icon: "🎟️" },
  { to: "/admin/settlements-report", label: "Abrechnungsprotokoll", icon: "📒" },
];

const systemLinks = [
  { to: "/admin/branding", label: "Branding", icon: "🏷️" },
  { to: "/admin/users", label: "Admin-Benutzer", icon: "👤" },
  { to: "/admin/device-pairing", label: "Geräte koppeln", icon: "🔐" },
  { to: "/admin/device-sync", label: "Geräte-Sync", icon: "🔁" },
  { to: "/admin/sync-errors", label: "Sync-Fehler", icon: "⚠️" },
  { to: "/admin/sync-queue", label: "Sync-Queue", icon: "🔄" },
  { to: "/admin/performance", label: "Performance", icon: "📈" },
];

const currentSectionLabel = computed(() => {
  const allLinks = [
    { to: "/admin/dashboard", label: "Dashboard" },
    ...masterDataLinks,
    ...actionLinks,
    ...reportLinks,
    ...systemLinks,
  ];
  return allLinks.find((item) => route.path === item.to)?.label ?? "Adminportal";
});

function onLogoError(event: Event) {
  const target = event.target as HTMLImageElement | null;
  if (target) target.src = "/icons/icon-192.png";
}

function closeAllMenus() {
  showMasterData.value = false;
  showActions.value = false;
  showReports.value = false;
  showSystem.value = false;
  showMobileMenu.value = false;
}

function closeSectionMenus() {
  showMasterData.value = false;
  showActions.value = false;
  showReports.value = false;
  showSystem.value = false;
}

function toggleSection(section: "masterData" | "actions" | "reports" | "system") {
  const current =
    section === "masterData"
      ? showMasterData.value
      : section === "actions"
        ? showActions.value
        : section === "reports"
          ? showReports.value
          : showSystem.value;

  closeSectionMenus();

  if (section === "masterData") showMasterData.value = !current;
  else if (section === "actions") showActions.value = !current;
  else if (section === "reports") showReports.value = !current;
  else showSystem.value = !current;
}

function toggleMobileMenu() {
  const next = !showMobileMenu.value;
  showMobileMenu.value = next;
  if (!next) {
    closeSectionMenus();
  }
}

function onMobileSectionToggle(section: "masterData" | "actions" | "reports" | "system") {
  toggleSection(section);
}

async function logout() {
  loading.value = true;
  try {
    await authStore.logoutAdmin();
  } finally {
    loading.value = false;
    router.push("/");
  }
}

watch(
  () => route.fullPath,
  () => {
    closeAllMenus();
  }
);

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
      class="bg-primary text-white shadow-md relative"
    >
      <div class="px-4 sm:px-6 py-3 flex items-center justify-between gap-4">
        <div class="min-w-0">
          <h1 class="text-lg sm:text-xl font-semibold flex items-center gap-2 min-w-0">
            <img
              :src="logoUrl"
              :alt="`${appTitle} Logo`"
              class="h-8 w-8 object-contain shrink-0"
              @error="onLogoError"
            />
            <span class="truncate">{{ appTitle }} – Adminportal</span>
          </h1>
          <div class="lg:hidden text-xs text-white/75 mt-1 truncate">
            {{ currentSectionLabel }}
          </div>
        </div>

        <div class="hidden lg:flex gap-4 text-sm items-center relative">
          <RouterLink to="/admin/dashboard" class="hover:underline">
            Dashboard
          </RouterLink>

          <div class="relative">
            <button
              @click="toggleSection('masterData')"
              class="hover:underline flex items-center gap-1"
            >
              🗂️ Stammdaten
              <span class="text-xs" :class="{ 'rotate-180': showMasterData }">▼</span>
            </button>
            <div
              v-if="showMasterData"
              class="absolute right-0 mt-2 w-56 bg-white text-gray-800 rounded-md shadow-lg border border-gray-200 z-50"
              @mouseleave="showMasterData = false"
            >
              <RouterLink
                v-for="item in masterDataLinks"
                :key="item.to"
                :to="item.to"
                class="block px-4 py-2 hover:bg-gray-100"
                @click="showMasterData = false"
              >
                {{ item.icon }} {{ item.label }}
              </RouterLink>
            </div>
          </div>

          <div class="relative">
            <button
              @click="toggleSection('actions')"
              class="hover:underline flex items-center gap-1"
            >
              🧭 Vorgänge
              <span class="text-xs" :class="{ 'rotate-180': showActions }">▼</span>
            </button>
            <div
              v-if="showActions"
              class="absolute right-0 mt-2 w-60 bg-white text-gray-800 rounded-md shadow-lg border border-gray-200 z-50"
              @mouseleave="showActions = false"
            >
              <RouterLink
                v-for="item in actionLinks"
                :key="item.to"
                :to="item.to"
                class="block px-4 py-2 hover:bg-gray-100"
                @click="showActions = false"
              >
                {{ item.icon }} {{ item.label }}
              </RouterLink>
            </div>
          </div>

          <div class="relative">
            <button
              @click="toggleSection('reports')"
              class="hover:underline flex items-center gap-1"
            >
              📊 Berichte
              <span class="text-xs" :class="{ 'rotate-180': showReports }"
                >▼</span
              >
            </button>
            <div
              v-if="showReports"
              class="absolute right-0 mt-2 w-64 bg-white text-gray-800 rounded-md shadow-lg border border-gray-200 z-50"
              @mouseleave="showReports = false"
            >
              <RouterLink
                v-for="item in reportLinks"
                :key="item.to"
                :to="item.to"
                class="block px-4 py-2 hover:bg-gray-100"
                @click="showReports = false"
              >
                {{ item.icon }} {{ item.label }}
              </RouterLink>
            </div>
          </div>

          <div class="relative">
            <button
              @click="toggleSection('system')"
              class="hover:underline flex items-center gap-1"
            >
              🛠️ System
              <span class="text-xs" :class="{ 'rotate-180': showSystem }">▼</span>
            </button>
            <div
              v-if="showSystem"
              class="absolute right-0 mt-2 w-56 bg-white text-gray-800 rounded-md shadow-lg border border-gray-200 z-50"
              @mouseleave="showSystem = false"
            >
              <RouterLink
                v-for="item in systemLinks"
                :key="item.to"
                :to="item.to"
                class="block px-4 py-2 hover:bg-gray-100"
                @click="showSystem = false"
              >
                {{ item.icon }} {{ item.label }}
              </RouterLink>
            </div>
          </div>

          <RouterLink
            to="/"
            class="ml-1 bg-white/20 px-3 py-1 rounded hover:bg-white/30 transition"
          >
            Terminal
          </RouterLink>

          <button
            @click="logout"
            class="flex h-8 w-8 items-center justify-center rounded bg-white/20 text-base hover:bg-white/30 transition disabled:opacity-50"
            :disabled="loading"
            :title="loading ? 'Abmelden...' : 'Abmelden'"
            aria-label="Abmelden"
          >
            {{ loading ? "…" : "⏻" }}
          </button>
        </div>

        <button
          @click="toggleMobileMenu"
          class="lg:hidden inline-flex items-center justify-center rounded-lg border border-white/20 bg-white/10 px-3 py-2 text-sm font-medium shadow-sm hover:bg-white/20 transition"
          :aria-expanded="showMobileMenu"
          aria-label="Admin-Menü öffnen"
        >
          {{ showMobileMenu ? "Schließen" : "Menü" }}
        </button>
      </div>

      <transition name="mobile-menu">
        <div
          v-if="showMobileMenu"
          class="lg:hidden border-t border-white/15 bg-primary/95 backdrop-blur-sm"
        >
          <nav class="px-4 py-4 space-y-3">
            <RouterLink
              to="/admin/dashboard"
              class="block rounded-lg bg-white/10 px-4 py-3 text-sm font-medium hover:bg-white/15 transition"
            >
              🏠 Dashboard
            </RouterLink>

            <div class="rounded-xl bg-white/10 overflow-hidden">
              <button
                @click="onMobileSectionToggle('masterData')"
                class="w-full flex items-center justify-between px-4 py-3 text-sm font-medium"
              >
                <span>🗂️ Stammdaten</span>
                <span class="text-xs" :class="{ 'rotate-180': showMasterData }">▼</span>
              </button>
              <div v-if="showMasterData" class="border-t border-white/10 bg-black/10">
                <RouterLink
                  v-for="item in masterDataLinks"
                  :key="item.to"
                  :to="item.to"
                  class="block px-4 py-3 text-sm text-white/95 hover:bg-white/10 transition"
                >
                  {{ item.icon }} {{ item.label }}
                </RouterLink>
              </div>
            </div>

            <div class="rounded-xl bg-white/10 overflow-hidden">
              <button
                @click="onMobileSectionToggle('actions')"
                class="w-full flex items-center justify-between px-4 py-3 text-sm font-medium"
              >
                <span>🧭 Vorgänge</span>
                <span class="text-xs" :class="{ 'rotate-180': showActions }">▼</span>
              </button>
              <div v-if="showActions" class="border-t border-white/10 bg-black/10">
                <RouterLink
                  v-for="item in actionLinks"
                  :key="item.to"
                  :to="item.to"
                  class="block px-4 py-3 text-sm text-white/95 hover:bg-white/10 transition"
                >
                  {{ item.icon }} {{ item.label }}
                </RouterLink>
              </div>
            </div>

            <div class="rounded-xl bg-white/10 overflow-hidden">
              <button
                @click="onMobileSectionToggle('reports')"
                class="w-full flex items-center justify-between px-4 py-3 text-sm font-medium"
              >
                <span>📊 Berichte</span>
                <span class="text-xs" :class="{ 'rotate-180': showReports }">▼</span>
              </button>
              <div v-if="showReports" class="border-t border-white/10 bg-black/10">
                <RouterLink
                  v-for="item in reportLinks"
                  :key="item.to"
                  :to="item.to"
                  class="block px-4 py-3 text-sm text-white/95 hover:bg-white/10 transition"
                >
                  {{ item.icon }} {{ item.label }}
                </RouterLink>
              </div>
            </div>

            <div class="rounded-xl bg-white/10 overflow-hidden">
              <button
                @click="onMobileSectionToggle('system')"
                class="w-full flex items-center justify-between px-4 py-3 text-sm font-medium"
              >
                <span>🛠️ System</span>
                <span class="text-xs" :class="{ 'rotate-180': showSystem }">▼</span>
              </button>
              <div v-if="showSystem" class="border-t border-white/10 bg-black/10">
                <RouterLink
                  v-for="item in systemLinks"
                  :key="item.to"
                  :to="item.to"
                  class="block px-4 py-3 text-sm text-white/95 hover:bg-white/10 transition"
                >
                  {{ item.icon }} {{ item.label }}
                </RouterLink>
              </div>
            </div>

            <div class="grid grid-cols-2 gap-3 pt-1">
              <RouterLink
                to="/"
                class="rounded-lg bg-white/10 px-4 py-3 text-center text-sm font-medium hover:bg-white/15 transition"
              >
                Terminal
              </RouterLink>
              <button
                @click="logout"
                class="rounded-lg bg-white/10 px-4 py-3 text-sm font-medium hover:bg-white/15 transition"
                :disabled="loading"
              >
                {{ loading ? "…" : "Abmelden" }}
              </button>
            </div>
          </nav>
        </div>
      </transition>
    </header>

    <!-- Seiteninhalt -->
    <main class="flex-1 p-4 sm:p-6">
      <RouterView />
    </main>
  </div>
</template>

<style scoped>
a.router-link-exact-active {
  text-decoration: underline;
  font-weight: 600;
}
button span {
  transition: transform 0.2s ease;
}
button span.rotate-180 {
  transform: rotate(180deg);
}
.mobile-menu-enter-active,
.mobile-menu-leave-active {
  transition: opacity 0.2s ease, transform 0.2s ease;
}
.mobile-menu-enter-from,
.mobile-menu-leave-to {
  opacity: 0;
  transform: translateY(-8px);
}
</style>
