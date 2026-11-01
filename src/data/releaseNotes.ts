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
  periodLabel: "26. Oktober–1. November 2026 · letzte 7 Tage",
  lastUpdated: "Aktualisiert am 1. November 2026",
  highlights: [
    { value: "2", label: "dokumentierte Änderungen" },
    { value: "1", label: "neue Funktion" },
    { value: "1", label: "betroffener Themenbereich" },
  ],
  overviewTitle: "Diese Woche im Fokus",
  overviewDescription:
    "Der Umsatzreport zeigt jetzt, wie sich der Umsatz auf Mitglieder und Gäste verteilt – so wird der Einfluss des Gastverzehrs auf die Vereinsfinanzen sichtbar.",
  sections: [
    {
      theme: "reports" as ReleaseNoteTheme,
      title: "Auswertung & Transparenz",
      description: "Mitglieder- und Gastumsatz lassen sich getrennt auswerten und drucken.",
      changes: [
        "Der Umsatzreport stellt Umsatz, Anteil, Buchungen, Käufer, Stornos, Wareneinsatz und Rohgewinn für Mitglieder und Gäste gegenüber; die Summe ergibt den Gesamtumsatz.",
        "Über den neuen Filter „Mitglieder / Gäste“ lässt sich der gesamte Report auf eine der beiden Gruppen einschränken. Der Umsatzverlauf zeigt den Gästeanteil zusätzlich als eigene Kurve.",
        "Der getrennt ausgewiesene Gästeumsatz erleichtert den groben Abgleich mit dem Barbestand der Kasse.",
        "Die Schaltflächen zum Drucken heißen jetzt einheitlich „Drucken / PDF“; im Druckdialog des Browsers kann der Bericht als PDF gespeichert werden.",
      ],
    },
  ] satisfies ReleaseNoteSection[],
};

function releaseEntry(
  commit: string,
  theme: ReleaseNoteTheme,
  type: ReleaseNoteChangeType,
  title: string,
): ReleaseNoteArchiveEntry {
  return { id: `git-${commit}`, theme, type, title };
}

