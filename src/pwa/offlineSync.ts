import {
  deleteQueueEntry,
  getQueueEntries,
  queueBooking,
  updateQueueEntry,
} from "@/utils/offlineDB";

export type QueuePayload = {
  member_id: string;
  product_id: string | null;
  amount: number;
  transaction_type?: "sale_free_amount" | "cash_withdrawal" | null;
  note?: string | null;
  cancel_tx_id?: string | null; // 🟢 für Stornos
  client_tx_id?: string; // 🟢 für Idempotenz
};

const BOOKING_SYNC_BATCH_SIZE = 25;
let syncInFlight: Promise<number> | null = null;

function getErrorText(err: unknown): string {
  if (err instanceof Error) return err.message ?? "";
  return String(err ?? "");
}

function isMemberMissingError(err: unknown): boolean {
  const raw = getErrorText(err).toLowerCase();
  return (
    raw.includes("member_not_found") ||
    raw.includes("mitglied nicht gefunden") ||
    raw.includes("member not found")
  );
}

/**
 * Legt eine Buchung immer lokal in die Queue.
 * Die Synchronisierung läuft im Hintergrund.
 * @returns true, wenn lokal gespeichert wurde.
 */
export async function book(
  token: string,
  member_id: string,
  product_id: string | null,
  amount: number,
  note?: string | null,
  transaction_type?: "sale_free_amount" | "cash_withdrawal" | null
): Promise<boolean> {
  const clientTxId = crypto.randomUUID(); // 🟢 Idempotente Client-ID
  await queueBooking({
    member_id,
    product_id,
    amount,
    transaction_type: transaction_type ?? null,
    note: note ?? null,
    client_tx_id: clientTxId,
  });
  return true; // ✅ immer lokal gespeichert
}

/**
 * Legt ein Storno immer lokal in die Queue.
 * @returns true, wenn lokal gespeichert wurde.
 */
export async function cancelBooking(
  token: string,
  cancel_tx_id: string | null,
  member_id: string,
  extra?: { product_id?: string | null; note?: string | null }
): Promise<boolean> {
  await queueBooking({
    member_id,
    product_id: extra?.product_id ?? null,
    amount: 0,
    note: extra?.note ?? null,
    cancel_tx_id: cancel_tx_id ?? null,
    client_tx_id: crypto.randomUUID(),
  });
  return true;
}

/** Hilfsfunktion: Request an Edge Function. Wirft bei HTTP≠2xx. */
async function callEF(
  token: string,
  endpoint: string,
  payload: any
): Promise<any> {
  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
  });

  const text = await res.text().catch(() => "");
  if (!res.ok) {
    console.error("[offlineSync.callEF] HTTP Error:", res.status, text);
    throw new Error(text || `HTTP ${res.status}`);
  }

  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

/**
 * Synchronisiert die lokale Queue beim Online-Event oder App-Start.
 * @returns Anzahl erfolgreich synchronisierter Einträge.
 */
