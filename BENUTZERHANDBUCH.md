# Benutzerhandbuch - ClubCashBuddy

Dieses Handbuch beschreibt die Bedienung der Anwendung aus Sicht von Vereinsbetrieb und Administration.

## 1. Zweck der Anwendung
ClubCashBuddy ist eine Self-Service-Kassensoftware mit drei Hauptbereichen:
- `Terminal`: Buchungen für Mitglieder und Gäste
- `Nachfüllen`: Bestand im Kühlschrank/Lager pflegen
- `Adminportal`: Stammdaten, Auswertungen und Verwaltungsfunktionen

## 2. Rollen und Zugriff

### 2.1 Terminal-Geraet
- Beim ersten Start muss das Geraet per **Pairing-Code** aktiviert werden.
- Ohne gueltige Geraeteauthentifizierung wird ein Aktivierungsdialog angezeigt.
- Nach erfolgreicher Aktivierung startet das Terminal im Normalbetrieb.

### 2.2 Admin
- Login ueber `/login` mit Benutzername und Passwort.
- Der Adminbereich liegt unter `/admin/...`.
- Schutzmechanismen:
  - Automatischer Logout nach **5 Minuten Inaktivitaet** im Adminbereich.
  - Automatischer Logout nach **5 Minuten**, wenn man den Adminbereich verlaesst.

## 3. Terminal bedienen

### 3.1 Mitglied auswaehlen
1. Im Terminal ein Mitglied aus der Liste waehlen.
2. Falls fuer das Mitglied eine PIN hinterlegt ist, wird eine 4-stellige PIN abgefragt.
3. Nach erfolgreicher Auswahl erscheint die Buchungsansicht.

### 3.2 Produkte buchen
1. Produkt antippen.
2. Buchung wird in der Seitenleiste sichtbar.
3. Bereich "Heute gebucht" zeigt bestaetigte Buchungen, "Neu" zeigt aktuelle neue Buchungen.
4. Ueber Rueckgaengig-Funktion (Undo) kann eine Buchung storniert werden.

### 3.3 Freier Betrag buchen
- Ueber `Freier Betrag` kann ein beliebiger Betrag gebucht werden (z. B. Sonderverkauf).

### 3.4 Gast anlegen und abrechnen
1. `Gast anlegen` waehlen.
2. Vor- oder Nachname eingeben.
3. Fuer den Gast koennen danach normale Buchungen erfasst werden.
4. Fuer Gaeste stehen zusaetzlich bereit:
   - `Teilabrechnung`
   - `Abrechnung` (kompletter Abschluss)

### 3.5 Inaktivitaetsschutz im Terminal
- Wenn ein Mitglied geoeffnet ist und keine Aktivitaet erfolgt, wird die Mitgliedsansicht nach ca. **60 Sekunden** automatisch geschlossen.

## 4. Bestand nachfuellen (`/stock-refill`)

1. Im Terminal auf `Nachfuellen` wechseln.
2. Verpflichtend ein Mitglied als "Auffueller" auswaehlen.
3. Mengen je Artikel eintragen.
4. `Speichern` klicken.
5. Der Bestand wird aktualisiert und die Nachfuellung protokolliert.

Hinweise:
- Ohne Auswahl eines Auffuellers wird das Speichern blockiert.
- Angezeigt werden u. a. Kuehlschrank-, Lager- und Gesamtbestand je Artikel.

## 5. Adminportal (`/admin`)

### 5.1 Dashboard
- Kennzahlen wie Umsatz, Stornos, Buchungen, aktiven Mitgliederanteil, Durchschnittsbon.
- Zeitraumfilter (Heute, letzte 7/30 Tage, Monat, Jahr, benutzerdefiniert).
- Visualisierungen:
  - Umsatztrend
  - Kategorienanteil
  - Top-Produkte
  - Aktivitaets-Heatmap

### 5.2 Verwaltung
Im Bereich `Verwaltung` stehen je nach Berechtigung folgende Module bereit:
- Mitglieder
- Artikel
- Lagerverwaltung
- Buchungsuebersicht
- Branding
- Admin-Benutzer
- Geraete koppeln

### 5.3 Berichte
Im Bereich `Berichte` sind u. a. verfuegbar:
- Inventurabgleich
- Fehlbestaende & Anpassungen
- Kuehlschrank-Auffuellungen
- Storno-Report
- Umsatzreport
- Abrechnungsprotokoll
- Monatsabschluss

## 6. Typische Arbeitsablaeufe

### Tagesbetrieb (Terminal)
1. Terminal startet und ist geraeteauthentifiziert.
2. Mitglieder buchen selbststaendig Artikel.
3. Optional: Gast anlegen und abrechnen.
4. Bei Bedarf freie Betraege erfassen.

### Nachfuellen
1. Nachfuellansicht aufrufen.
2. Auffueller auswaehlen.
3. Artikelmengen eintragen und speichern.

### Verwaltung/Controlling
1. Als Admin anmelden.
2. Stammdaten pflegen (Mitglieder/Artikel).
3. Berichte und Dashboard fuer Auswertung nutzen.
4. Optional Monatsabschluss durchfuehren.

## 7. Fehlerbehebung

### Pairing-Code wird nicht akzeptiert
- Eingabe auf Tippfehler pruefen.
- Sicherstellen, dass der Code noch gueltig ist.
- Geraet im Adminbereich ggf. neu koppeln.

### Admin-Session endet unerwartet
- Pruefen, ob 5 Minuten Inaktivitaet erreicht wurden.
- Pruefen, ob der Adminbereich verlassen wurde und der Exit-Timeout abgelaufen ist.

### Buchungen/Bestand laden nicht
- Netzwerkverbindung pruefen.
- API-/Supabase-Konfiguration pruefen.
- Bei anhaltenden Problemen Admin informieren und Logs pruefen.

## 8. Sicherheits- und Betriebsregeln
- Zugangsdaten nicht teilen.
- Service-Keys niemals im Frontend oder in Dokumenten hinterlegen.
- Pairing-Codes und Admin-Zugaenge nur an autorisierte Personen ausgeben.
- Demo-Zugaenge nur in Testumgebungen verwenden.

---
Stand: 2026-02-28
