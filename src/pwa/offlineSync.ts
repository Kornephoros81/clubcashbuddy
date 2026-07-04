import {
  deleteQueueEntry,
  getQueueEntries,
  queueBooking,
  updateQueueEntry,
  type QueueEntry,
} from "@/utils/offlineDB";
import { fetchWithTimeout } from "@/utils/fetchWithTimeout";

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
const QUICK_RETRY_ATTEMPTS = 3;
let syncInFlight: Promise<number> | null = null;
let rerunRequested = false;

type SyncRunMetrics = {
  started_at: string;
  finished_at?: string;
  duration_ms?: number;
  attempted_count: number;
  success_count: number;
  failed_count: number;
  book_count: number;
  cancel_count: number;
  batch_count: number;
  avg_item_ms?: number | null;
  error_message?: string | null;
};

function getNextRetryDelayMs(attempts: number): number {
  if (attempts <= QUICK_RETRY_ATTEMPTS) return 0;
  if (attempts === 4) return 5 * 60_000;
  if (attempts === 5) return 15 * 60_000;
  if (attempts === 6) return 60 * 60_000;
  if (attempts === 7) return 4 * 60 * 60_000;
  return 12 * 60 * 60_000;
}

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

function getQueueOperation(payload: QueuePayload): "book" | "cancel" {
  return Object.prototype.hasOwnProperty.call(payload, "cancel_tx_id")
    ? "cancel"
    : "book";
}

function getPerformanceNow(): number {
  if (typeof performance !== "undefined" && typeof performance.now === "function") {
    return performance.now();
  }
  return Date.now();
}

function buildQueueStatus(entries: QueueEntry[]) {
  const failed = entries.filter((entry) => entry.status === "failed");
  const fatal = failed.filter((entry) => entry.retryClass === "fatal");
  const retryable = failed.filter((entry) => entry.retryClass !== "fatal");

  return {
    pending_count: entries.filter((entry) => entry.status !== "failed").length,
    failed_count: failed.length,
    total_count: entries.length,
    fatal_failed_count: fatal.length,
    retryable_failed_count: retryable.length,
  };
}

async function reportSyncMetrics(token: string, metrics: SyncRunMetrics): Promise<void> {
  if (!token) return;
  if (typeof navigator !== "undefined" && !navigator.onLine) return;

  const entries = (await getQueueEntries()) as QueueEntry[];
  const res = await fetchWithTimeout(
    "/api/device-sync-control",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        action: "report_status",
        queue_status: buildQueueStatus(entries),
        sync_metrics: metrics,
      }),
    },
    10_000
  );

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(text || `HTTP ${res.status}`);
  }
}

async function reportSyncFailure(
  token: string,
  id: number,
  payload: QueuePayload,
  attempts: number,
  message: string,
  retryClass: "retryable" | "fatal",
  nextRetryAt?: number
) {
  if (!token || typeof navigator !== "undefined" && !navigator.onLine) return;

  const res = await fetchWithTimeout(
    "/api/device-sync-error",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        queue_id: id,
        operation: getQueueOperation(payload),
        payload,
        error_message: message,
        retry_class: retryClass,
        attempts,
        next_retry_at: nextRetryAt ?? null,
      }),
    },
    5_000
  );

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(text || `HTTP ${res.status}`);
  }
}

