export type ReleaseNoteTheme =
  | "articles"
  | "bookings"
  | "reports"
  | "inventory"
  | "devices"
  | "quality";

export type ReleaseNoteChangeType = "new" | "improved" | "fixed" | "operations";

export type ReleaseNoteSection = {
  theme: ReleaseNoteTheme;
  title: string;
  description: string;
  changes: string[];
};

export type ReleaseNoteArchiveEntry = {
  id: string;
  theme: ReleaseNoteTheme;
  type: ReleaseNoteChangeType;
  title: string;
};

export type ReleaseNoteArchiveGroup = {
  date: string;
  dateLabel: string;
  entries: ReleaseNoteArchiveEntry[];
};

export const releaseNotesOverview = {
  eyebrow: "Produkt-Update",
  title: "Was ist neu bei ClubCashBuddy?",
  description:
    "Die wichtigsten Neuerungen der vergangenen sieben Tage – verständlich zusammengefasst für Kassenbetrieb und Vereinsverwaltung.",
  periodLabel: "26. Juli–1. August 2026 · letzte 7 Tage",
  lastUpdated: "Aktualisiert am 1. August 2026",
  highlights: [
    { value: "2", label: "dokumentierte Änderungen" },
    { value: "2", label: "neue Funktionen" },
    { value: "2", label: "betroffene Themenbereiche" },
  ],
  overviewTitle: "Diese Woche im Fokus",
  overviewDescription:
    "Umsatzneutrale Stammartikel schaffen eine saubere Trennung in der Auswertung, während die neue Änderungshistorie Neuerungen dauerhaft nachvollziehbar macht.",
  sections: [
    {
      theme: "articles" as ReleaseNoteTheme,
      title: "Artikel & Buchungen",
      description: "Feste Artikel können jetzt gezielt außerhalb des Umsatzes geführt werden.",
      changes: [
        "Artikel lassen sich im Artikelstamm als umsatzneutral kennzeichnen – zum Beispiel Startgelder, die später als Preisgeld ausgeschüttet werden.",
        "Die Kennzeichnung gilt unabhängig von der Lagerführung und wird bei jeder neuen Buchung dauerhaft gespeichert.",
      ],
    },
    {
      theme: "reports" as ReleaseNoteTheme,
      title: "Auswertung & Transparenz",
      description: "Kennzahlen bleiben fachlich sauber und Produktänderungen nachvollziehbar.",
      changes: [
        "Umsatzneutrale Artikel fließen weder in Umsatz, Wareneinsatz noch Marge ein und können in den Berichten separat gefiltert werden.",
        "Eine neue Release-Notes-Seite verbindet eine kompakte Sieben-Tage-Übersicht mit einem dauerhaft gepflegten Änderungsarchiv.",
      ],
    },
  ] satisfies ReleaseNoteSection[],
};