export async function syncQueue(token: string): Promise<number> {
  if (syncInFlight) return syncInFlight;

  syncInFlight = (async () => {
    if (!navigator.onLine) return 0;

    const entries = (await getQueueEntries()).sort(
      (a: any, b: any) => Number(a?.id ?? 0) - Number(b?.id ?? 0)
    );
    let successCount = 0;

    const processEntry = async (entry: any): Promise<boolean> => {
      const id = Number(entry?.id ?? 0);
      if (!Number.isFinite(id) || id <= 0) return false;

      const payload = (entry?.payload ?? {}) as QueuePayload;
      const attempts = Number(entry?.attempts ?? 0) + 1;

      await updateQueueEntry(id, {
        status: "sending",
        attempts,
        lastError: undefined,
      });

      try {
        const isCancel = Object.prototype.hasOwnProperty.call(
          payload,
          "cancel_tx_id"
        );

        if (isCancel) {
          const result = await callEF(token, "/api/cancel-transaction", {
            cancel_tx_id: payload.cancel_tx_id ?? null,
            member_id: payload.member_id,
            product_id: payload.product_id ?? null,
            note: payload.note ?? null,
          });
          if (result?.cancelled) {
            console.log("[offlineSync] ✅ storniert:", result.cancelled);
          }
        } else {
          const result = await callEF(token, "/api/book-transaction", {
            member_id: payload.member_id,
            product_id: payload.product_id,
            free_amount: payload.amount,
            p_transaction_type: payload.transaction_type ?? null,
            p_note: payload.note ?? null,
            client_tx_id_param: payload.client_tx_id ?? crypto.randomUUID(),
          });
          if (result?.success) {
            console.log("[offlineSync] ✅ gebucht:", result.data);
          }
        }

        await deleteQueueEntry(id);
        return true;
      } catch (err) {
        if (!isCancel && isMemberMissingError(err)) {
          await deleteQueueEntry(id);
          console.warn(
            "[offlineSync.syncQueue] Queue-Eintrag geloescht (Mitglied nicht gefunden):",
            id
          );
          return false;
        }

        await updateQueueEntry(id, {
          status: "failed",
          attempts,
          lastError:
            getErrorText(err) || "Unknown error",
        });
        console.error("[offlineSync.syncQueue] Fehler bei Queue-ID", id, err);
        return false;
      }
    };

    const processBookingRun = async (run: any[]) => {
      if (!run.length) return 0;
      let runSuccess = 0;

      for (let start = 0; start < run.length; start += BOOKING_SYNC_BATCH_SIZE) {
        const slice = run.slice(start, start + BOOKING_SYNC_BATCH_SIZE);
        const attemptsById = new Map<number, number>();
        const payloadItems: any[] = [];

        for (const entry of slice) {
          const id = Number(entry?.id ?? 0);
          if (!Number.isFinite(id) || id <= 0) continue;
          const payload = (entry?.payload ?? {}) as QueuePayload;
          const attempts = Number(entry?.attempts ?? 0) + 1;
          attemptsById.set(id, attempts);

          await updateQueueEntry(id, {
            status: "sending",
            attempts,
            lastError: undefined,
          });

          payloadItems.push({
            queue_id: id,
            member_id: payload.member_id,
            product_id: payload.product_id,
            free_amount: payload.amount,
            p_transaction_type: payload.transaction_type ?? null,
            p_note: payload.note ?? null,
            client_tx_id_param: payload.client_tx_id ?? crypto.randomUUID(),
          });
        }

        if (!payloadItems.length) continue;

        let results: any[] = [];
        try {
          const response = await callEF(token, "/api/book-transactions-batch", {
            items: payloadItems,
          });
          results = Array.isArray(response?.results) ? response.results : [];
        } catch (err) {
          for (const item of payloadItems) {
            const id = Number(item.queue_id ?? 0);
            if (!Number.isFinite(id) || id <= 0) continue;
            try {
              await callEF(token, "/api/book-transaction", {
                member_id: item.member_id,
                product_id: item.product_id,
                free_amount: item.free_amount,
                p_transaction_type: item.p_transaction_type,
                p_note: item.p_note,
                client_tx_id_param: item.client_tx_id_param,
              });
              await deleteQueueEntry(id);
              runSuccess += 1;
            } catch (singleErr) {
              if (isMemberMissingError(singleErr)) {
                await deleteQueueEntry(id);
                console.warn(
                  "[offlineSync.syncQueue] Queue-Eintrag geloescht (Mitglied nicht gefunden):",
                  id
                );
                continue;
              }

              await updateQueueEntry(id, {
                status: "failed",
                attempts: attemptsById.get(id) ?? 1,
                lastError: getErrorText(singleErr) || getErrorText(err) || "Unknown error",
              });
            }
          }
          continue;
        }

        const byQueueId = new Map<number, any>();
        for (const result of results) {
          const id = Number(result?.queue_id ?? 0);
          if (Number.isFinite(id) && id > 0) byQueueId.set(id, result);
        }

        for (const item of payloadItems) {
          const id = Number(item.queue_id ?? 0);
          if (!Number.isFinite(id) || id <= 0) continue;

          const result = byQueueId.get(id);
          if (result?.success) {
            await deleteQueueEntry(id);
            runSuccess += 1;
            continue;
          }

          if (isMemberMissingError(result?.error)) {
            await deleteQueueEntry(id);
            console.warn(
              "[offlineSync.syncQueue] Queue-Eintrag geloescht (Mitglied nicht gefunden):",
              id
            );
            continue;
          }

          await updateQueueEntry(id, {
            status: "failed",
            attempts: attemptsById.get(id) ?? 1,
            lastError: String(result?.error ?? "Batch sync failed"),
          });
        }
      }

      return runSuccess;
    };

    let i = 0;
    while (i < entries.length) {
      const current = entries[i];
      const payload = (current?.payload ?? {}) as QueuePayload;
      const isCancel = Object.prototype.hasOwnProperty.call(
        payload,
        "cancel_tx_id"
      );

      if (isCancel) {
        const ok = await processEntry(current);
        if (ok) successCount += 1;
        i += 1;
        continue;
      }

      const run: any[] = [];
      while (i < entries.length) {
        const e = entries[i];
        const p = (e?.payload ?? {}) as QueuePayload;
        const cancel = Object.prototype.hasOwnProperty.call(p, "cancel_tx_id");
        if (cancel) break;
        run.push(e);
        i += 1;
      }

      successCount += await processBookingRun(run);
    }

    if (successCount > 0) {
      console.log(`[offlineSync] ${successCount} Einträge synchronisiert`);
    }
    return successCount;
  })();

  try {
    return await syncInFlight;
  } finally {
    syncInFlight = null;
  }
}

/** Rückwärtskompatibler Alias */
export const syncQueued = syncQueue;