async function markQueueFailure(
  token: string,
  id: number,
  payload: QueuePayload,
  attempts: number,
  err: unknown
) {
  const message = getErrorText(err) || "Unbekannter Fehler";
  const fatal = isMemberMissingError(message);
  const retryClass = fatal ? "fatal" : "retryable";
  const nextRetryAt = fatal ? undefined : Date.now() + getNextRetryDelayMs(attempts);

  await updateQueueEntry(id, {
    status: "failed",
    attempts,
    lastError: message,
    retryClass,
    nextRetryAt,
  });

  void reportSyncFailure(
    token,
    id,
    payload,
    attempts,
    message,
    retryClass,
    nextRetryAt
  ).catch((logErr) => {
    console.warn("[offlineSync.reportSyncFailure] Fehler konnte nicht zentral geloggt werden", logErr);
  });
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
  payload: QueuePayload | Record<string, unknown>
): Promise<unknown> {
  const res = await fetchWithTimeout(endpoint, {
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
  if (syncInFlight) {
    // Ein laufender Sync könnte den letzten Queue-Read schon hinter sich haben;
    // nach Abschluss direkt einen Folgelauf starten, damit neue Einträge nicht
    // bis zum nächsten Poller-Zyklus liegen bleiben.
    rerunRequested = true;
    return syncInFlight;
  }

  syncInFlight = (async () => {
    if (!navigator.onLine) return 0;
    const startedAt = new Date();
    const startedPerf = getPerformanceNow();
    let successCount = 0;
    const attemptedThisRun = new Set<number>();
    const metrics: SyncRunMetrics = {
      started_at: startedAt.toISOString(),
      attempted_count: 0,
      success_count: 0,
      failed_count: 0,
      book_count: 0,
      cancel_count: 0,
      batch_count: 0,
      avg_item_ms: null,
      error_message: null,
    };

    function shouldAttemptEntry(entry: QueueEntry) {
      const id = Number(entry?.id ?? 0);
      if (!Number.isFinite(id) || id <= 0) return false;
      if (attemptedThisRun.has(id)) return false;

      const status = entry?.status ?? "pending";
      if (status === "failed") {
        if (entry?.retryClass === "fatal") return false;
        const nextRetryAt = Number(entry?.nextRetryAt ?? 0);
        return nextRetryAt <= Date.now();
      }
      return true;
    }

    const processEntry = async (entry: QueueEntry): Promise<boolean> => {
      const id = Number(entry?.id ?? 0);
      if (!Number.isFinite(id) || id <= 0) return false;
      attemptedThisRun.add(id);

      const payload = (entry?.payload ?? {}) as QueuePayload;
      const attempts = Number(entry?.attempts ?? 0) + 1;
      metrics.attempted_count += 1;

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
          metrics.cancel_count += 1;
          await callEF(token, "/api/cancel-transaction", {
            cancel_tx_id: payload.cancel_tx_id ?? null,
            member_id: payload.member_id,
            product_id: payload.product_id ?? null,
            note: payload.note ?? null,
            // Idempotenz: verhindert Doppel-Storno bei Timeout + Retry
            client_tx_id: payload.client_tx_id ?? null,
          });
        } else {
          metrics.book_count += 1;
          await callEF(token, "/api/book-transaction", {
            member_id: payload.member_id,
            product_id: payload.product_id,
            free_amount: payload.amount,
            p_transaction_type: payload.transaction_type ?? null,
            p_note: payload.note ?? null,
            client_tx_id_param: payload.client_tx_id ?? crypto.randomUUID(),
          });
        }

        await deleteQueueEntry(id);
        return true;
      } catch (err) {
        await markQueueFailure(token, id, payload, attempts, err);
        console.error("[offlineSync.syncQueue] Fehler bei Queue-ID", id, err);
        return false;
      }
    };

    const processBookingRun = async (run: QueueEntry[]) => {
      if (!run.length) return 0;
      let runSuccess = 0;

      for (let start = 0; start < run.length; start += BOOKING_SYNC_BATCH_SIZE) {
        const slice = run.slice(start, start + BOOKING_SYNC_BATCH_SIZE);
        const attemptsById = new Map<number, number>();
        type BatchItem = {
          queue_id: number; member_id: string; product_id: string | null;
          free_amount: number; p_transaction_type: string | null;
          p_note: string | null; client_tx_id_param: string;
        };
        const payloadItems: BatchItem[] = [];

        for (const entry of slice) {
          const id = Number(entry?.id ?? 0);
          if (!Number.isFinite(id) || id <= 0) continue;
          attemptedThisRun.add(id);
          const payload = (entry?.payload ?? {}) as QueuePayload;
          const attempts = Number(entry?.attempts ?? 0) + 1;
          attemptsById.set(id, attempts);
          metrics.attempted_count += 1;
          metrics.book_count += 1;

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

        let results: Record<string, unknown>[] = [];
        try {
          metrics.batch_count += 1;
          const response = await callEF(token, "/api/book-transactions-batch", {
            items: payloadItems,
          }) as Record<string, unknown>;
          results = Array.isArray(response?.results) ? (response.results as Record<string, unknown>[]) : [];
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
              await markQueueFailure(
                token,
                id,
                {
                  member_id: item.member_id,
                  product_id: item.product_id,
                  amount: item.free_amount,
                  transaction_type: item.p_transaction_type as QueuePayload["transaction_type"],
                  note: item.p_note,
                  client_tx_id: item.client_tx_id_param,
                },
                attemptsById.get(id) ?? 1,
                singleErr || err
              );
            }
          }
          continue;
        }

        const byQueueId = new Map<number, Record<string, unknown>>();
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

          await markQueueFailure(
            token,
            id,
            {
              member_id: item.member_id,
              product_id: item.product_id,
              amount: item.free_amount,
              transaction_type: item.p_transaction_type as QueuePayload["transaction_type"],
              note: item.p_note,
              client_tx_id: item.client_tx_id_param,
            },
            attemptsById.get(id) ?? 1,
            String(result?.error ?? "Batch-Sync fehlgeschlagen")
          );
        }
      }

      return runSuccess;
    };

    try {
      while (navigator.onLine) {
        const entries = (await getQueueEntries() as QueueEntry[])
          .filter(shouldAttemptEntry)
          .sort((a, b) => Number(a?.id ?? 0) - Number(b?.id ?? 0));

        if (!entries.length) break;

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

          const run: QueueEntry[] = [];
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
      }

      if (successCount > 0) {
        console.log(`[offlineSync] ${successCount} Einträge synchronisiert`);
      }
      return successCount;
    } catch (err) {
      metrics.error_message = getErrorText(err) || "Sync fehlgeschlagen";
      throw err;
    } finally {
      metrics.finished_at = new Date().toISOString();
      metrics.duration_ms = Math.max(0, Math.round(getPerformanceNow() - startedPerf));
      metrics.success_count = successCount;
      metrics.failed_count = Math.max(0, metrics.attempted_count - successCount);
      metrics.avg_item_ms = metrics.attempted_count > 0
        ? Math.round((metrics.duration_ms / metrics.attempted_count) * 10) / 10
        : null;

      if (metrics.attempted_count > 0 || metrics.error_message) {
        void reportSyncMetrics(token, metrics).catch((err) => {
          console.warn("[offlineSync.reportSyncMetrics] Sync-Metriken konnten nicht gemeldet werden", err);
        });
      }
    }
  })();

  try {
    return await syncInFlight;
  } finally {
    syncInFlight = null;
    if (rerunRequested) {
      rerunRequested = false;
      void syncQueue(token).catch(() => {});
    }
  }
}
