-- ============================================================
-- Demandes récentes (lu/non lu) + abonnements push administrateur
-- ============================================================
-- N'affecte ni le flux de réservation existant (create_booking /
-- create_guest_or_quote_booking restent inchangées) ni les déclencheurs
-- e-mail déjà en place (0005/0008, notify_admin_new_booking notamment) :
-- admin_viewed_at est une colonne purement additive, et l'envoi push est
-- ajouté à la FIN de la fonction Edge notify-admin-booking existante (même
-- déclencheur AFTER INSERT, aucun nouveau trigger créé), qui répond déjà 200
-- même si un envoi échoue — un souci d'abonnement push ne peut donc jamais
-- faire échouer une réservation, exactement comme pour l'e-mail admin
-- aujourd'hui.

-- ---- "Vu" par l'admin (NULL = nouvelle demande non consultée) ----
alter table bookings add column admin_viewed_at timestamptz;

-- Recréée avec la nouvelle colonne ajoutée à la même protection déjà en
-- place pour les colonnes gérées uniquement par l'admin (voir
-- 0007_travel_and_emails.sql) : un client/professionnel ne doit jamais
-- pouvoir se marquer lui-même "vu" via un update direct de sa propre ligne.
create or replace function protect_booking_financial_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (is_admin() or auth.role() = 'service_role') then
    new.service_price_cents := old.service_price_cents;
    new.travel_fee_cents := old.travel_fee_cents;
    new.discount_cents := old.discount_cents;
    new.total_cents := old.total_cents;
    new.service_duration_minutes := old.service_duration_minutes;
    new.status := old.status;
    new.intervention_lat := old.intervention_lat;
    new.intervention_lng := old.intervention_lng;
    new.one_way_distance_km := old.one_way_distance_km;
    new.included_radius_km := old.included_radius_km;
    new.travel_rate_per_km_cents := old.travel_rate_per_km_cents;
    new.distance_calculation_status := old.distance_calculation_status;
    new.distance_calculated_at := old.distance_calculated_at;
    new.admin_viewed_at := old.admin_viewed_at;
  end if;
  return new;
end;
$$;

-- ---- Abonnements push de l'administrateur ----
-- Une ligne par appareil/navigateur abonné (un admin peut activer les
-- notifications sur son téléphone ET son ordinateur : pas de contrainte
-- d'unicité par user_id, uniquement par endpoint, qui identifie un
-- abonnement push de façon unique). Lue par notify-admin-booking via la clé
-- service_role (bypass RLS, comportement déjà utilisé par toutes les Edge
-- Functions existantes) pour l'envoi effectif des notifications — jamais par
-- un autre admin que son propriétaire depuis le frontend.
create table admin_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth_key text not null,
  enabled boolean not null default true,
  user_agent text,
  created_at timestamptz not null default now()
);

alter table admin_push_subscriptions enable row level security;

create policy "admin_push_subscriptions: admin manages own" on admin_push_subscriptions
  for all using (
    is_admin() and user_id = auth.uid()
  ) with check (
    is_admin() and user_id = auth.uid()
  );
