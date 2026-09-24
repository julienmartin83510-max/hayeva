-- ============================================================
-- Ouverture officielle HAYEVA : 1er novembre 2026
-- ============================================================
-- Aucune réservation (nouvelle demande OU déplacement d'une demande
-- existante) ne doit pouvoir cibler une date d'intervention antérieure au
-- 1er novembre 2026. Implémenté comme un trigger BEFORE INSERT/UPDATE sur
-- bookings plutôt qu'en modifiant create_booking()/
-- create_guest_or_quote_booking()/reschedule_own_booking() : ces fonctions
-- ont des corps longs et déjà éprouvés (conformité CGV, déplacement
-- gratuit, etc.) — un trigger séparé couvre tous les chemins d'écriture
-- (actuels ET futurs) sans risquer de retoucher leur logique existante.
--
-- Le 1er novembre 2026 tombe un dimanche (jour fermé, voir hoursForDate()
-- côté frontend) : le premier créneau réellement réservable est donc de
-- fait lundi 2 novembre, mais la règle ci-dessous reste bien "< 1er
-- novembre 2026" — la date d'OUVERTURE affichée sur le site reste le 1er
-- novembre, jamais modifiée par cette histoire de dimanche fermé.
--
-- Échappatoire admin/service_role : même logique que
-- protect_booking_financial_fields() — un administrateur (ou un appel
-- service_role) peut toujours créer/corriger une réservation à une date
-- antérieure si nécessaire (ex. données de test, correction manuelle) ;
-- seuls les clients/invités en sont empêchés.
create or replace function enforce_hayeva_opening_date()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.date < date '2026-11-01' and not (is_admin() or auth.role() = 'service_role') then
    raise exception 'HAYEVA ouvre officiellement le 1er novembre 2026 — aucune réservation avant cette date.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_enforce_hayeva_opening_date on bookings;
create trigger trg_enforce_hayeva_opening_date
  before insert or update of date on bookings
  for each row execute function enforce_hayeva_opening_date();
