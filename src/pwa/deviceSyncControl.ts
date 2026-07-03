import { syncQueue } from "@/pwa/offlineSync";
import { fetchWithTimeout } from "@/utils/fetchWithTimeout";
import {
  deleteQueueEntry,
  getQueueEntries,
  resetFailedQueueRetries,
  type QueueEntry,
} from "@/utils/offlineDB";

export type DeviceQueueStatus = {
  pending_count: number;
  failed_count: number;
  total_count: number;
  fatal_failed_count: number;
  retryable_failed_count: number;
};

type DeviceCommand = {
  id: string;
  command: "sync_now" | string;
  payload?: Record<string, unknown> | null;
  requested_at?: string | null;
};

let pollTimerId: number | null = null;
let commandPollInFlight = false;

const COMMAND_POLL_INTERVAL_MS = 30_000;

export async function getLocalQueueStatus(): Promise<DeviceQueueStatus> {
  const entries = (await getQueueEntries()) as QueueEntry[];
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

async function postDeviceSyncControl(
  token: string,
  payload: Record<string, unknown>,
  timeoutMs = 10_000
): Promise<Record<string, unknown>> {
  const res = await fetchWithTimeout(
    "/api/device-sync-control",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(payload),
    },
    timeoutMs
  );

  const text = await res.text().catch(() => "");
  if (!res.ok) {
    throw new Error(text || `HTTP ${res.status}`);
  }

  try {
    return JSON.parse(text) as Record<string, unknown>;
  } catch {
    return {};
  }
}

export async function reportDeviceQueueStatus(token: string): Promise<void> {
  if (!token) return;
  if (typeof navigator !== "undefined" && !navigator.onLine) return;

  const queueStatus = await getLocalQueueStatus();
  await postDeviceSyncControl(token, {
    action: "report_status",
    queue_status: queueStatus,
  });
}

async function deleteLocalQueueEntryFromCommand(
  command: DeviceCommand
): Promise<{ queueId: number; deleted: boolean; alreadyMissing: boolean }> {
  const payload = command.payload && typeof command.payload === "object"
    ? command.payload
    : {};
  const queueId = Math.floor(Number(payload.client_queue_id ?? 0));
  if (!Number.isFinite(queueId) || queueId <= 0) {
    throw new Error("client_queue_id fehlt");
  }

  const entries = (await getQueueEntries()) as QueueEntry[];
  const entry = entries.find((item) => Number(item.id ?? 0) === queueId);
  if (!entry) {
    return { queueId, deleted: false, alreadyMissing: true };
  }

  const expectedClientTxId = String(payload.client_tx_id ?? "").trim();
  const actualClientTxId = String(entry.payload?.client_tx_id ?? "").trim();
  if (expectedClientTxId && actualClientTxId && expectedClientTxId !== actualClientTxId) {
    throw new Error("client_tx_id passt nicht zum lokalen Queue-Eintrag");
  }

  await deleteQueueEntry(queueId);
  return { queueId, deleted: true, alreadyMissing: false };
}

export async function pollAndRunDeviceCommands(token: string): Promise<void> {
  if (commandPollInFlight) return;
  if (!token) return;
  if (typeof navigator !== "undefined" && !navigator.onLine) return;

  commandPollInFlight = true;
  try {
    const queueStatus = await getLocalQueueStatus();
    const response = await postDeviceSyncControl(token, {
      action: "poll",
      queue_status: queueStatus,
    });
    const commands = Array.isArray(response.commands)
      ? (response.commands as DeviceCommand[])
      : [];

    for (const command of commands) {
      if (!command.id) continue;

      if (command.command === "delete_queue_entry") {
        try {
          const deleteResult = await deleteLocalQueueEntryFromCommand(command);
          if (typeof window !== "undefined") {
            window.dispatchEvent(
              new CustomEvent("queue-synced", {
                detail: { deleted_queue_id: deleteResult.queueId },
              })
            );
          }
          await postDeviceSyncControl(token, {
            action: "complete",
            command_id: command.id,
            success: true,
            processed_count: 0,
            deleted_queue_id: deleteResult.queueId,
            queue_entry_deleted: deleteResult.deleted,
            queue_entry_already_missing: deleteResult.alreadyMissing,
            queue_status: await getLocalQueueStatus(),
          });
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err ?? "Queue-Loeschen fehlgeschlagen");
          await postDeviceSyncControl(token, {
            action: "complete",
            command_id: command.id,
            success: false,
            processed_count: 0,
            error: message,
            queue_status: await getLocalQueueStatus(),
          }).catch((completeErr) => {
            console.warn("[deviceSyncControl.delete.complete]", completeErr);
          });
        }
        continue;
      }

      if (command.command !== "sync_now") {
        await postDeviceSyncControl(token, {
          action: "complete",
          command_id: command.id,
          success: false,
          processed_count: 0,
          error: `Unbekannter Geräte-Command: ${command.command}`,
          queue_status: await getLocalQueueStatus(),
        }).catch((completeErr) => {
          console.warn("[deviceSyncControl.unknown.complete]", completeErr);
        });
        continue;
      }

      let releasedFailedCount = 0;
      try {
        releasedFailedCount = await resetFailedQueueRetries();
        const processed = await syncQueue(token);
        if ((processed > 0 || releasedFailedCount > 0) && typeof window !== "undefined") {
          window.dispatchEvent(
            new CustomEvent("queue-synced", {
              detail: { processed, released_failed_count: releasedFailedCount },
            })
          );
        }
        await postDeviceSyncControl(token, {
          action: "complete",
          command_id: command.id,
          success: true,
          processed_count: processed,
          released_failed_count: releasedFailedCount,
          queue_status: await getLocalQueueStatus(),
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err ?? "Sync fehlgeschlagen");
        await postDeviceSyncControl(token, {
          action: "complete",
          command_id: command.id,
          success: false,
          processed_count: 0,
          released_failed_count: releasedFailedCount,
          error: message,
          queue_status: await getLocalQueueStatus(),
        }).catch((completeErr) => {
          console.warn("[deviceSyncControl.complete]", completeErr);
        });
      }
    }
  } catch (err) {
    console.warn("[deviceSyncControl.poll]", err);
  } finally {
    commandPollInFlight = false;
  }
}

function clearDeviceSyncControlPoller() {
  if (pollTimerId !== null) {
    window.clearTimeout(pollTimerId);
    pollTimerId = null;
  }
}

function scheduleNextPoll(getToken: () => string | null, delayMs = COMMAND_POLL_INTERVAL_MS) {
  if (typeof window === "undefined") return;
  clearDeviceSyncControlPoller();
  pollTimerId = window.setTimeout(() => {
    pollTimerId = null;
    void runPollCycle(getToken);
  }, delayMs);
}

async function runPollCycle(getToken: () => string | null) {
  await pollAndRunDeviceCommands(getToken() ?? "");
  scheduleNextPoll(getToken);
}

export function startDeviceSyncControlPoller(getToken: () => string | null): void {
  if (typeof window === "undefined") return;
  if (pollTimerId !== null) return;

  void runPollCycle(getToken);

  window.addEventListener("online", () => {
    void pollAndRunDeviceCommands(getToken() ?? "");
  });
  window.addEventListener("focus", () => {
    void pollAndRunDeviceCommands(getToken() ?? "");
  });
}
