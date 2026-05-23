const DEFAULT_TIMEOUT_MS = 15_000;

export function fetchWithTimeout(
  input: string | URL | Request,
  init?: RequestInit,
  timeoutMs = DEFAULT_TIMEOUT_MS,
): Promise<Response> {
  const controller = new AbortController();
  const timerId = setTimeout(() => controller.abort(), timeoutMs);

  const signal =
    init?.signal
      ? mergeSignals(init.signal, controller.signal)
      : controller.signal;

  return fetch(input, { ...init, signal }).finally(() => clearTimeout(timerId));
}

function mergeSignals(a: AbortSignal, b: AbortSignal): AbortSignal {
  const ctrl = new AbortController();
  const abort = (reason: unknown) => ctrl.abort(reason);
  if (a.aborted) { ctrl.abort(a.reason); return ctrl.signal; }
  if (b.aborted) { ctrl.abort(b.reason); return ctrl.signal; }
  a.addEventListener("abort", () => abort(a.reason), { once: true });
  b.addEventListener("abort", () => abort(b.reason), { once: true });
  return ctrl.signal;
}