export const releaseNotesArchive: ReleaseNoteArchiveGroup[] = [
  {
    date: "2026-08-01",
    dateLabel: "1. August 2026",
    entries: [
      {
        id: "release-notes-page-and-archive",
        theme: "quality",
        type: "new",
        title: "Release Notes zeigen die wichtigsten Änderungen der letzten sieben Tage und führen zusätzlich ein dauerhaftes, durchsuchbares Archiv.",
      },
      {
        id: "revenue-neutral-products",
        theme: "articles",
        type: "new",
        title: "Feste Artikel können als umsatzneutral geführt und getrennt von Umsatz und Marge ausgewertet werden.",
      },
    ],
  },
  {
    date: "2026-07-17",
    dateLabel: "17. Juli 2026",
    entries: [
      {
        id: "mark-booking-complimentary",
        theme: "bookings",
        type: "new",
        title: "Produktbuchungen lassen sich nachträglich als Freigetränk kennzeichnen und entsprechend umsatzneutral auswerten.",
      },
    ],
  },
  {
    date: "2026-07-12",
    dateLabel: "12. Juli 2026",
    entries: [
      {
        id: "order-suggestion-delivery-time",
        theme: "inventory",
        type: "improved",
        title: "Bestellvorschläge berücksichtigen Lieferzeit, Sicherheitsaufschlag und wählbare Betrachtungszeiträume genauer.",
      },
      {
        id: "order-suggestion-auto-refresh",
        theme: "inventory",
        type: "improved",
        title: "Bestellvorschläge aktualisieren ihre Daten automatisch und bieten Schnellfilter für 30, 60 und 90 Tage.",
      },
    ],
  },
  {
    date: "2026-07-09",
    dateLabel: "9. Juli 2026",
    entries: [
      {
        id: "product-activity-report",
        theme: "reports",
        type: "new",
        title: "Der Artikelreport bündelt Verkäufe, MHD-Anteil, Umsatz, Wareneinsatz und Bestandsentwicklung je Artikel.",
      },
      {
        id: "package-size-order-suggestions",
        theme: "inventory",
        type: "new",
        title: "Gebindegrößen können im Artikelstamm gepflegt und für Bestellvorschläge verwendet werden.",
      },
      {
        id: "cancel-storage-delivery",
        theme: "inventory",
        type: "new",
        title: "Noch vorhandene Mengen einer Einlagerung können kontrolliert storniert werden.",
      },
    ],
  },
  {
    date: "2026-07-08",
    dateLabel: "8. Juli 2026",
    entries: [
      {
        id: "mhd-product-pricing",
        theme: "articles",
        type: "new",
        title: "Geeignete Artikel unterstützen einen gesonderten MHD-Verkauf mit angepasstem Preis und eindeutiger Kennzeichnung.",
      },
    ],
  },
  {
    date: "2026-07-06",
    dateLabel: "6. Juli 2026",
    entries: [
      {
        id: "simplified-stock-model",
        theme: "inventory",
        type: "improved",
        title: "Die Lagerführung verwendet ein vereinfachtes Bestandsmodell ohne getrennten Kühlschrankbestand.",
      },
      {
        id: "stock-shortage-report",
        theme: "reports",
        type: "new",
        title: "Fehlbestände und manuelle Bestandsanpassungen sind in einem eigenen Bericht nachvollziehbar.",
      },
    ],
  },
  {
    date: "2026-07-05",
    dateLabel: "5. Juli 2026",
    entries: [
      {
        id: "revenue-margin-report",
        theme: "reports",
        type: "new",
        title: "Der Umsatzreport weist Wareneinsatz, Rohertrag und Marge anhand gespeicherter Einkaufskosten aus.",
      },
      {
        id: "revenue-heatmap-timezone",
        theme: "reports",
        type: "fixed",
        title: "Die Aktivitäts-Heatmap ordnet Buchungen zuverlässig der lokalen Berliner Zeit zu.",
      },
      {
        id: "cancellation-revenue-semantics",
        theme: "bookings",
        type: "fixed",
        title: "Stornos stellen Kosten- und Umsatzwerte in den Auswertungen konsistent wieder her.",
      },
    ],
  },
  {
    date: "2026-07-04",
    dateLabel: "4. Juli 2026",
    entries: [
      {
        id: "member-archive",
        theme: "quality",
        type: "new",
        title: "Mitglieder können archiviert und bei Bedarf wiederhergestellt werden, ohne historische Buchungen zu verlieren.",
      },
      {
        id: "admin-navigation-layout",
        theme: "quality",
        type: "improved",
        title: "Das Adminportal gruppiert Stammdaten, Vorgänge, Berichte und Systemfunktionen in einer responsiven Navigation.",
      },
    ],
  },
  {
    date: "2026-07-03",
    dateLabel: "3. Juli 2026",
    entries: [
      {
        id: "device-sync-control",
        theme: "devices",
        type: "operations",
        title: "Geräte-Synchronisierung, fehlgeschlagene Queue-Einträge und erneute Übertragungsversuche lassen sich zentral überwachen.",
      },
    ],
  },
];

export const changeTypeLabels: Record<ReleaseNoteChangeType, string> = {
  new: "Neu",
  improved: "Verbessert",
  fixed: "Behoben",
  operations: "Betrieb",
};

export const themeLabels: Record<ReleaseNoteTheme, { label: string; icon: string }> = {
  articles: { label: "Artikel", icon: "🧃" },
  bookings: { label: "Buchungen", icon: "🧾" },
  reports: { label: "Berichte", icon: "📊" },
  inventory: { label: "Lager", icon: "📦" },
  devices: { label: "Geräte", icon: "🔁" },
  quality: { label: "Qualität", icon: "✨" },
};
