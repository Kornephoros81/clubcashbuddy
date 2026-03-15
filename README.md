## Unterstuetzung
Wenn dein Verein ClubCashBuddy nutzt und das Open-Source-Projekt sowie den betreibenden gemeinnuetzigen Verein unterstuetzen moechte, kannst du hier spenden:

[Jetzt ueber betterplace spenden](https://www.betterplace.org/p172195)

Die Spenden gehen an den Verein, nicht an eine Privatperson.

# ClubCashBuddy (Vue + Supabase + Vercel)
Self-Service-Kassensoftware (Terminal, Admin, Dashboard, PWA, API).

## Quickstart
1. Abhängigkeiten installieren:
   ```bash
   npm install
   ```
2. Environment-Datei anlegen (`.env.local` oder `.env`) mit:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY`
3. Entwicklung starten:
   ```bash
   npm run dev
   ```

## Datenbank-Setup
- Komplettes SQL-Bootstrap: `supabase/full_setup_clean_bootstrap.sql`
- Demo-Daten: `supabase/demo_seed.sql`

## Deployment
Für produktive Einrichtung siehe `DEPLOYMENT_GUIDE.md`.

## Sicherheit
- Niemals Secrets ins Repository committen (`.env*`, Service Keys, Tokens).
- `SUPABASE_SERVICE_ROLE_KEY` nur serverseitig nutzen (API/Functions), nie im Frontend.
- Demo-Credentials aus `demo_seed.sql` sind ausschließlich für Demo/Testzwecke.

## Open Source
Dieses Projekt ist source-available unter einer Non-Commercial-Lizenz. Kommerzielle Nutzung durch for-profit Unternehmen ist nicht erlaubt. Vereine und gemeinnuetzige Einrichtungen duerfen die Software nutzen (siehe `LICENSE`).


