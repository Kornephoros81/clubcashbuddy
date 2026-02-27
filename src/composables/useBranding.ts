import { ref } from "vue";
import { adminRpc } from "@/lib/adminApi";

type BrandingSettings = {
  app_title: string;
  logo_url: string | null;
};

const DEFAULT_TITLE = "ClubCashBuddy";
const DEFAULT_LOGO_URL = "/icons/icon-192.png";

const appTitle = ref<string>(DEFAULT_TITLE);
const logoUrl = ref<string>(DEFAULT_LOGO_URL);

function applyBranding(data: Partial<BrandingSettings> | null | undefined) {
  const nextTitle = String(data?.app_title ?? "").trim() || DEFAULT_TITLE;
  const nextLogoRaw = String(data?.logo_url ?? "").trim();
  appTitle.value = nextTitle;
  logoUrl.value = nextLogoRaw || DEFAULT_LOGO_URL;
}

async function loadBrandingPublic() {
  const res = await fetch("/api/branding", { method: "GET", cache: "no-store" });
  if (!res.ok) throw new Error("Branding konnte nicht geladen werden");
  const data = await res.json().catch(() => ({}));
  applyBranding(data?.data ?? data ?? null);
}

async function loadBrandingAdmin() {
  const data = await adminRpc("get_branding_settings");
  const row = Array.isArray(data) ? data[0] : data;
  applyBranding(row ?? null);
}

async function saveBrandingAdmin(payload: BrandingSettings) {
  const data = await adminRpc("upsert_branding_settings", payload);
  const row = Array.isArray(data) ? data[0] : data;
  applyBranding(row ?? payload);
}

export function useBranding() {
  return {
    appTitle,
    logoUrl,
    DEFAULT_TITLE,
    DEFAULT_LOGO_URL,
    applyBranding,
    loadBrandingPublic,
    loadBrandingAdmin,
    saveBrandingAdmin,
  };
}

