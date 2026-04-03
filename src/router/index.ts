import { createRouter, createWebHistory } from "vue-router";
import { useAppAuthStore } from "@/stores/useAppAuthStore";
const Terminal = () => import("@/pages/Terminal.vue");
const AdminPortal = () => import("@/pages/AdminPortal.vue");
const Dashboard = () => import("@/pages/DashboardOptimized.vue");
const Login = () => import("@/components/AdminLogin.vue");
const AdminProducts = () => import("@/components/AdminProducts.vue");
const AdminProductCategories = () => import("@/components/AdminProductCategories.vue");
const AdminMembers = () => import("@/components/AdminMembers.vue");
const StockRefillView = () => import("@/components/Terminal/StockRefillView.vue");
const AdminInventoryReport = () => import("@/components/AdminInventoryReport.vue");
const AdminBookingsReport = () => import("@/components/AdminBookingsReport.vue");
const AdminSettlementView = () => import("@/components/AdminSettlementView.vue");
const AdminStorageView = () => import("@/components/AdminStorageView.vue");
const AdminStockAdjustmentsReport = () => import("@/components/AdminStockAdjustmentsReport.vue");
const AdminFridgeRefillsReport = () => import("@/components/AdminFridgeRefillsReport.vue");
const AdminCancellationsReport = () => import("@/components/AdminCancellationsReport.vue");
const AdminRevenueReport = () => import("@/components/AdminRevenueReportOptimized.vue");
const AdminSettlementsReport = () => import("@/components/AdminSettlementsReport.vue");
const AdminBrandingSettings = () => import("@/components/AdminBrandingSettings.vue");
const AdminUsers = () => import("@/components/AdminUsers.vue");
const AdminDevicePairing = () => import("@/components/AdminDevicePairing.vue");

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
let activityListenersAttached = false;

const ADMIN_EXIT_TIMEOUT = 5 * 60 * 1000;
const ADMIN_INACTIVITY_TIMEOUT = 5 * 60 * 1000;
const ACTIVITY_EVENTS: Array<keyof WindowEventMap> = [
  "click",
  "keydown",
  "touchstart",
  "mousemove",
];

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
    await router.replace("/");
  }
}

function resetInactivityTimer() {
  if (inactivityTimer) clearTimeout(inactivityTimer);
  inactivityTimer = window.setTimeout(
    () => safeLogout("Inaktivität"),
    ADMIN_INACTIVITY_TIMEOUT
  );
}

function attachActivityListeners() {
  if (activityListenersAttached) return;
  for (const eventName of ACTIVITY_EVENTS) {
    window.addEventListener(eventName, resetInactivityTimer, { passive: true });
  }
  activityListenersAttached = true;
}

function detachActivityListeners() {
  if (!activityListenersAttached) return;
  for (const eventName of ACTIVITY_EVENTS) {
    window.removeEventListener(eventName, resetInactivityTimer);
  }
  activityListenersAttached = false;
}

router.beforeEach(async (to, from) => {
  const authStore = useAppAuthStore();
  authStore.ensureHydrated();
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
      attachActivityListeners();
      console.log("[Admin Timeout] im Adminbereich → Timer gestoppt");
    }
  } else {
    clearAdminTimers();
    detachActivityListeners();
  }

  return true;
});

router.afterEach(async (to) => {
  const authStore = useAppAuthStore();
  authStore.ensureHydrated();
  const role = authStore.isAdminAuthenticated ? "admin" : null;

  if (role === "admin" && to.path.startsWith("/admin")) {
    logoutTriggered = false;
    attachActivityListeners();
    resetInactivityTimer();
  } else {
    if (inactivityTimer) clearTimeout(inactivityTimer);
    detachActivityListeners();
  }
});

export default router;
