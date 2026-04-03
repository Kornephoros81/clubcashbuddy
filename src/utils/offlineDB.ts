// src/utils/offlineDB.ts
import { openDB } from "idb";

const DB_NAME = "vereinskasse";
const VERSION = 3;

const STORE_QUEUE = "queue";
const STORE_MEMBERS = "members";
const STORE_PRODUCTS = "products";

export async function getDB() {
  return openDB(DB_NAME, VERSION, {
    upgrade(db, oldVersion, _newVersion, transaction) {
      if (!db.objectStoreNames.contains(STORE_QUEUE)) {
        const queueStore = db.createObjectStore(STORE_QUEUE, {
          keyPath: "id",
          autoIncrement: true,
        });
        queueStore.createIndex("by-member-id", "payload.member_id");
      } else if (oldVersion < VERSION) {
        const queueStore = transaction.objectStore(STORE_QUEUE);
        if (!queueStore.indexNames.contains("by-member-id")) {
          queueStore.createIndex("by-member-id", "payload.member_id");
        }
      }
      if (!db.objectStoreNames.contains(STORE_MEMBERS)) {
        db.createObjectStore(STORE_MEMBERS, { keyPath: "id" });
      }
      if (!db.objectStoreNames.contains(STORE_PRODUCTS)) {
        db.createObjectStore(STORE_PRODUCTS, { keyPath: "id" });
      }
    },
  });
}

// ----------------------
// Queue (Transaktionen)
// ----------------------

export type QueueStatus = "pending" | "sending" | "failed";

export type QueueEntry = {
  id?: number;
  payload: any;
  status: QueueStatus;
  createdAt: number;
  attempts?: number;
  lastError?: string;
};

export async function queueBooking(payload: any) {
  const db = await getDB();
  await db.add(STORE_QUEUE, {
    payload,
    status: "pending",
    createdAt: Date.now(),
    attempts: 0,
  });
}

export async function updateQueueEntry(
  id: number,
  patch: Partial<QueueEntry>
) {
  const db = await getDB();
  const entry = await db.get(STORE_QUEUE, id);
  if (!entry) return;
  await db.put(STORE_QUEUE, { ...entry, ...patch });
}

export async function deleteQueueEntry(id: number) {
  const db = await getDB();
  await db.delete(STORE_QUEUE, id);
}

export async function drainQueue(
  processor: (payload: any) => Promise<void>
): Promise<number> {
  const db = await getDB();
  const keys = (await db.getAllKeys("queue")).sort(
    (a: any, b: any) => Number(a) - Number(b)
  );

  let processed = 0;
  for (const key of keys) {
    const entry = await db.get("queue", key);
    if (!entry) continue;

    try {
      const status = entry.status ?? "pending";
      // Nach App-Abbruch/Reload kann "sending" haengenbleiben.
      // Solche Eintraege erneut versuchen statt dauerhaft zu skippen.
      if (status === "sending") {
        entry.status = "pending";
        await db.put(STORE_QUEUE, entry);
      }

      entry.status = "sending";
      entry.attempts = (entry.attempts ?? 0) + 1;
      await db.put(STORE_QUEUE, entry);

      console.log(`[offlineDB.drainQueue] → Verarbeite Eintrag ${key}`);
      await processor(entry.payload);
      await db.delete("queue", key);
      processed++;
    } catch (err) {
      entry.status = "failed";
      entry.lastError =
        err instanceof Error ? err.message : String(err ?? "Unknown error");
      await db.put(STORE_QUEUE, entry);
      console.warn(`[offlineDB.drainQueue] Fehler bei Eintrag ${key}:`, err);
      continue;
    }
  }

  if (processed > 0)
    console.log(
      `[offlineDB.drainQueue] ${processed} Einträge erfolgreich synchronisiert`
    );
  return processed;
}

export async function getQueueEntries() {
  const db = await getDB();
  const entries = await db.getAll(STORE_QUEUE);
  return entries.map((e: QueueEntry) => ({
    ...e,
    status: e.status === "sending" ? "pending" : (e.status ?? "pending"),
  }));
}

// ----------------------
// Cache für Mitglieder & Produkte
// ----------------------

export async function cacheMembers(members: any[]) {
  const db = await getDB();
  const tx = db.transaction(STORE_MEMBERS, "readwrite");
  const store = tx.store;
  const incoming = Array.isArray(members) ? members : [];
  const cachedAt = Date.now();
  const nextIds = new Set(incoming.map((m) => m.id));
  const existingKeys = await store.getAllKeys();

  for (const key of existingKeys) {
    if (!nextIds.has(key)) {
      await store.delete(key);
    }
  }

  for (const m of incoming) {
    await store.put({ ...m, cachedAt });
  }
  await tx.done;
}

export async function getCachedMembers() {
  const db = await getDB();
  return await db.getAll(STORE_MEMBERS);
}

export async function cacheProducts(products: any[]) {
  const db = await getDB();
  const tx = db.transaction(STORE_PRODUCTS, "readwrite");
  const store = tx.store;
  const incoming = Array.isArray(products) ? products : [];
  const cachedAt = Date.now();
  const nextIds = new Set(incoming.map((p) => p.id));
  const existingKeys = await store.getAllKeys();

  for (const key of existingKeys) {
    if (!nextIds.has(key)) {
      await store.delete(key);
    }
  }

  for (const p of incoming) {
    await store.put({ ...p, cachedAt });
  }
  await tx.done;
}

export async function getCachedProducts() {
  const db = await getDB();
  return await db.getAll(STORE_PRODUCTS);
}

export async function clearCachedProducts() {
  const db = await getDB();
  const tx = db.transaction(STORE_PRODUCTS, "readwrite");
  await tx.store.clear();
  await tx.done;
}

export async function getQueuedBookingsForMember(memberId: string) {
  const db = await getDB();
  const entries = await db.getAllFromIndex(STORE_QUEUE, "by-member-id", memberId);
  return entries.map((e: QueueEntry) => ({
    ...e,
    status: e.status === "sending" ? "pending" : (e.status ?? "pending"),
  }));
}
