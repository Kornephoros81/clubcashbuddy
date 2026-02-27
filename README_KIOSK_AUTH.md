# Kiosk-Authentifizierung (Self-Identifying Device)

Dieses Paket stellt den Flow bereit, bei dem **kein `VITE_DEVICE_NAME`** benötigt wird.
Das Gerät gibt **einmalig den Device-Key** ein; die App speichert anschließend ein JWT (Token) lokal
und nutzt es beim nächsten Start automatisch.

## Dateien
- `supabase/functions/register-device/index.ts` – Admin registriert ein Gerät, erhält einmalig den Key
- `supabase/functions/device-login/index.ts` – Gerät meldet sich **nur mit Key** an, Function ermittelt Gerät selbst
- `src/store/useDeviceAuthStore.ts` – Pinia-Store für den Geräte-Login-Flow (Token-Speicher)
- `src/components/DeviceAuthDialog.vue` – UI zur einmaligen Key-Eingabe
- `src/router/index.ts` – Route-Guard, sperrt Kiosk-Seiten ohne Device-Auth
- `src/pages/Home.vue`, `src/pages/Kiosk.vue` – Beispielseiten
- `src/utils/jwt.ts` – kleines Hilfsmodul, um Token-Expiry zu prüfen
- `vercel.json` – Rewrite der API-Routen auf Supabase Edge Functions (URL anpassen)

## Setup
1) **Tabellenanlage** (falls noch nicht vorhanden):
```sql
create table if not exists public.kiosk_devices (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  device_secret text not null,
  active boolean default true,
  last_seen_at timestamptz default now(),
  created_at timestamptz default now()
);
```

2) **Supabase Edge Functions** im Supabase Dashboard anlegen:
   - `register-device` (Inhalt siehe Datei)
   - `device-login` (Inhalt siehe Datei)

   Setze im Function-Environment:
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY` (nur in Function, **niemals im Frontend**)
   - `JWT_SECRET` (für die Signatur der Gerätetokens)

3) **Vercel: Environment Variables**
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`

4) **Vercel: Rewrite konfigurieren** (`vercel.json` im Projektwurzelverzeichnis):
   Ersetze in `vercel.json` die Platzhalter-URL `https://<PROJECT>.functions.supabase.co`
   durch deine Functions-URL (z.B. `https://xyz.functions.supabase.co`).

5) **Gerät registrieren**:
   - Admin ruft `register-device` auf (z.B. über Supabase Studio → Edge Functions → Invoke)
   - Es wird einmalig ein **Device-Key** angezeigt

6) **Erststart am Gerät**:
   - App öffnet sich → Eingabedialog fragt den **Device-Key**
   - Bei Erfolg speichert die App das **JWT** lokal (kein Key bleibt gespeichert)
   - Danach automatischer Start ohne erneute Eingabe, bis das JWT abläuft (Standard: 30 Tage)

7) **RLS-Policy** (nur authentifizierte Geräte dürfen Transaktionen einfügen):
```sql
create policy if not exists kiosk_insert_tx
on public.transactions
for insert
to anon
using ( current_setting('request.jwt.claim.device_id', true) is not null );
```
Hinweis: Die Tabelle `public.transactions` existiert im Schema bereits. (Siehe vorhandenes Schema.)

## Sicherheit
- Device-Key wird **nicht** gespeichert, nur ein JWT mit `device_id`/`device_name`.
- Geräte können in `kiosk_devices.active=false` deaktiviert werden.
- Tokensignatur via `JWT_SECRET`.
- Service-Role-Key bleibt ausschließlich in den Functions.
