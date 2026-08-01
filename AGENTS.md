# Arbeitsregeln fuer Codex

## Release Notes

- Die Release-Notes-Seite unter `/admin/release-notes` besteht aus zwei Ebenen:
  - Die obere, kuratierte Uebersicht zeigt ausschliesslich die wichtigsten Aenderungen der jeweils letzten sieben Tage.
  - Das darunterliegende Aenderungsarchiv beginnt am 3. Juli 2026 und wird dauerhaft fortgefuehrt. Archiveintraege werden nicht entfernt, nur weil sie aelter als sieben Tage sind.
- Jeder Feature- oder Bugfix-Auftrag ergaenzt vor seinem Abschluss mindestens einen neuen Archiveintrag in `src/data/releaseNotes.ts`.
- Neue Archivgruppen und Eintraege stehen in absteigender Reihenfolge. Jede `id` muss dauerhaft eindeutig sein.
- Eintraege werden aus Sicht der Benutzerinnen, Benutzer oder des Betriebs formuliert. Interne Ticketnummern, Commit-Hashes und reine Implementierungsdetails gehoeren nicht in die Release Notes.
- Bei jeder Aenderung ist zusaetzlich zu pruefen, ob die kuratierte Sieben-Tage-Uebersicht, ihr Zeitraum, das Aktualisierungsdatum oder ihre Kennzahlen angepasst werden muessen.
- Ein Entwicklungsauftrag ist erst vollstaendig, wenn Anwendungscode, passender Release-Notes-Eintrag und relevante Dokumentation gemeinsam geprueft wurden.
