-- ============================================================
-- Notification admin (e-mail) à la création d'une réservation
-- ============================================================
-- Remplace l'approche "Database Webhook" du Dashboard : le schéma
-- supabase_functions dont cette fonctionnalité dépend n'existe pas sur ce
-- projet ("ERROR: 3F000: schema supabase_functions does not exist"), même
-- après activation de pg_net. On obtient exactement la même garantie
-- (une notification, uniquement à la création, jamais sur une mise à jour)
-- avec un trigger Postgres standard AFTER INSERT + pg_net, entièrement
-- sous notre contrôle.
--
-- ATTENTION AVANT D'EXÉCUTER : remplace REMPLACER_PAR_LE_SECRET ci-dessous
-- par le jeton généré (le même que celui défini comme secret WEBHOOK_SECRET
-- de l'Edge Function via `supabase secrets set WEBHOOK_SECRET=...`) avant
-- de coller ce fichier dans le SQL Editor. Ne commite jamais la vraie
-- valeur dans ce fichier.
create extension if not exists pg_net;

create or replace function notify_admin_new_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-admin-booking',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer REMPLACER_PAR_LE_SECRET'
    ),
    body := jsonb_build_object(
      'type', 'INSERT',
      'table', 'bookings',
      'record', to_jsonb(NEW)
    )
  );
  return NEW;
end;
$$;

revoke all on function notify_admin_new_booking() from public;

drop trigger if exists trg_notify_admin_new_booking on bookings;
create trigger trg_notify_admin_new_booking
  after insert on bookings
  for each row
  execute function notify_admin_new_booking();
