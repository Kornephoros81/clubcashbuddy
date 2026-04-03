// src/composables/useTerminalLogic.ts
import { ref, computed, onMounted, onBeforeUnmount, watch } from "vue";
import { useCatalog } from "@/stores/useCatalog";
import { useDeviceAuthStore } from "@/stores/useDeviceAuthStore";
import { useTransactionStore } from "@/stores/useTransactionStore";
import { book, cancelBooking, syncQueue } from "@/pwa/offlineSync";
import { useToast } from "@/composables/useToast";
import { useModal } from "@/composables/useModal";
import { getQueueEntries, getQueuedBookingsForMember } from "@/utils/offlineDB";

let singleton: ReturnType<typeof createLogic> | null = null;

export function useTerminalLogic() {
  if (!singleton) singleton = createLogic();
  return singleton!;
}

function createLogic() {
  const auth = useDeviceAuthStore();
  const store = useCatalog();
  const txStore = useTransactionStore();
  const { message: toast, show: showToast } = useToast();
  const { confirm: confirmModal } = useModal();

  const isOnline = ref(true);
  if (typeof window !== "undefined") {
    isOnline.value = navigator.onLine;
    window.addEventListener("online", () => (isOnline.value = true));
    window.addEventListener("offline", () => (isOnline.value = false));
  }

  const selectedMember = ref<any | null>(null);
  const confirmedBookings = ref<any[]>([]);
  const queuedBookings = ref<any[]>([]);
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
    const all = await getQueueEntries();
    pendingQueueCount.value = all.filter((e: any) => e.status !== "failed")
      .length;
    failedQueueCount.value = all.filter((e: any) => e.status === "failed")
      .length;
  }

  onMounted(async () => {
    auth.initFromStorage();
    if (auth.authenticated) await initDataOnce();
    watch(
      () => auth.authenticated,
      async (ok) => ok && (await initDataOnce())
    );
    if (typeof window !== "undefined") {
      window.addEventListener("online", onOnline);
      window.addEventListener("queue-synced", onQueueSynced as EventListener);
    }
  });

  onBeforeUnmount(() => {
    if (syncTimer) {
      clearTimeout(syncTimer);
      syncTimer = null;
    }
    if (typeof window !== "undefined") {
      window.removeEventListener("online", onOnline);
      window.removeEventListener("queue-synced", onQueueSynced as EventListener);
    }
  });

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
        await syncQueue(auth.token).catch(() => {});
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

  function isQueuedCancel(entry: any) {
    const p = entry?.payload ?? entry;
    return Object.prototype.hasOwnProperty.call(p, "cancel_tx_id");
  }

  function applyQueuedCancelsToServer(
    serverTx: any[],
    queued: any[]
  ): any[] {
    const out = [...serverTx];
    for (const entry of queued) {
      if (!isQueuedCancel(entry)) continue;
      const p = entry.payload ?? entry;

      let idx = -1;
      if (p.cancel_tx_id) {
        idx = out.findIndex((t: any) => t.id === p.cancel_tx_id);
      } else if (p.product_id) {
        idx = out.findIndex((t: any) => t.product_id === p.product_id);
      } else if (p.note != null) {
        idx = out.findIndex(
          (t: any) => !t.product_id && (t.note ?? null) === (p.note ?? null)
        );
      }

      if (idx >= 0) out.splice(idx, 1);
    }
    return out;
  }

  function mapQueuedDisplayToTx(member: any, queued: any[]) {
    const out: any[] = [];
    const openQueuedBooks: any[] = [];

    for (const entry of queued) {
      const p = entry.payload ?? entry;
      const syncStatus = entry.status === "failed" ? "failed" : "pending";

      if (!isQueuedCancel(entry)) {
        if (p.product_id) {
          const prod = store.products.find((x: any) => x.id === p.product_id);
          const basePrice = prod?.price ?? 0;
          const guestPrice = prod?.guest_price ?? basePrice;
          const cents = member?.is_guest ? guestPrice : basePrice;
          const bookTx = {
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
          const freeTx = {
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
        const prod = store.products.find((x: any) => x.id === p.product_id);
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

  function updateTxStoreItems() {
    txStore.items = [...confirmedBookings.value, ...queuedBookings.value];
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
    updateTxStoreItems();
  }

  async function loadBookings(memberId: string) {
    try {
      if (typeof navigator !== "undefined" && !navigator.onLine) {
        console.info("[loadBookings] Offline → zeige lokale Queue-Buchungen");
        confirmedBookings.value = [];
        await refreshQueuedBookingsForMember(memberId);
        return;
      }

      const res = await fetch("/api/get-today-transactions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${auth.token}`,
        },
        body: JSON.stringify({ member_id: memberId, limit: 300 }),
      });
      if (auth.handleAuthStatus(res.status)) return;
      const json = await res.json();
      if (!res.ok || !json.success) {
        showToast("⚠️ Fehler beim Laden der Buchungen");
        return;
      }
      const queued = await getQueuedBookingsForMember(memberId);
      const member = store.members.find((m) => m.id === memberId);
      const baseTx = applyQueuedCancelsToServer(json.data ?? [], queued);
      const queuedTx = mapQueuedDisplayToTx(member, queued);
      confirmedBookings.value = groupBookings(baseTx);
      queuedBookings.value = groupBookings(queuedTx);
      updateTxStoreItems();
    } catch (e) {
      console.info("[loadBookings] Offline/Fetch-Fehler:", e);
      showToast("📴 Offline: Buchungen können nicht geladen werden");
    }
  }

  function groupBookings(data: any[]) {
    const groups: Record<string, any> = {};
    for (const b of data) {
      const queuePrefix = b.queueOp ? `${b.queueOp}-` : "";
      const key = b.product_id
        ? `${queuePrefix}prod-${b.product_id}`
        : `${queuePrefix}note-${b.note ?? "frei"}`;
      const statusRank =
        b.syncStatus === "failed" ? 2 : b.syncStatus === "pending" ? 1 : 0;
      if (!groups[key]) {
        groups[key] = {
          product_id: b.product_id,
          product_name: b.product_name ?? b.products?.name ?? b.note ?? "frei",
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
    return Object.values(groups).sort((a: any, b: any) =>
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
    updateTxStoreItems();
  }

  async function addProduct(product: any) {
    if (!selectedMember.value || !auth.token) {
      showToast("⚠️ Kein Mitglied oder keine Authentifizierung");
      return;
    }
    loading.value = true;
    try {
      const price = selectedMember.value.is_guest
        ? product.guest_price || product.price
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

  async function undoBooking(b: any) {
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

      const res = await fetch("/api/get-booked-today-members", {
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

      const res = await fetch("/api/terminal-snapshot", {
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
        members
          .filter((m: any) => m?.has_booked_today)
          .map((m: any) => String(m.id))
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
