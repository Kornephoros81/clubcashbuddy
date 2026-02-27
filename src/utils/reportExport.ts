export async function exportReportAsPdf(
  reportId: string,
  title: string,
): Promise<void> {
  const root = document.querySelector<HTMLElement>(`[data-report-id="${reportId}"]`);
  if (!root) {
    throw new Error("Reportbereich nicht gefunden");
  }

  const previousTitle = document.title;
  let cleaned = false;

  const cleanup = () => {
    if (cleaned) return;
    cleaned = true;
    document.title = previousTitle;
    document.body.classList.remove("report-print-mode");
    root.classList.remove("print-report-target");
  };

  root.classList.add("print-report-target");
  document.body.classList.add("report-print-mode");
  document.title = title;

  const afterPrintHandler = () => cleanup();
  window.addEventListener("afterprint", afterPrintHandler, { once: true });

  await new Promise((resolve) => setTimeout(resolve, 80));
  window.print();

  setTimeout(() => cleanup(), 1500);
}

