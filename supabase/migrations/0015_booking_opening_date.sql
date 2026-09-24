-- ============================================================
-- Règle métier : ouverture des rendez-vous le 1er novembre 2026
-- ============================================================
-- Aucune réservation ne peut être CRÉÉE ni DÉPLACÉE vers une date
-- antérieure au 01/11/2026, quel que soit le chemin utilisé :
--   * create_booking()                  (particulier connecté)
--   * create_guest_or_quote_booking()   (invité, compte professionnel, devis)
--   * toute future RPC de déplacement (ex. reschedule_own_booking())
--   * panneau Administration, SQL Editor, Edge Functions (service_role)
-- La règle est portée par un trigger BEFORE INSERT OR UPDATE OF date sur
-- bookings : elle s'applique à TOUTE écriture, pas seulement à l'interface
-- (qui ne propose de toute façon plus aucune date antérieure, voir
-- HAYEVA_LAUNCH dans index.html). Appeler l'API/RPC directement ne permet
-- donc pas de la contourner.
--
-- Les réservations DÉJÀ enregistrées avant cette date ne sont pas bloquées
-- par ce trigger tant que leur date ne change pas : l'administrateur peut
-- toujours les consulter et changer leur statut (ex. les annuler). Leur
-- traitement (annulation, conservation dans l'historique) est un script
-- séparé, à exécuter manuellement après validation :
-- supabase/scripts/cancel_bookings_before_opening.sql
--
-- Pas de contrainte CHECK : elle serait réévaluée à chaque mise à jour des
-- lignes existantes (y compris un simple changement de statut) et
-- empêcherait justement d'annuler les anciennes réservations.
--
-- POUR RETIRER / MODIFIER LA RÈGLE PLUS TARD : changer la date renvoyée par
-- booking_opening_date() via une nouvelle migration (create or replace),
-- ou supprimer le trigger trg_enforce_booking_opening_date. Une fois la date
-- passée, la règle devient de toute façon sans effet (aucun client ne peut
-- réserver dans le passé, create_* le refusent déjà).
--
-- Rejouable sans risque (idempotent).

-- Source unique côté serveur de la date d'ouverture.
create or replace function booking_opening_date()
returns date
language sql
immutable
set search_path = public
as $$
  select date '2026-11-01';
$$;
-- Information publique (affichée sur le site) : lisible par tous. Nécessaire
-- aussi parce que le trigger ci-dessous s'exécute avec les droits de
-- l'appelant (ex. un administrateur connecté qui modifierait une date).
revoke execute on function booking_opening_date() from public;
grant execute on function booking_opening_date() to anon, authenticated, service_role;

create or replace function enforce_booking_opening_date()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.date < booking_opening_date()
     and (tg_op = 'INSERT' or new.date is distinct from old.date) then
    raise exception 'Prise de rendez-vous ouverte pour les interventions à partir du 1er novembre 2026. Merci de choisir une date à partir du 01/11/2026.'
      using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke execute on function enforce_booking_opening_date() from public, anon, authenticated;

drop trigger if exists trg_enforce_booking_opening_date on bookings;
create trigger trg_enforce_booking_opening_date
  before insert or update of date on bookings
  for each row execute function enforce_booking_opening_date();
