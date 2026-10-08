# HAYEVA — Point de restauration V1-STABLE (2026-10-07)

Créé avant tout développement V2 (Règle 0 du prompt maître V2).

## Code
- Branche Git : `HAYEVA-V1-STABLE` (commit `4f09745`). Les tags sont refusés par le dépôt, d'où une branche.
- Autres branches de restauration : `HAYEVA-V1-CLEAN-PRODUCTION`, `HAYEVA-V1-PRE-OUVERTURE`.

## Base de données (Supabase `hvlzdsuyhrhaflwutwml`)
- Instantané des données métier : schéma privé `backup_v1_stable` (40 tables copiées, aucun accès anon / authenticated, non exposé par l'API).
- Migrations appliquées : `0001` à `0101` (dossier `supabase/migrations`) + `v1_stable_snapshot`.
- Restauration d'une table : `insert into public.<table> select * from backup_v1_stable.<table> on conflict do nothing;` (à faire uniquement après vérification).

## Edge Functions
admin-push, ai-assistant, ai-assistant-pro, ai-request-human, booking-email-action, calculate-travel-distance,
calendar-sync, get-public-config, notify-admin-booking, notify-booking-change, notify-customer-booking,
notify-customer-status-change, notify-document, process-reminders, propose-alternative-slot,
resend-booking-email, send-intervention-report, verify-turnstile (+ `_shared/email-template.ts`).
`diag-turnstile-env` : fonction temporaire neutralisée (410), à supprimer dans le tableau de bord.

## Noms des variables / secrets (valeurs jamais consignées)
ACTION_ALLOWED_ORIGINS, ADMIN_BOOKING_EMAIL, ADMIN_NOTIFICATION_EMAIL, ADMIN_PANEL_URL, CLIENT_PANEL_URL,
CRON_SHARED_SECRET, MAPBOX_PUBLIC_TOKEN, MAPBOX_SECRET_TOKEN, OPENROUTER_API_KEY, PUBLIC_SITE_URL,
REPLY_TO_EMAIL, RESEND_API_KEY, RESEND_FROM_EMAIL, SITE_BASE_URL, SMS_PROVIDER, TURNSTILE_SECRET_KEY,
TURNSTILE_SITE_KEY, TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER, VAPID_PRIVATE_KEY,
VAPID_PUBLIC_KEY, VAPID_SUBJECT, WEBHOOK_SECRET (+ Vault : `webhook_secret`).

## Tâches planifiées (pg_cron)
hayeva-reminder-cycle (*/15), hayeva-calendar-pull-cycle (*/15), hayeva-admin-intervention-reminders (*/10).

## Sécurité
Turnstile : `security_settings.turnstile_enforced = true` depuis le 2026-10-07 17:31 UTC.
Retour arrière d'urgence (si les réservations sans compte étaient bloquées) :
`update security_settings set turnstile_enforced = false where id = 1;`
