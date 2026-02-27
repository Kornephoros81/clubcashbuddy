# Deployment Guide (Vereine)

## 1) Supabase-Projekt erstellen
In Supabase ein neues Projekt anlegen.

## 2) Datenbank vollständig aufsetzen
Im Supabase `SQL Editor` den kompletten Inhalt von
`supabase/full_setup_clean_bootstrap.sql`
einfügen und ausführen.

## 3) Ersten Admin-Benutzer anlegen
Im `SQL Editor` ausführen (Werte ersetzen):

```sql
insert into public.app_users (id, username, password_hash, role, active)
values (
  gen_random_uuid(),
  'admin',
  crypt('ADMIN_PASSWORT', gen_salt('bf')),
  'admin',
  true
);

insert into public.admins (user_id)
select id from public.app_users where username = 'admin';
```

## 4) Terminal-Gerät anlegen
Im `SQL Editor` ausführen (Werte ersetzen):

```sql
insert into public.kiosk_devices (name, secret_hash, active)
values (
  'Terminal 1',
  crypt('GERAETE_KEY', gen_salt('bf')),
  true
);
```

## 5) Vercel-Projekt erstellen
Das Repository in Vercel importieren und deployen.

## 6) Pflicht-Umgebungsvariablen in Vercel setzen
In Vercel unter `Project Settings -> Environment Variables`:

- `SUPABASE_URL` = URL eures Supabase-Projekts
- `SUPABASE_SERVICE_ROLE_KEY` = Service Role Key aus Supabase
- `VITE_SUPABASE_URL` = URL eures Supabase-Projekts (Frontend)
- `VITE_SUPABASE_ANON_KEY` = anon/public Key aus Supabase (Frontend)

## 7) Deployment ausführen
Deployment starten.

## 8) Nutzung
- Admin-Login mit `admin` und `ADMIN_PASSWORT`
- Terminal-Login mit `GERAETE_KEY`