export const releaseNotesArchive: ReleaseNoteArchiveGroup[] = [
  {
    date: "2026-11-01",
    dateLabel: "1. November 2026",
    entries: [
      {
        id: "revenue-report-members-guests-split",
        theme: "reports",
        type: "new",
        title: "Der Umsatzreport trennt Umsatz, Wareneinsatz und Rohgewinn nach Mitgliedern und Gästen und bietet einen Filter „Mitglieder / Gäste“.",
      },
      {
        id: "report-print-pdf-button-label",
        theme: "reports",
        type: "improved",
        title: "Die Druckfunktion der Berichte heißt einheitlich „Drucken / PDF“ und weist damit auf das Speichern als PDF hin.",
      },
    ],
  },
  {
    date: "2026-08-01",
    dateLabel: "1. August 2026",
    entries: [
      {
        id: "keep-product-member-editors-open-on-backdrop-click",
        theme: "articles",
        type: "fixed",
        title: "Pflegeansichten für Artikel und Mitglieder schließen nicht mehr durch einen Klick außerhalb des Dialogs; Eingaben können nur noch über die vorgesehenen Aktionen verlassen werden.",
      },
      {
        id: "retroactive-revenue-neutral-product-bookings",
        theme: "bookings",
        type: "improved",
        title: "Beim Umstellen eines Artikels auf umsatzneutral werden nach ausdrücklicher Bestätigung auch alle bisherigen normalen Buchungen und Stornos rückwirkend umgestellt.",
      },
      releaseEntry("c1709a8", "quality", "improved", "Das Änderungsarchiv umfasst jetzt die vollständige inhaltliche Commit-Historie seit der ersten öffentlichen Version."),
      releaseEntry("8bdba70", "quality", "new", "Release Notes zeigen die wichtigsten Änderungen der letzten sieben Tage und führen zusätzlich ein dauerhaftes, durchsuchbares Archiv."),
      releaseEntry("3926166", "articles", "new", "Feste Artikel können als umsatzneutral geführt und getrennt von Umsatz und Marge ausgewertet werden."),
    ],
  },
  {
    date: "2026-07-17",
    dateLabel: "17. Juli 2026",
    entries: [
      releaseEntry("8e30ad3", "bookings", "new", "Produktbuchungen lassen sich nachträglich als Freigetränk kennzeichnen und entsprechend umsatzneutral auswerten."),
    ],
  },
  {
    date: "2026-07-12",
    dateLabel: "12. Juli 2026",
    entries: [
      releaseEntry("d6f6742", "inventory", "improved", "Bestellvorschläge berücksichtigen die erwartete Lieferzeit bei der Bedarfsermittlung."),
      releaseEntry("5defc5e", "inventory", "improved", "Bestellvorschläge laden ihre Berechnungsgrundlage nach Änderungen automatisch neu."),
      releaseEntry("22dd06a", "inventory", "new", "Schnellfilter ermöglichen Bestellprognosen für 30, 60 oder 90 Tage."),
      releaseEntry("5389355", "inventory", "improved", "Die Prognoselogik für Bestellvorschläge berücksichtigt Verbrauch und Sicherheitsbedarf genauer."),
    ],
  },
  {
    date: "2026-07-09",
    dateLabel: "9. Juli 2026",
    entries: [
      releaseEntry("98ac3d2", "inventory", "improved", "Die Einlagerungsansicht zeigt geänderte Mengen und Kosten übersichtlicher an."),
      releaseEntry("fcc6949", "inventory", "improved", "Bestellvorschläge wurden gestrafft und ihre Bedarfsauswertung präzisiert."),
      releaseEntry("2bd4344", "inventory", "fixed", "Stornierte Einlagerungen erscheinen nicht mehr fälschlich als normale Bestandsanpassung."),
      releaseEntry("834a83a", "inventory", "new", "Restmengen einer Einlagerung können kontrolliert storniert werden; Bestellvorschläge beachten Gebindegrößen."),
      releaseEntry("4cf012a", "inventory", "fixed", "Fehler beim Speichern einer Einlagerung werden verständlicher angezeigt."),
      releaseEntry("f5c8703", "inventory", "new", "Ein neuer Bestellvorschlag berechnet den erwarteten Nachbestellbedarf je Artikel."),
      releaseEntry("a4afa40", "reports", "new", "Der Artikelreport bündelt Verkäufe, MHD-Anteil, Umsatz, Wareneinsatz und Bestandsentwicklung; Gebindegrößen ergänzen den Artikelstamm."),
    ],
  },
  {
    date: "2026-07-08",
    dateLabel: "8. Juli 2026",
    entries: [
      releaseEntry("73df218", "articles", "improved", "MHD-Preise und Artikelkacheln sind im Terminal klarer und platzsparender dargestellt."),
      releaseEntry("674125f", "articles", "improved", "Die Artikelauswahl im Terminal wurde durch Entfernen des entbehrlichen Suchfelds vereinfacht."),
      releaseEntry("780e6d5", "articles", "improved", "Die Beschriftung für MHD-Verkäufe wurde verständlicher formuliert."),
      releaseEntry("14905c3", "articles", "new", "Im Artikelstamm lässt sich festlegen, welche Artikel für einen MHD-Verkauf vorgesehen sind."),
    ],
  },
  {
    date: "2026-07-07",
    dateLabel: "7. Juli 2026",
    entries: [
      releaseEntry("39dd185", "articles", "new", "Ein eigener MHD-Ablauf erlaubt rabattierte Artikelbuchungen mit nachvollziehbarer Kennzeichnung."),
      releaseEntry("4a46cc3", "inventory", "improved", "Bestandsbewegungen verwenden aussagekräftigere Begründungen."),
    ],
  },
  {
    date: "2026-07-06",
    dateLabel: "6. Juli 2026",
    entries: [
      releaseEntry("6a81071", "inventory", "improved", "Die Lagerführung verwendet ein einheitliches Bestandsmodell ohne getrennten Kühlschrankbestand."),
      releaseEntry("99d3de8", "reports", "new", "Fehlbestände und manuelle Bestandsanpassungen sind in einem eigenen Bericht nachvollziehbar."),
      releaseEntry("4c5427b", "inventory", "fixed", "Der Inventurabgleich verwendet zuverlässig den gesamten verfügbaren Artikelbestand."),
      releaseEntry("2831727", "inventory", "improved", "Der separate Kühlschrank-Nachfüllablauf wurde zugunsten der vereinfachten Lagerführung entfernt."),
    ],
  },
  {
    date: "2026-07-05",
    dateLabel: "5. Juli 2026",
    entries: [
      releaseEntry("f34ad4a", "devices", "fixed", "Das Leistungsdiagramm stellt Messreihen auch bei unterschiedlichen Datenmengen korrekt dar."),
      releaseEntry("f791244", "reports", "fixed", "Die Aktivitäts-Heatmap ordnet Buchungen zuverlässig der lokalen Berliner Zeit zu."),
      releaseEntry("0b5a181", "reports", "new", "Der Umsatzreport weist Wareneinsatz, Rohertrag und Marge anhand gespeicherter Einkaufskosten aus."),
      releaseEntry("652ad7e", "reports", "improved", "Dashboard und Umsatzreport wurden bei gleichbleibenden Kennzahlen übersichtlicher gestaltet."),
      releaseEntry("80c67b5", "reports", "improved", "Umsatzreport und Dashboard bieten verbesserte Diagramme, Druckansichten und kompaktere Kennzahlen."),
      releaseEntry("5911411", "reports", "new", "Zusätzliche Schnellzeiträume erleichtern wiederkehrende Auswertungen."),
      releaseEntry("0ca0c67", "bookings", "fixed", "Stornos stellen Kosten- und Umsatzwerte in den Auswertungen konsistent wieder her."),
      releaseEntry("4fe542f", "inventory", "fixed", "Einkaufskosten nicht inventarisierter Artikel und nachträgliche Kostenkorrekturen werden stabiler verarbeitet."),
      releaseEntry("ee872cf", "articles", "new", "Artikelpflege und Einlagerung unterstützen Einkaufspreise als Grundlage für Bestandswert und Marge."),
    ],
  },
  {
    date: "2026-07-04",
    dateLabel: "4. Juli 2026",
    entries: [
      releaseEntry("8c1f36d", "quality", "fixed", "Datenbankmigrationen wurden für unterschiedliche bestehende Installationsstände robuster gemacht."),
      releaseEntry("8944025", "inventory", "fixed", "Fallback-Einkaufskosten lassen sich nachträglich korrigieren und werden in der Lageransicht transparenter dargestellt."),
      releaseEntry("b6cb860", "inventory", "fixed", "Verkäufe ohne passende Einkaufschargen erhalten eine stabile Fallback-Kostenbewertung."),
      releaseEntry("abced02", "devices", "new", "Ein Leistungsdiagramm macht Dauer und Umfang der Geräte-Synchronisierung sichtbar."),
      releaseEntry("5403c91", "bookings", "fixed", "Die benötigte Abrechnungsfunktion wird auch bei älteren Datenbankständen zuverlässig bereitgestellt."),
      releaseEntry("1dcdb18", "bookings", "fixed", "Mitgliedsabrechnungen verwenden die passende serverseitige Funktion und liefern eindeutige Ergebnisse."),
      releaseEntry("73b0a73", "devices", "new", "Synchronisationsläufe erfassen Laufzeit und verarbeitete Buchungen als Leistungskennzahlen."),
      releaseEntry("48091e3", "quality", "improved", "Die Mitgliederliste zeigt Status und Verwaltungsinformationen übersichtlicher an."),
      releaseEntry("bc9da73", "bookings", "improved", "Monatsabschluss und Mitgliederansicht erklären offene und bereits abgeschlossene Beträge klarer."),
      releaseEntry("e4f5457", "bookings", "fixed", "Der Monatsabschluss schließt die zugehörigen offenen Buchungen zuverlässig ab."),
      releaseEntry("2bad17f", "quality", "new", "Bestehende Mitgliedsdaten können direkt in der Verwaltung bearbeitet werden."),
      releaseEntry("d39d7e2", "quality", "new", "Mitglieder können archiviert und wiederhergestellt werden, ohne historische Buchungen zu verlieren."),
      releaseEntry("1f71b60", "quality", "improved", "Das Adminportal gruppiert Stammdaten, Vorgänge, Berichte und Systemfunktionen in einer responsiven Navigation."),
      releaseEntry("a36d094", "devices", "fixed", "Remote-Synchronisationsbefehle und deren Fehlerrückmeldungen wurden robuster abgesichert."),
      releaseEntry("2df0c6b", "devices", "improved", "Die Aktion zum erneuten Übertragen fehlgeschlagener Synchronisationen ist eindeutiger benannt."),
    ],
  },
  {
    date: "2026-07-03",
    dateLabel: "3. Juli 2026",
    entries: [
      releaseEntry("c33ee77", "devices", "new", "Fehlerhafte oder nicht mehr benötigte Einträge können kontrolliert aus der Synchronisationswarteschlange entfernt werden."),
      releaseEntry("56ee44b", "devices", "fixed", "Ein erneuter Synchronisationsbefehl nimmt zuvor fehlgeschlagene Einträge wieder in die Verarbeitung auf."),
      releaseEntry("47861a1", "devices", "new", "Administratoren können eine Gerätesynchronisierung zentral auslösen."),
      releaseEntry("320816e", "devices", "new", "Leistungskennzahlen und Remote-Steuerung erleichtern die Diagnose der Terminal-Synchronisierung."),
      releaseEntry("11e5e3b", "quality", "fixed", "Berichte, Terminal, Offline-Anzeige und Verwaltungsaktionen wurden technisch vereinheitlicht und sicherer gemacht."),
      releaseEntry("c51ef81", "quality", "operations", "Nicht mehr verwendete Altkomponenten und doppelte Sitzungslogik wurden entfernt."),
      releaseEntry("b36599d", "devices", "improved", "Aktualisierte Daten können in den Synchronisationsansichten gezielt neu geladen werden."),
      releaseEntry("bb24e74", "devices", "new", "Synchronisationsfehler werden mit Ursache und betroffenem Vorgang zentral protokolliert."),
    ],
  },
  {
    date: "2026-05-23",
    dateLabel: "23. Mai 2026",
    entries: [
      releaseEntry("a000593", "bookings", "improved", "Die Mitgliedersuche findet Gäste auch über naheliegende, unvollständige Suchangaben."),
      releaseEntry("5bf7e83", "bookings", "improved", "Das Terminal hebt wichtige Buchungsrückmeldungen mit einem gelben Hinweis deutlicher hervor."),
      releaseEntry("9436e76", "bookings", "fixed", "Für Gäste werden alle relevanten offenen Buchungen vollständig geladen."),
      releaseEntry("4a4bec5", "quality", "improved", "Mehrere Terminal- und Verwaltungsabläufe wurden auf schnellere und klarere Bedienung optimiert."),
      releaseEntry("6d74f8a", "devices", "new", "Fehlgeschlagene Offline-Buchungen erhalten abgestufte Wiederholungsversuche und eine administrative Übersicht."),
    ],
  },
  {
    date: "2026-04-26",
    dateLabel: "26. April 2026",
    entries: [
      releaseEntry("6127e16", "reports", "new", "Ein eigener Bericht wertet Freigetränke und deren Kosten aus."),
      releaseEntry("0d88306", "devices", "fixed", "Fehlgeschlagene Synchronisationsvorgänge können zuverlässig erneut angestoßen werden."),
      releaseEntry("d1a310d", "bookings", "improved", "Neue Buchungen stehen in Listen oberhalb bereits vorhandener Einträge."),
      releaseEntry("b21feeb", "bookings", "new", "Produktbuchungen können bei Gästeabrechnungen als Freigetränk behandelt werden."),
      releaseEntry("fc74949", "bookings", "new", "Die Gasterfassung bietet eine Suche nach bereits vorhandenen Gästen."),
    ],
  },
  {
    date: "2026-04-20",
    dateLabel: "20. April 2026",
    entries: [
      releaseEntry("740dc8e", "quality", "fixed", "Die Produktionsweiterleitung erreicht nach dem Deployment wieder zuverlässig die Anwendung."),
      releaseEntry("152bbdc", "inventory", "new", "Einkäufe werden als einzelne Chargen geführt und Verkäufen nach dem FIFO-Prinzip zugeordnet."),
    ],
  },
  {
    date: "2026-04-19",
    dateLabel: "19. April 2026",
    entries: [
      releaseEntry("90036e4", "inventory", "fixed", "Kosten-Snapshots, Sperren und nachträgliche Rekonstruktionen wurden für bestehende Datenbestände stabilisiert."),
      releaseEntry("042bcec", "inventory", "fixed", "Die Migration zur Einkaufskostenverfolgung berücksichtigt zusätzliche bestehende Funktionsvarianten."),
      releaseEntry("472a3d5", "quality", "fixed", "Zugriffsregeln für Kosten- und Produktdaten wurden nach dem Sicherheitsprinzip der geringsten Rechte gehärtet."),
      releaseEntry("d6a3d69", "inventory", "new", "Einkaufspreise werden pro Artikel und Buchung gespeichert und bilden die Grundlage für Bestandswert und Marge."),
    ],
  },
  {
    date: "2026-04-03",
    dateLabel: "3. April 2026",
    entries: [
      releaseEntry("583a75a", "reports", "improved", "Dashboard und Umsatzreport wurden umfassend erneuert; Terminal, Offline-Cache und Adminzugriffe arbeiten zugleich effizienter."),
    ],
  },
  {
    date: "2026-03-17",
    dateLabel: "17. März 2026",
    entries: [
      releaseEntry("3490ea3", "articles", "improved", "Produktbilder werden außerhalb der Datenbank im vorgesehenen Dateispeicher abgelegt."),
    ],
  },
  {
    date: "2026-03-15",
    dateLabel: "15. März 2026",
    entries: [
      releaseEntry("9957d6f", "articles", "improved", "Preischips auf Artikelkacheln benötigen weniger Platz."),
      releaseEntry("1ca96c9", "articles", "improved", "Artikelkacheln nutzen eine klarere Anordnung von Bild, Name und Preis."),
      releaseEntry("591cafb", "articles", "improved", "Produktbilder werden innerhalb der Artikelkacheln gleichmäßiger skaliert."),
      releaseEntry("e300193", "quality", "improved", "Das Terminal verteilt Mitglieder, Artikel und Buchungen ausgewogener auf die verfügbaren Spalten."),
      releaseEntry("aa0b4f5", "quality", "improved", "Nachnamen sind in der Mitgliederauswahl leichter erkennbar."),
    ],
  },
  {
    date: "2026-03-14",
    dateLabel: "14. März 2026",
    entries: [
      releaseEntry("972ae89", "quality", "fixed", "Die Terminalbereiche bleiben bei unterschiedlichen Bildschirmgrößen korrekt ausgerichtet."),
      releaseEntry("6246279", "bookings", "improved", "Die Elemente der Gast-Teilabrechnung wurden abschließend übersichtlicher angeordnet."),
      releaseEntry("613708f", "bookings", "fixed", "Die Gastbezeichnung erscheint in der Teilabrechnung nicht mehr doppelt."),
      releaseEntry("4f25c8d", "bookings", "improved", "Auswahl und Summen der Gast-Teilabrechnung wurden klarer voneinander getrennt."),
      releaseEntry("cbdb696", "bookings", "improved", "Aktionen der Gast-Teilabrechnung stehen in einer nachvollziehbareren Reihenfolge."),
      releaseEntry("e75c226", "bookings", "improved", "Buchungsgruppen in der Gast-Teilabrechnung sind kompakter dargestellt."),
      releaseEntry("cc303d4", "bookings", "improved", "Die Buchungshistorie kennzeichnet Tages- und Monatsgruppen eindeutiger."),
      releaseEntry("a8bf00d", "bookings", "improved", "Die Gast-Teilabrechnung bietet eine verständlichere Auswahl und Zusammenfassung der zu zahlenden Positionen."),
      releaseEntry("2dce6c8", "articles", "fixed", "Kategorieänderungen werden im Artikelstamm gespeichert und in Terminal sowie Offline-Cache übernommen."),
      releaseEntry("64a9b64", "quality", "improved", "Artikelbereich und Terminalnavigation nutzen den verfügbaren Platz kompakter."),
      releaseEntry("d54809a", "quality", "improved", "Der Terminalkopf ordnet Branding und Hauptaktionen klarer an."),
      releaseEntry("82500e2", "articles", "improved", "Sekundäre Angaben auf Artikelkacheln sind typografisch zurückhaltender."),
      releaseEntry("31729b4", "articles", "improved", "Artikelnamen und Zusatzinformationen sind ausgewogener gewichtet."),
      releaseEntry("ae86f49", "articles", "improved", "Preise erscheinen auf Artikelkacheln in einer besser lesbaren Position."),
      releaseEntry("289f972", "articles", "improved", "Die Preisdarstellung der Artikelkacheln wurde für schnelle Erfassung verfeinert."),
      releaseEntry("72be420", "articles", "improved", "Artikelkacheln reagieren deutlicher auf Berührung und Auswahl."),
      releaseEntry("fde2df9", "quality", "improved", "Eine entbehrliche Trennlinie wurde aus der Mitgliederauswahl entfernt."),
      releaseEntry("1413b45", "quality", "improved", "Schaltflächen und Interaktionszustände im Terminal wurden vereinheitlicht."),
      releaseEntry("a695b15", "quality", "operations", "Der vorübergehend erprobte dunkle Terminalstil wurde zugunsten der bewährten hellen Darstellung zurückgenommen."),
      releaseEntry("6bcc5c5", "quality", "new", "Ein dunkler Darstellungsentwurf für das Terminal wurde zur Erprobung eingeführt."),
      releaseEntry("b41993c", "quality", "improved", "Die Mitgliederauswahl erhielt weitere visuelle Detailverbesserungen."),
      releaseEntry("8002e29", "quality", "improved", "Buchungslisten, Mitgliederauswahl und Artikelkacheln wurden im neuen Terminaldesign weiter abgestimmt."),
      releaseEntry("e866a92", "quality", "improved", "Das Terminal wurde mit moderneren Karten, klareren Abständen und responsiver Struktur neu gestaltet."),
      releaseEntry("c70e2e6", "quality", "operations", "Die Projektdokumentation führt Installations- und Nutzungshinweise in einer sinnvolleren Reihenfolge auf."),
      releaseEntry("73cc040", "quality", "operations", "Die öffentliche Projektseite enthält einen transparenten Hinweis auf Unterstützungsmöglichkeiten."),
      releaseEntry("8ab0eec", "devices", "improved", "Gebündelte Datenabrufe und lokaler Cache reduzieren die Anzahl der API-Aufrufe im Terminal deutlich."),
    ],
  },
  {
    date: "2026-03-13",
    dateLabel: "13. März 2026",
    entries: [
      releaseEntry("64498f1", "reports", "fixed", "Top-Artikel berücksichtigen Stornos bei der ausgewiesenen Nettomenge."),
    ],
  },
  {
    date: "2026-03-10",
    dateLabel: "10. März 2026",
    entries: [
      releaseEntry("c22db76", "quality", "improved", "Das Vereinslogo wird als Symbol im Browser-Tab verwendet."),
      releaseEntry("bb4d266", "devices", "fixed", "Das Terminal startet die Hintergrundsynchronisierung nach dem Laden zuverlässig."),
    ],
  },
  {
    date: "2026-03-09",
    dateLabel: "9. März 2026",
    entries: [
      releaseEntry("b4564e1", "devices", "improved", "Im Offlinebetrieb blockiert eine nicht verfügbare PIN-Prüfung die Mitgliederauswahl nicht."),
      releaseEntry("abfe8ee", "devices", "fixed", "Die Hintergrundsynchronisierung läuft nach einzelnen Übertragungen kontinuierlich weiter."),
      releaseEntry("d369680", "quality", "operations", "Die vollständige Datenbank-Einrichtung wurde für eine erneute Bereitstellung aktualisiert."),
      releaseEntry("7bd28d7", "devices", "improved", "Kürzere Synchronisationswege bringen Offline-Buchungen schneller zum Server."),
      releaseEntry("ca2ff15", "quality", "improved", "Gespeichertes Vereinsbranding wird ohne unnötige Zwischenschritte in der Oberfläche verwendet."),
      releaseEntry("9670848", "reports", "fixed", "Eine doppelte Anzeige im Bericht zu Bestandsanpassungen wurde entfernt."),
      releaseEntry("88b808e", "reports", "improved", "Adminberichte sind auch auf Smartphones und schmalen Tablets vollständig nutzbar."),
      releaseEntry("8e459f8", "quality", "improved", "Mitglieder- und Artikelverwaltung passen sich an kleine Bildschirme an."),
      releaseEntry("61a611a", "quality", "improved", "Das Adminmenü bietet eine responsive Navigation für Mobilgeräte."),
      releaseEntry("57dc22b", "devices", "new", "Ein Synchronisations-Poller und eine Offline-Anzeige machen den Verbindungszustand des Terminals sichtbar."),
      releaseEntry("caf3b54", "quality", "fixed", "Eine Content-Security-Policy begrenzt zulässige externe Inhalte und Skriptquellen."),
      releaseEntry("1ff9f47", "quality", "fixed", "Authentifizierung, API-Zugriffe und Datenbankberechtigungen wurden umfassend gehärtet."),
    ],
  },
  {
    date: "2026-02-28",
    dateLabel: "28. Februar 2026",
    entries: [
      releaseEntry("e601671", "articles", "improved", "Kategorien lassen sich mit Status und Sortierung zentral verwalten."),
      releaseEntry("55e8c6b", "quality", "new", "Bei der Ersteinrichtung kann ein initialer Administrator sicher angelegt werden."),
      releaseEntry("7080d98", "quality", "improved", "Der konfigurierte Vereinsname erscheint als Titel im Browser-Tab."),
      releaseEntry("31a9297", "devices", "new", "Die Adminnavigation führt direkt zur Kopplung neuer Terminalgeräte."),
      releaseEntry("ec78633", "quality", "new", "Ein Benutzerhandbuch dokumentiert Terminal, Lager und Adminportal."),
      releaseEntry("b3ab9cf", "articles", "improved", "Bei gleicher Kategorie werden Artikel zusätzlich alphabetisch sortiert."),
      releaseEntry("398ee89", "articles", "new", "Die Artikelliste kann nach Name oder Kategorie sortiert werden."),
      releaseEntry("e60d753", "quality", "fixed", "Die neue Kategorienverwaltung ist über die korrekte Adminroute erreichbar."),
      releaseEntry("0ee5ccd", "articles", "new", "Produktkategorien können in einer eigenen Adminansicht angelegt und bearbeitet werden."),
      releaseEntry("6de96a7", "articles", "improved", "Artikel verwenden zentral gepflegte Kategorien statt frei eingegebener Kategorienamen."),
    ],
  },
  {
    date: "2026-02-27",
    dateLabel: "27. Februar 2026",
    entries: [
      releaseEntry("571cfb3", "quality", "new", "ClubCashBuddy wurde erstmals als öffentlich nutzbare Vereins- und Getränkekassenanwendung veröffentlicht."),
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
