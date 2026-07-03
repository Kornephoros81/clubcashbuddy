// src/composables/useTerminalLogic.ts
import { ref, computed, watch, effectScope } from "vue";
import { useCatalog, type Member, type Product } from "@/stores/useCatalog";
import { useDeviceAuthStore } from "@/stores/useDeviceAuthStore";
import { book, cancelBooking, syncQueue, type QueuePayload } from "@/pwa/offlineSync";
import { useModal } from "@/composables/useModal";
import { getQueueEntries, getQueuedBookingsForMember } from "@/utils/offlineDB";
import { fetchWithTimeout } from "@/utils/fetchWithTimeout";

export type BookingEntry = {
  id: string;
  product_id: string | null;
  product_name: string;
  note: string | null;
  amount: number;
  count: number;
  syncStatus?: "pending" | "failed" | null;
  queueOp?: "book" | "cancel" | null;
};

type QueueEntry = {
  id?: number;
  status?: string;
  retryClass?: string;
  nextRetryAt?: number;
  payload?: QueuePayload;
  attempts?: number;
};

let singleton: ReturnType<typeof createLogic> | null = null;

export function useTerminalLogic() {
  // Detached Scope: Watcher/Computed des Singletons dürfen nicht am Lifecycle
  // der ersten aufrufenden Komponente hängen, sonst sterben sie bei deren
  // Unmount (z. B. Wechsel Terminal → Admin → Terminal).
  if (!singleton) {
    const scope = effectScope(true);
    singleton = scope.run(createLogic)!;
  }
  return singleton;
}

