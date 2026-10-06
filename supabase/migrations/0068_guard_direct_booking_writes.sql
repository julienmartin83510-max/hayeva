-- Sécurité (audit de mise en production) : écritures DIRECTES via l'API REST.
--
-- Constat vérifié (transaction annulée, aucune donnée créée) : avec la seule
-- clé publique du site, un visiteur anonyme pouvait insérer directement dans
-- bookings une réservation déjà CONFIRMED, à 0 €, à 22:30 pour 10 h —
-- contournant tarifs, horaires d'ouverture, blocages Apple Calendar et
-- validation administrateur (et déclenchant e-mails + envoi Apple).
-- De même, un client pouvait modifier directement la date de son RDV
-- (sans les contrôles de reschedule_own_booking), supprimer ses RDV, et un
-- client (compte pro ou particulier) pouvait écrire dans les fiches
-- d'intervention de ses propres RDV.
--
-- Principe : les parcours officiels passent par des fonctions SECURITY
-- DEFINER (create_booking, create_guest_or_quote_booking,
-- reschedule_own_booking, cancel_own_booking, start_intervention,
-- finalize_intervention_booking…) qui s'exécutent sous le propriétaire de la
-- base : elles ne sont PAS concernées. Seules les écritures faites
-- directement par les rôles anon/authenticated non admin sont encadrées.
-- L'espace admin (is_admin()) garde exactement les mêmes droits.

-- 1) INSERT direct : interdit aux visiteurs anonymes ; pour un client
--    connecté (seul usage réel : demande de dépannage depuis un contrat),
--    statut forcé à PENDING et tarif/durée recalculés depuis le catalogue.
create or replace function public.guard_direct_booking_insert()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_service services%rowtype;
begin
  if current_user not in ('anon', 'authenticated') or is_admin() then
    return new;
  end if;
  if current_user = 'anon' or auth.uid() is null then
    raise exception 'Merci d''utiliser le formulaire de réservation.';
  end if;

  select * into v_service from services where id = new.service_id;
  if not found then
    raise exception 'Prestation inconnue.';
  end if;

  new.status := 'PENDING';
  new.service_duration_minutes := coalesce(v_service.duration_minutes, 60);
  new.service_price_cents := coalesce(v_service.base_price_cents, 0);
  new.travel_fee_cents := 0;
  new.discount_cents := 0;
  new.total_cents := coalesce(v_service.base_price_cents, 0);
  new.calendar_event_uid := null;
  new.calendar_sync_status := 'NOT_SYNCED';
  new.calendar_sync_error := null;
  new.admin_viewed_at := null;
  new.cancelled_by := null;
  new.cancelled_at := null;
  new.cancellation_type := null;
  new.cancellation_reason_code := null;
  new.cancellation_reason_detail := null;
  return new;
end;
$$;

create trigger trg_bookings_guard_direct_insert
  before insert on bookings
  for each row execute function guard_direct_booking_insert();

-- 2) UPDATE direct par un client : les champs de planification, d'identité,
--    d'annulation et de synchronisation restent inchangés (les parcours
--    client officiels passent par reschedule_own_booking/cancel_own_booking).
--    Statut et montants étaient déjà protégés (protect_booking_financial_fields).
create or replace function public.guard_direct_booking_update()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or is_admin() then
    return new;
  end if;
  new.reference := old.reference;
  new.date := old.date;
  new.start_time := old.start_time;
  new.service_id := old.service_id;
  new.service_pack_id := old.service_pack_id;
  new.customer_user_id := old.customer_user_id;
  new.professional_account_id := old.professional_account_id;
  new.client_id := old.client_id;
  new.cancelled_by := old.cancelled_by;
  new.cancelled_at := old.cancelled_at;
  new.cancellation_type := old.cancellation_type;
  new.cancellation_reason_code := old.cancellation_reason_code;
  new.cancellation_reason_detail := old.cancellation_reason_detail;
  new.calendar_event_uid := old.calendar_event_uid;
  new.calendar_sync_status := old.calendar_sync_status;
  new.calendar_last_sync_at := old.calendar_last_sync_at;
  new.calendar_sync_error := old.calendar_sync_error;
  new.cgv_version := old.cgv_version;
  new.cgv_accepted_at := old.cgv_accepted_at;
  return new;
end;
$$;

create trigger trg_bookings_guard_direct_update
  before update on bookings
  for each row execute function guard_direct_booking_update();

-- 3) et 4) Politiques RESTRICTIVES (combinées en ET avec les politiques
--    existantes, qui restent en place) : suppression d'un RDV réservée à
--    l'administration (le client annule via cancel_own_booking, ce qui
--    conserve l'historique) ; écriture des fiches d'intervention réservée à
--    l'administration — le client (particulier ou compte pro) garde la
--    lecture de ses propres données via les politiques existantes.
create policy "bookings: delete admin only" on bookings
  as restrictive for delete using (is_admin());

create policy "interventions: write admin only (insert)" on interventions as restrictive for insert with check (is_admin());
create policy "interventions: write admin only (update)" on interventions as restrictive for update using (is_admin()) with check (is_admin());
create policy "interventions: write admin only (delete)" on interventions as restrictive for delete using (is_admin());

create policy "intervention_items: write admin only (insert)" on intervention_items as restrictive for insert with check (is_admin());
create policy "intervention_items: write admin only (update)" on intervention_items as restrictive for update using (is_admin()) with check (is_admin());
create policy "intervention_items: write admin only (delete)" on intervention_items as restrictive for delete using (is_admin());

create policy "intervention_parts: write admin only (insert)" on intervention_parts as restrictive for insert with check (is_admin());
create policy "intervention_parts: write admin only (update)" on intervention_parts as restrictive for update using (is_admin()) with check (is_admin());
create policy "intervention_parts: write admin only (delete)" on intervention_parts as restrictive for delete using (is_admin());

create policy "intervention_anomalies: write admin only (insert)" on intervention_anomalies as restrictive for insert with check (is_admin());
create policy "intervention_anomalies: write admin only (update)" on intervention_anomalies as restrictive for update using (is_admin()) with check (is_admin());
create policy "intervention_anomalies: write admin only (delete)" on intervention_anomalies as restrictive for delete using (is_admin());

create policy "intervention_photos: write admin only (insert)" on intervention_photos as restrictive for insert with check (is_admin());
create policy "intervention_photos: write admin only (update)" on intervention_photos as restrictive for update using (is_admin()) with check (is_admin());
create policy "intervention_photos: write admin only (delete)" on intervention_photos as restrictive for delete using (is_admin());
