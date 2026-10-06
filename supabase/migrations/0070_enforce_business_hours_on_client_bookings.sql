-- Audit de mise en production : les fonctions de réservation publiques
-- (create_booking, create_guest_or_quote_booking) ne vérifiaient pas les
-- horaires d'ouverture côté serveur — seul le site les imposait. Un appel
-- direct à l'API pouvait donc réserver un dimanche ou à 22:30 (RDV PENDING
-- qui bloque malgré tout le créneau). La règle serveur existante
-- is_slot_within_business_hours() (identique aux créneaux du site, déjà
-- utilisée par reschedule_own_booking) est désormais appliquée à toute
-- création de RDV par un client/visiteur.
-- Non concernés : l'administration (horaires exceptionnels possibles),
-- service_role, et les demandes de dépannage issues d'un contrat
-- (contract_id renseigné : date provisoire, planifiée ensuite par l'admin).
-- Nom "zz" : s'exécute après trg_bookings_guard_direct_insert (ordre
-- alphabétique des triggers), donc sur la durée déjà recalculée.
create or replace function public.enforce_business_hours_on_client_booking()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if is_admin() or coalesce(auth.role(), '') = 'service_role' or new.contract_id is not null then
    return new;
  end if;
  if not is_slot_within_business_hours(new.date, new.start_time, coalesce(new.service_duration_minutes, 60)) then
    raise exception 'Ce créneau est en dehors de nos horaires d''intervention. Choisissez un autre horaire.';
  end if;
  return new;
end;
$$;

create trigger trg_bookings_zz_business_hours
  before insert on bookings
  for each row execute function enforce_business_hours_on_client_booking();
