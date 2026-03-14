import { ref } from "vue";
import { adminRpc } from "@/lib/adminApi";

type BrandingSettings = {
  app_title: string;
  logo_url: string | null;
};

const DEFAULT_TITLE = "ClubCashBuddy";
const DEFAULT_LOGO_URL = "/icons/icon-192.png";
const BRANDING_CACHE_KEY = "clubcashbuddy_branding";
const BRANDING_CACHE_TTL_MS = 6 * 60 * 60 * 1000;

type CachedBrandingPayload = {
  app_title: string;
  logo_url: string | null;
  cached_at: number;
};

function readCachedBranding(): BrandingSettings | null {
  if (typeof window === "undefined") return null;

  const raw = window.localStorage.getItem(BRANDING_CACHE_KEY);
  if (!raw) return null;

  try {
    const parsed = JSON.parse(raw) as Partial<CachedBrandingPayload> | null;
    if (!parsed || typeof parsed !== "object") return null;
    const cachedAt = Number(parsed.cached_at ?? 0);
    if (!Number.isFinite(cachedAt) || Date.now() - cachedAt > BRANDING_CACHE_TTL_MS) {
      window.localStorage.removeItem(BRANDING_CACHE_KEY);
      return null;
    }
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
  const payload: CachedBrandingPayload = {
    ...data,
    cached_at: Date.now(),
  };
  window.localStorage.setItem(BRANDING_CACHE_KEY, JSON.stringify(payload));
}

const cachedBranding = readCachedBranding();

const appTitle = ref<string>(cachedBranding?.app_title || DEFAULT_TITLE);
const logoUrl = ref<string>(cachedBranding?.logo_url || DEFAULT_LOGO_URL);

function syncDocumentTitle(title: string) {
  if (typeof document !== "undefined") {
    document.title = title;
  }
}

function syncDocumentIcons(iconUrl: string) {
  if (typeof document === "undefined") return;

  const links = Array.from(
    document.querySelectorAll<HTMLLinkElement>("link[rel~='icon']")
  );

  if (links.length) {
    for (const link of links) {
      link.href = iconUrl;
    }
    return;
  }

  const link = document.createElement("link");
  link.rel = "icon";
  link.href = iconUrl;
  document.head.appendChild(link);
}

function applyBranding(data: Partial<BrandingSettings> | null | undefined) {
  const nextTitle = String(data?.app_title ?? "").trim() || DEFAULT_TITLE;
  const nextLogoRaw = String(data?.logo_url ?? "").trim();
  const nextLogo = nextLogoRaw || DEFAULT_LOGO_URL;
  appTitle.value = nextTitle;
  logoUrl.value = nextLogo;
  writeCachedBranding({
    app_title: nextTitle,
    logo_url: nextLogoRaw || null,
  });
  syncDocumentTitle(nextTitle);
  syncDocumentIcons(nextLogo);
}

syncDocumentTitle(appTitle.value);
syncDocumentIcons(logoUrl.value);

async function loadBrandingPublic() {
  const res = await fetch("/api/branding", { method: "GET", cache: "force-cache" });
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

