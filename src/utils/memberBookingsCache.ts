import { fetchWithTimeout } from "@/utils/fetchWithTimeout";

const BOOKING_CACHE_TTL_MS = 30 * 1000;

type BookingCacheEntry = {
  expiresAt: number;
  data: any[];
};

const cache = new Map<string, BookingCacheEntry>();

// Abgelaufene Einträge aufräumen: die Map lebt auf einem dauerlaufenden
// Kiosk-Gerät sonst unbegrenzt weiter (jeder neue Key bleibt für immer).
function pruneExpired(now: number) {
  for (const [key, entry] of cache) {
    if (entry.expiresAt <= now) cache.delete(key);
  }
}

function buildKey(memberId: string, start: string, end: string, excludeSettled: boolean) {
  return JSON.stringify({
    memberId,
    start,
    end,
    excludeSettled,
  });
}

export function clearMemberBookingsCache(memberId?: string) {
  if (!memberId) {
    cache.clear();
    return;
  }

  for (const key of cache.keys()) {
    if (key.includes(`"memberId":"${memberId}"`)) {
      cache.delete(key);
    }
  }
}

export async function fetchMemberBookingsCached(params: {
  token: string;
  memberId: string;
  start: string;
  end: string;
  excludeSettled?: boolean;
  force?: boolean;
}) {
  const {
    token,
    memberId,
    start,
    end,
    excludeSettled = false,
    force = false,
  } = params;

  const key = buildKey(memberId, start, end, excludeSettled);
  const now = Date.now();
  pruneExpired(now);
  const cached = cache.get(key);

  if (!force && cached && cached.expiresAt > now) {
    return cached.data;
  }

  const res = await fetchWithTimeout("/api/get-member-bookings", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      member_id: memberId,
      start,
      end,
      exclude_settled: excludeSettled,
    }),
  });

  const result = await res.json();
  if (!res.ok || result.error) {
    throw new Error(result.error || "Fehler beim Abruf");
  }

  const data = Array.isArray(result.data) ? result.data : [];
  cache.set(key, {
    expiresAt: now + BOOKING_CACHE_TTL_MS,
    data,
  });
  return data;
}
