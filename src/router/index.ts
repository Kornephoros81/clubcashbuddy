import { createRouter, createWebHistory } from "vue-router";
import { useAppAuthStore } from "@/stores/useAppAuthStore";
import Terminal from "@/pages/Terminal.vue";
import AdminPortal from "@/pages/AdminPortal.vue";
import Dashboard from "@/pages/Dashboard.vue";
import Login from "@/components/AdminLogin.vue";
import AdminProducts from "@/components/AdminProducts.vue";
import AdminProductCategories from "@/components/AdminProductCategories.vue";
import AdminMembers from "@/components/AdminMembers.vue";
import StockRefillView from "@/components/Terminal/StockRefillView.vue";
import AdminInventoryReport from "@/components/AdminInventoryReport.vue";
import AdminBookingsReport from "@/components/AdminBookingsReport.vue";
import AdminSettlementView from "@/components/AdminSettlementView.vue";
import AdminStorageView from "@/components/AdminStorageView.vue"; 
import AdminStockAdjustmentsReport from "@/components/AdminStockAdjustmentsReport.vue";
import AdminFridgeRefillsReport from "@/components/AdminFridgeRefillsReport.vue";
import AdminCancellationsReport from "@/components/AdminCancellationsReport.vue";
import AdminRevenueReport from "@/components/AdminRevenueReport.vue";
import AdminSettlementsReport from "@/components/AdminSettlementsReport.vue";
import AdminBrandingSettings from "@/components/AdminBrandingSettings.vue";
import AdminUsers from "@/components/AdminUsers.vue";
import AdminDevicePairing from "@/components/AdminDevicePairing.vue";


const routes = [
  { path: "/", component: Terminal },
  { path: "/terminal", component: Terminal },
  { path: "/stock-refill", component: StockRefillView },
  {
    path: "/admin",
    component: AdminPortal,
    meta: { requiresAuth: true },
    children: [
      { path: "", redirect: "/admin/dashboard" },
      { path: "dashboard", component: Dashboard },
      { path: "products", component: AdminProducts },
      { path: "product-categories", component: AdminProductCategories },
      { path: "members", component: AdminMembers },
      { path: "inventory-report", component: AdminInventoryReport },
      { path: "bookings-report", component: AdminBookingsReport },
      { path: "stock-adjustments-report", component: AdminStockAdjustmentsReport },
      { path: "fridge-refills-report", component: AdminFridgeRefillsReport },
      { path: "cancellations-report", component: AdminCancellationsReport },
      { path: "revenue-report", component: AdminRevenueReport },
      { path: "settlements-report", component: AdminSettlementsReport },
      { path: "branding", component: AdminBrandingSettings },
      { path: "users", component: AdminUsers },
      { path: "device-pairing", component: AdminDevicePairing },
      { path: "settlement", component: AdminSettlementView },
      { path: "storage", component: AdminStorageView },
    ],
  },
  { path: "/login", component: Login },
  { path: "/reset-password", component: () => import("@/pages/ResetPasswordPage.vue") },
];

const router = createRouter({
  history: createWebHistory(),
  routes,
});

let adminExitTimer: number | null = null;
let inactivityTimer: number | null = null;
let logoutTriggered = false;

const ADMIN_EXIT_TIMEOUT = 5 * 60 * 1000;
const ADMIN_INACTIVITY_TIMEOUT = 5 * 60 * 1000;

function clearAdminTimers() {
  if (adminExitTimer) clearTimeout(adminExitTimer);
  if (inactivityTimer) clearTimeout(inactivityTimer);
  adminExitTimer = null;
  inactivityTimer = null;
}

async function safeLogout(reason: string) {
  if (logoutTriggered) return;
  logoutTriggered = true;
  console.warn(`[Admin Logout] ${reason}`);
  try {
    const authStore = useAppAuthStore();
    await authStore.logoutAdmin();
  } catch (e) {
    console.error("[Admin Logout Error]", e);
  } finally {
    window.location.href = "/";
  }
}

function resetInactivityTimer() {
  if (inactivityTimer) clearTimeout(inactivityTimer);
  inactivityTimer = window.setTimeout(
    () => safeLogout("Inaktivität"),
    ADMIN_INACTIVITY_TIMEOUT
  );
}

router.beforeEach(async (to, from) => {
  const authStore = useAppAuthStore();
  authStore.initFromStorage();
  const role = authStore.isAdminAuthenticated ? "admin" : null;

  if (to.meta.requiresAuth && !authStore.isAdminAuthenticated) return "/login";

  if (role === "admin") {
    const leavingAdmin =
      from.path.startsWith("/admin") && !to.path.startsWith("/admin");
    const enteringAdmin = to.path.startsWith("/admin");

    if (leavingAdmin) {
      console.log(
        "[Admin Timeout] verlässt Adminbereich → Exit-Timer gestartet"
      );
      adminExitTimer = window.setTimeout(
        () => safeLogout("zu lange außerhalb des Adminbereichs"),
        ADMIN_EXIT_TIMEOUT
      );
    }

    if (enteringAdmin) {
      clearAdminTimers();
      console.log("[Admin Timeout] im Adminbereich → Timer gestoppt");
    }
  } else {
    clearAdminTimers();
  }

  return true;
});

window.addEventListener("click", resetInactivityTimer);
window.addEventListener("keydown", resetInactivityTimer);
window.addEventListener("touchstart", resetInactivityTimer);
window.addEventListener("mousemove", resetInactivityTimer);

router.afterEach(async (to) => {
  const authStore = useAppAuthStore();
  authStore.initFromStorage();
  const role = authStore.isAdminAuthenticated ? "admin" : null;

  if (role === "admin" && to.path.startsWith("/admin")) {
    logoutTriggered = false;
    resetInactivityTimer();
  } else {
    if (inactivityTimer) clearTimeout(inactivityTimer);
  }
});

export default router;
