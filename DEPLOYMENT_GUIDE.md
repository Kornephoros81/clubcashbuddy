# Deployment Guide (Vereine)

## 1) Git: Public Repo korrekt uebernehmen
Empfohlen fuer produktive Nutzung:
- Public-Repo forken oder in ein eigenes (privates) Repository spiegeln.
- Vercel auf dieses eigene Repository verbinden, nicht direkt auf das Upstream-Public-Repo.
- Upstream optional hinterlegen, um spaeter Updates zu ziehen.

Beispiel:
```bash
git clone <euer-repo-url>
cd ClubCashBuddy-public
git remote add upstream <public-upstream-url>
git fetch upstream
```

## 2) Supabase-Projekt erstellen
In Supabase ein neues Projekt anlegen.

## 3) Datenbank vollstaendig aufsetzen
Im Supabase `SQL Editor` den kompletten Inhalt von
`supabase/full_setup_clean_bootstrap.sql`
einfuegen und ausfuehren.

## 4) Rollenmodell
Die App nutzt `public.app_users.role` als einziges Rollenmodell:
- `admin`: Admin-Funktionen
- `operator`: eingeschraenkte Backoffice-Rolle
- `device`: Terminal-Session-Rolle (wird bei Device-Login verwendet)
- `service`: interne Service-Rolle

## 5) Initialer Admin (automatisch)
Nach Ausfuehren von `supabase/full_setup_clean_bootstrap.sql` ist ein initialer Admin vorhanden:
- Username: `clubadmin`
- Passwort: `ClubCashBuddy`

Wichtig: Passwort sofort nach erstem Login im Admin-Bereich aendern.

## 6) Vercel-Projekt erstellen
Das Repository in Vercel importieren und deployen.

## 7) Pflicht-Umgebungsvariablen in Vercel setzen
In Vercel unter `Project Settings -> Environment Variables`:

- `SUPABASE_URL` = URL eures Supabase-Projekts
- `SUPABASE_SERVICE_ROLE_KEY` = Service Role Key aus Supabase
- `VITE_SUPABASE_URL` = URL eures Supabase-Projekts (Frontend)
- `VITE_SUPABASE_ANON_KEY` = anon/public Key aus Supabase (Frontend)

## 8) Deployment ausfuehren
Deployment starten.

## 9) Nutzung
- Admin-Login initial mit `clubadmin` und `ClubCashBuddy`
- Danach im Admin-Portal ein Terminal-Geraet anlegen und Pairing-Code erzeugen.
