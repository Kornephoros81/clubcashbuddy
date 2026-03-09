import { ref } from "vue";
import { adminRpc } from "@/lib/adminApi";

type BrandingSettings = {
  app_title: string;
  logo_url: string | null;
};

const DEFAULT_TITLE = "ClubCashBuddy";
const DEFAULT_LOGO_URL = "/icons/icon-192.png";
const BRANDING_CACHE_KEY = "clubcashbuddy_branding";

function readCachedBranding(): BrandingSettings | null {
  if (typeof window === "undefined") return null;

  const raw = window.localStorage.getItem(BRANDING_CACHE_KEY);
  if (!raw) return null;

  try {
    const parsed = JSON.parse(raw) as Partial<BrandingSettings> | null;
    if (!parsed || typeof parsed !== "object") return null;
    return {
      app_title: String(parsed.app_title ?? "").trim(),
      logo_url: String(parsed.logo_url ?? "").trim() || null,
    };
  } catch {
    window.localStorage.removeItem(BRANDING_CACHE_KEY);
    return null;
  }
}

function writeCachedBranding(data: BrandingSettings) {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(BRANDING_CACHE_KEY, JSON.stringify(data));
}

const cachedBranding = readCachedBranding();

const appTitle = ref<string>(cachedBranding?.app_title || DEFAULT_TITLE);
const logoUrl = ref<string>(cachedBranding?.logo_url || DEFAULT_LOGO_URL);

function syncDocumentTitle(title: string) {
  if (typeof document !== "undefined") {
    document.title = title;
  }
}

function applyBranding(data: Partial<BrandingSettings> | null | undefined) {
  const nextTitle = String(data?.app_title ?? "").trim() || DEFAULT_TITLE;
  const nextLogoRaw = String(data?.logo_url ?? "").trim();
  appTitle.value = nextTitle;
  logoUrl.value = nextLogoRaw || DEFAULT_LOGO_URL;
  writeCachedBranding({
    app_title: nextTitle,
    logo_url: nextLogoRaw || null,
  });
  syncDocumentTitle(nextTitle);
}

syncDocumentTitle(appTitle.value);

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