function createLogic() {
  const auth = useDeviceAuthStore();
  const store = useCatalog();
  const toast = ref<string | null>(null);
  let toastTimer: ReturnType<typeof setTimeout> | null = null;
  function showToast(msg: string) {
    toast.value = msg;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toast.value = null; }, 3500);
  }
  const { confirm: confirmModal } = useModal();

  const isOnline = ref(true);
  if (typeof window !== "undefined") {
    isOnline.value = navigator.onLine;
    window.addEventListener("online", () => (isOnline.value = true));
    window.addEventListener("offline", () => (isOnline.value = false));
  }

  const selectedMember = ref<Member | null>(null);
  const confirmedBookings = ref<BookingEntry[]>([]);
  const queuedBookings = ref<BookingEntry[]>([]);
  const loading = ref(false);

  const bookedTodayIds = ref<Set<string>>(new Set());
  const lastBookedTodayFetch = ref<number>(0);
  const BOOKED_TODAY_TTL_MS = 30_000;

  const hasInitialSync = ref(false);
  const hasInitialized = ref(false);

  const totalToday = computed(
    () => confirmedBookings.value.reduce((s, b) => s + b.amount, 0) * -1
  );

  const pendingQueueCount = ref(0);
  const failedQueueCount = ref(0);
  let syncTimer: ReturnType<typeof setTimeout> | null = null;
  const DIRECT_SYNC_DELAY_MS = 200;
  async function refreshQueueCount() {
    const all = await getQueueEntries() as QueueEntry[];
    pendingQueueCount.value = all.filter((e) => e.status !== "failed").length;
    failedQueueCount.value = all.filter((e) => e.status === "failed").length;
  }

  // Einmalige Initialisierung auf Singleton-/App-Lebensdauer. Bewusst NICHT an
  // onMounted/onBeforeUnmount einer Komponente gekoppelt: der Singleton überlebt
  // die erste Komponente, deren Unmount hätte die Listener dauerhaft entfernt.
  auth.initFromStorage();
  if (auth.authenticated) void initDataOnce();
  watch(
    () => auth.authenticated,
    async (ok: boolean) => ok && (await initDataOnce())
  );
  if (typeof window !== "undefined") {
    window.addEventListener("online", onOnline);
    window.addEventListener("queue-synced", onQueueSynced as EventListener);
  }

  async function initDataOnce() {
    if (hasInitialized.value) return;
    hasInitialized.value = true;
    await initData();
  }

  async function initData() {
    try {
      if (!store.members.length || !store.products.length) {
        await refreshTerminalSnapshot();
      }
      await refreshQueueCount();

      if (auth.token && !hasInitialSync.value) {
        try {
          await syncQueue(auth.token);
        } catch {
          showToast("⚠️ Synchronisation beim Start fehlgeschlagen");
        }
        await refreshQueueCount();
        hasInitialSync.value = true;
      }
    } catch (e) {
      console.error("[initData]", e);
      showToast("⚠️ Fehler beim Laden der Daten");
    }
  }

  async function onOnline() {
    if (!auth.token) return;
    try {
      await refreshAfterRemoteChanges(true);
      showToast("🔄 Online-Sync abgeschlossen");
    } catch {
      showToast("⚠️ Sync fehlgeschlagen");
    }
  }

  async function onQueueSynced() {
    try {
      await refreshAfterRemoteChanges();
    } catch (e) {
      console.warn("[queue-synced] refresh failed:", e);
    }
  }

  function kickSyncSoon() {
    if (!auth.token) return;
    if (syncTimer) clearTimeout(syncTimer);
    syncTimer = setTimeout(async () => {
      if (!auth.token) return;
      try {
        const processed = await syncQueue(auth.token);
        if (processed > 0) {
          await refreshAfterRemoteChanges();
        }
      } catch {
        // Fehlerbehandlung passiert im Sync selbst
      } finally {
        await refreshQueueCount();
        syncTimer = null;
      }
    }, DIRECT_SYNC_DELAY_MS);
  }

  function isQueuedCancel(entry: QueueEntry): boolean {
    return Object.prototype.hasOwnProperty.call(entry.payload ?? {}, "cancel_tx_id");
  }

  function applyQueuedCancelsToServer(
    serverTx: BookingEntry[],
    queued: QueueEntry[]
  ): BookingEntry[] {
    const out = [...serverTx];
    for (const entry of queued) {
      if (!isQueuedCancel(entry)) continue;
      const p = entry.payload;
      if (!p) continue;

      let idx = -1;
      if (p.cancel_tx_id) {
        idx = out.findIndex((t) => t.id === p.cancel_tx_id);
      } else if (p.product_id) {
        idx = out.findIndex((t) => t.product_id === p.product_id);
      } else if (p.note != null) {
        idx = out.findIndex(
          (t) => !t.product_id && (t.note ?? null) === (p.note ?? null)
        );
      }

      if (idx >= 0) out.splice(idx, 1);
    }
    return out;
  }

  function mapQueuedDisplayToTx(member: Member | null, queued: QueueEntry[]): BookingEntry[] {
    const out: BookingEntry[] = [];
    const openQueuedBooks: BookingEntry[] = [];

    for (const entry of queued) {
      const p = entry.payload;
      if (!p) continue;
      const syncStatus = entry.status === "failed" ? "failed" : "pending";

      if (!isQueuedCancel(entry)) {
        if (p.product_id) {
          const prod = store.products.find((x: Product) => x.id === p.product_id);
          const basePrice = prod?.price ?? 0;
          const guestPrice = prod?.guest_price ?? basePrice;
          const cents = member?.is_guest ? guestPrice : basePrice;
          const bookTx: BookingEntry = {
            id: p.client_tx_id || crypto.randomUUID(),
            product_id: p.product_id,
            product_name: prod?.name ?? "(Produkt)",
            note: null,
            amount: -Math.abs(cents),
            count: 1,
            syncStatus,
            queueOp: "book",
          };
          out.push(bookTx);
          openQueuedBooks.push(bookTx);
        } else {
          const freeLabel =
            p.transaction_type === "cash_withdrawal"
              ? "Bar-Entnahme"
              : p.note ?? "Freier Betrag";
          const freeTx: BookingEntry = {
            id: p.client_tx_id || crypto.randomUUID(),
            product_id: null,
            product_name: freeLabel,
            note: p.note ?? null,
            amount: p.amount,
            count: 1,
            syncStatus,
            queueOp: "book",
          };
          out.push(freeTx);
          openQueuedBooks.push(freeTx);
        }
        continue;
      }

      let matchIdx = -1;
      if (p.cancel_tx_id) {
        matchIdx = openQueuedBooks.findIndex((x) => x.id === p.cancel_tx_id);
      }
      if (matchIdx < 0 && p.product_id) {
        for (let i = openQueuedBooks.length - 1; i >= 0; i--) {
          if (openQueuedBooks[i].product_id === p.product_id) {
            matchIdx = i;
            break;
          }
        }
      }
      if (matchIdx < 0 && p.note != null) {
        for (let i = openQueuedBooks.length - 1; i >= 0; i--) {
          if (
            !openQueuedBooks[i].product_id &&
            (openQueuedBooks[i].note ?? null) === (p.note ?? null)
          ) {
            matchIdx = i;
            break;
          }
        }
      }

      let cancelAmount = 0;
      let cancelName = p.note ? `Storno: ${p.note}` : "Storno";
      if (matchIdx >= 0) {
        const matched = openQueuedBooks.splice(matchIdx, 1)[0];
        cancelAmount = -Number(matched.amount || 0);
        cancelName = `Storno: ${matched.product_name || matched.note || "Buchung"}`;
      } else if (p.product_id) {
        const prod = store.products.find((x: Product) => x.id === p.product_id);
        const basePrice = prod?.price ?? 0;
        const guestPrice = prod?.guest_price ?? basePrice;
        cancelAmount = Math.abs(member?.is_guest ? guestPrice : basePrice);
        cancelName = `Storno: ${prod?.name ?? "(Produkt)"}`;
      }

      out.push({
        id: p.client_tx_id || crypto.randomUUID(),
        product_id: p.product_id ?? null,
        product_name: cancelName,
        note: p.note ?? null,
        amount: cancelAmount,
        count: 1,
        syncStatus,
        queueOp: "cancel",
      });
    }

    return out;
  }

  async function refreshAfterRemoteChanges(forceSync = false) {
    if (forceSync && auth.token) {
      await syncQueue(auth.token);
    }
    await refreshTerminalSnapshot();
    if (selectedMember.value?.id) {
      await loadBookings(selectedMember.value.id);
    }
    await refreshQueueCount();
  }

  async function refreshQueuedBookingsForMember(memberId: string) {
    const member = store.members.find((m) => m.id === memberId);
    const queued = await getQueuedBookingsForMember(memberId);
    const queuedTx = mapQueuedDisplayToTx(member, queued);
    queuedBookings.value = groupBookings(queuedTx);
  }

  function flattenGroupedBookings(groups: any[]): BookingEntry[] {
    return groups.flatMap((group) =>
      (Array.isArray(group?.items) ? group.items : []).map((item: any) => ({
        id: String(item.id),
        product_id: item.product_id ?? null,
        product_name: item.product_name ?? item.note ?? "frei",
        note: item.note ?? null,
        amount: Number(item.amount ?? 0),
        count: 1,
        syncStatus: null,
        queueOp: null,
      }))
    );
  }

  async function fetchConfirmedBookingsForMember(memberId: string, member?: Member | null) {
    if (member?.is_guest) {
      const end = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
      const res = await fetchWithTimeout("/api/get-member-bookings", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${auth.token}`,
        },
        body: JSON.stringify({
          member_id: memberId,
          start: "1970-01-01T00:00:00.000Z",
          end,
          exclude_settled: true,
        }),
      });
      if (auth.handleAuthStatus(res.status)) return null;
      const json = await res.json();
      if (!res.ok || !json.success) return null;
      return flattenGroupedBookings(json.data ?? []);
    }

    const res = await fetchWithTimeout("/api/get-today-transactions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${auth.token}`,
      },
      body: JSON.stringify({ member_id: memberId, limit: 300 }),
    });
    if (auth.handleAuthStatus(res.status)) return null;
    const json = await res.json();
    if (!res.ok || !json.success) return null;
    return json.data ?? [];
  }

  async function loadBookings(memberId: string) {
    try {
      if (typeof navigator !== "undefined" && !navigator.onLine) {
        console.info("[loadBookings] Offline → zeige lokale Queue-Buchungen");
        confirmedBookings.value = [];
        await refreshQueuedBookingsForMember(memberId);
        return;
      }

      const member = store.members.find((m) => m.id === memberId);
      const confirmed = await fetchConfirmedBookingsForMember(memberId, member);
      if (!confirmed) {
        showToast("⚠️ Fehler beim Laden der Buchungen");
        return;
      }
      const queued = await getQueuedBookingsForMember(memberId);
      const baseTx = applyQueuedCancelsToServer(confirmed, queued);
      const queuedTx = mapQueuedDisplayToTx(member, queued);
      confirmedBookings.value = groupBookings(baseTx);
      queuedBookings.value = groupBookings(queuedTx);
    } catch (e) {
      console.info("[loadBookings] Offline/Fetch-Fehler:", e);
      showToast("📴 Offline: Buchungen können nicht geladen werden");
    }
  }

  function groupBookings(data: BookingEntry[]): BookingEntry[] {
    const groups: Record<string, BookingEntry> = {};
    for (const b of data) {
      const queuePrefix = b.queueOp ? `${b.queueOp}-` : "";
      const key = b.product_id
        ? `${queuePrefix}prod-${b.product_id}`
        : `${queuePrefix}note-${b.note ?? "frei"}`;
      const statusRank =
        b.syncStatus === "failed" ? 2 : b.syncStatus === "pending" ? 1 : 0;
      if (!groups[key]) {
        groups[key] = {
          id: b.id,
          product_id: b.product_id,
          product_name: b.product_name ?? b.note ?? "frei",
          note: b.note,
          amount: b.amount,
          count: 1,
          syncStatus: b.syncStatus ?? null,
          queueOp: b.queueOp ?? null,
        };
      } else {
        groups[key].count++;
        groups[key].amount += b.amount;
        const currentRank =
          groups[key].syncStatus === "failed"
            ? 2
            : groups[key].syncStatus === "pending"
            ? 1
            : 0;
        if (statusRank > currentRank) {
          groups[key].syncStatus = b.syncStatus;
        }
      }
    }
    return Object.values(groups).sort((a, b) =>
      (a.product_name || "").localeCompare(b.product_name || "", "de")
    );
  }

  async function openMember(memberId: string) {
    const m = store.members.find((x) => x.id === memberId);
    if (!m) return;
    selectedMember.value = m;
    await loadBookings(m.id);
  }

  function closeMember() {
    selectedMember.value = null;
    confirmedBookings.value = [];
    queuedBookings.value = [];
  }

  async function addProduct(product: Product) {
    if (!selectedMember.value || !auth.token) {
      showToast("⚠️ Kein Mitglied oder keine Authentifizierung");
      return;
    }
    loading.value = true;
    try {
      const price = selectedMember.value.is_guest
        ? product.guest_price ?? product.price
        : product.price;
      await book(
        auth.token,
        selectedMember.value.id,
        product.id,
        0,
        undefined
      );
      await refreshQueuedBookingsForMember(selectedMember.value.id);
      bookedTodayIds.value.add(selectedMember.value.id);
      await refreshQueueCount();
      kickSyncSoon();

      showToast(
        `✅ ${product.name} (${(price / 100).toFixed(
          2
        )} €) gespeichert – Sync läuft`
      );
    } catch (err) {
      console.error("[addProduct]", err);
      showToast("⚠️ Buchung fehlgeschlagen");
    } finally {
      loading.value = false;
    }
  }

  async function addFree(
    amountEuro: number,
    note: string,
    transactionType: "sale_free_amount" | "cash_withdrawal" = "sale_free_amount"
  ) {
    if (!selectedMember.value || !auth.token) {
      showToast("⚠️ Kein Mitglied oder keine Authentifizierung");
      return;
    }
    if (!amountEuro || amountEuro <= 0) {
      showToast("⚠️ Ungültiger Betrag");
      return;
    }
    const negative = -Math.round(amountEuro * 100);
    const noteText = note?.trim() || (
      transactionType === "cash_withdrawal"
        ? `Bar-Entnahme ${new Date().toLocaleString("de-DE")}`
        : `freie Buchung ${new Date().toLocaleString("de-DE")}`
    );
    loading.value = true;
    try {
      await book(
        auth.token,
        selectedMember.value.id,
        null,
        negative,
        noteText,
        transactionType
      );
      await refreshQueuedBookingsForMember(selectedMember.value.id);
      bookedTodayIds.value.add(selectedMember.value.id);
      await refreshQueueCount();
      kickSyncSoon();

      showToast(
        `✅ ${amountEuro.toFixed(2)} € gespeichert – Sync läuft`
      );
    } catch (err) {
      console.error("[addFree]", err);
      showToast("⚠️ Freie Buchung fehlgeschlagen");
    } finally {
      loading.value = false;
    }
  }

  async function undoBooking(b: BookingEntry) {
    if (!selectedMember.value || !auth.token) {
      showToast("⚠️ Kein Mitglied oder keine Authentifizierung");
      return;
    }
    const ok = await confirmModal(
      "Buchung stornieren?",
      `Möchtest du wirklich 1× ${
        b.product_name || b.note || "Buchung"
      } stornieren?`,
      { danger: true }
    );
    if (!ok) {
      showToast("❎ Stornierung abgebrochen");
      return;
    }
    loading.value = true;
    try {
      await cancelBooking(
        auth.token,
        null,
        selectedMember.value.id,
        {
          product_id: b.product_id,
          note: b.note,
        }
      );
      await refreshQueuedBookingsForMember(selectedMember.value.id);
      await refreshQueueCount();

      kickSyncSoon();

      showToast("🗑️ Storno gespeichert – Sync läuft");
    } catch (err) {
      console.error("[undoBooking]", err);
      showToast("⚠️ Stornierung fehlgeschlagen");
    } finally {
      loading.value = false;
    }
  }

  async function fetchBookedToday(forceRefresh = false) {
    try {
      if (!auth.token) return;
      if (typeof navigator !== "undefined" && !navigator.onLine) {
        console.info("[fetchBookedToday] Offline → übersprungen");
        return;
      }
      const now = Date.now();
      if (
        !forceRefresh &&
        now - lastBookedTodayFetch.value < BOOKED_TODAY_TTL_MS
      )
        return;

      const res = await fetchWithTimeout("/api/get-booked-today-members", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${auth.token}`,
        },
      });
      if (auth.handleAuthStatus(res.status)) return;
      if (!res.ok) {
        console.warn("[fetchBookedToday] Edge error:", await res.text());
        return;
      }
      const json = await res.json();
      if (json.success && Array.isArray(json.member_ids)) {
        bookedTodayIds.value = new Set<string>(json.member_ids);
        lastBookedTodayFetch.value = now;
      }
    } catch (err) {
      console.info("[fetchBookedToday] Offline/Fetch-Fehler:", err);
    }
  }

  async function refreshTerminalSnapshot() {
    try {
      if (!auth.token) return;
      if (typeof navigator !== "undefined" && !navigator.onLine) {
        await store.loadMembers();
        return;
      }

      const res = await fetchWithTimeout("/api/terminal-snapshot", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${auth.token}`,
        },
      });
      if (auth.handleAuthStatus(res.status)) return;
      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const json = await res.json();
      const members = Array.isArray(json?.members) ? json.members : [];
      const products = Array.isArray(json?.products) ? json.products : [];
      await store.applyMembers(members);
      if (products.length) {
        await store.applyProducts(products);
      }
      bookedTodayIds.value = new Set<string>(
        (members as Member[])
          .filter((m) => m?.has_booked_today)
          .map((m) => String(m.id))
      );
      lastBookedTodayFetch.value = Date.now();
    } catch (err) {
      console.warn("[refreshTerminalSnapshot] fallback:", err);
      await store.loadMembers();
      await fetchBookedToday(true);
    }
  }

  return {
    auth,
    store,
    confirmedBookings,
    queuedBookings,
    selectedMember,
    totalToday,
    loading,
    toast,
    bookedTodayIds,
    pendingQueueCount,
    failedQueueCount,
    isOnline,
    openMember,
    closeMember,
    addProduct,
    addFree,
    undoBooking,
    fetchBookedToday,
    refreshTerminalSnapshot,
    showToast,
    loadBookings,
    async refreshCurrentBookings() {
      if (selectedMember.value?.id) {
        await loadBookings(selectedMember.value.id);
      }
    },
  };
}
