-- ============================================================
-- Moteur de frais de déplacement + e-mails transactionnels client
-- ============================================================
-- Audit préalable (voir commentaires) : bookings.travel_fee_cents existe
-- déjà (0001_init.sql) mais create_booking() ET create_guest_or_quote_booking()
-- l'écrivent en dur à 0 — c'est la cause du bug réel constaté (un devis pour
-- Nice, à ~70 km de Fréjus, enregistré avec des frais de déplacement nuls).
-- Cette migration ajoute uniquement ce qui manque : le détail du calcul
-- (colonnes snapshot sur bookings, jamais recalculées après coup même si le
-- tarif change plus tard), la configuration du barème (une seule ligne,
-- modifiable par l'admin sans toucher au code), et le suivi des e-mails
-- client (table séparée, pas de colonnes dupliquées par type d'e-mail).

-- ---------------------------------------------------------------------
-- Barème des déplacements — une seule ligne, modifiable par l'admin.
-- origin_address peut être une adresse privée (domicile de l'entrepreneur) :
-- sert uniquement au calcul serveur, jamais affichée au client (aucune
-- policy SELECT ne l'expose côté public — voir plus bas, colonne exclue des
-- lectures anon/authenticated via une vue restreinte).
create table travel_settings (
  id boolean primary key default true,
  constraint travel_settings_singleton check (id = true),
  origin_label text not null default 'Fréjus',
  origin_address text,
  origin_lat double precision not null default 43.4340,
  origin_lng double precision not null default 6.7356,
  included_radius_km numeric(5,1) not null default 20,
  rate_per_km_cents integer not null default 70,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into travel_settings (id) values (true);

alter table travel_settings enable row level security;

-- Vue publique : tout ce qu'il faut pour afficher/calculer côté client,
-- SANS l'adresse précise du point de départ (jamais publique).
create or replace view travel_settings_public as
  select origin_label, origin_lat, origin_lng, included_radius_km, rate_per_km_cents, updated_at
  from travel_settings;
grant select on travel_settings_public to anon, authenticated;

create policy "travel_settings: admin read" on travel_settings
  for select using (is_admin());
create policy "travel_settings: admin update" on travel_settings
  for update using (is_admin()) with check (is_admin());

-- ---------------------------------------------------------------------
-- Détail du calcul de déplacement, snapshotté sur chaque réservation (comme
-- service_price_cents/service_duration_minutes déjà présents) : un ancien
-- rendez-vous garde le tarif applicable au moment de la réservation même si
-- rate_per_km_cents change ensuite dans travel_settings.
alter table bookings add column intervention_lat double precision;
alter table bookings add column intervention_lng double precision;
alter table bookings add column one_way_distance_km numeric(6,1);
alter table bookings add column included_radius_km numeric(5,1);
alter table bookings add column travel_rate_per_km_cents integer;
alter table bookings add column distance_calculation_status text
  not null default 'unavailable'
  check (distance_calculation_status in ('ok','unavailable'));
alter table bookings add column distance_calculated_at timestamptz;

-- Le trigger existant protect_booking_financial_fields() (0001_init.sql,
-- trg_protect_booking_financials) gèle déjà service_price_cents/
-- travel_fee_cents/etc. contre toute modification client directe (seuls
-- is_admin() ou service_role peuvent les faire évoluer). Recréée ici avec
-- les nouvelles colonnes de détail du calcul de distance ajoutées à la même
-- protection, sinon un client pourrait les modifier via un simple update
-- alors que le montant facturé, lui, resterait gelé — incohérent.
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
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Suivi des e-mails client (table séparée plutôt que des colonnes par type
-- d'e-mail sur bookings : couvre "reçue", "confirmée", "annulée" et de
-- futurs types sans migration supplémentaire, et garde un historique complet
-- au lieu d'un seul statut écrasé à chaque envoi).
create table booking_emails (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings(id) on delete cascade,
  email_type text not null check (email_type in ('received','confirmed','cancelled')),
  status text not null default 'pending' check (status in ('pending','sent','failed')),
  recipient_email text,
  error_message text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_booking_emails_booking on booking_emails(booking_id);

alter table booking_emails enable row level security;
-- Écrit uniquement par les Edge Functions (clé service_role, contourne RLS
-- par construction) : aucune policy d'insert/update n'est nécessaire ni
-- souhaitable côté client. Lu par l'admin pour le suivi des envois.
create policy "booking_emails: admin read" on booking_emails
  for select using (is_admin());

-- ---------------------------------------------------------------------
-- Déclenchement des e-mails client, même mécanisme que
-- 0005_booking_notify_trigger.sql (trigger Postgres + pg_net, le Dashboard
-- Webhooks étant indisponible sur ce projet) : un second trigger AFTER
-- INSERT (indépendant de trg_notify_admin_new_booking, les deux se
-- déclenchent) pour l'e-mail "demande reçue", et un AFTER UPDATE pour
-- "confirmé"/"annulé", qui ne se déclenche QUE sur un vrai changement de
-- statut vers l'une de ces deux valeurs.
--
-- ATTENTION AVANT D'EXÉCUTER : remplace REMPLACER_PAR_LE_SECRET par le même
-- jeton que celui utilisé dans 0005_booking_notify_trigger.sql (secret
-- WEBHOOK_SECRET des Edge Functions). Ne commite jamais la vraie valeur.
create or replace function notify_customer_new_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-customer-booking',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer REMPLACER_PAR_LE_SECRET'
    ),
    body := jsonb_build_object('type', 'INSERT', 'table', 'bookings', 'record', to_jsonb(NEW))
  );
  return NEW;
end;
$$;
revoke all on function notify_customer_new_booking() from public;

drop trigger if exists trg_notify_customer_new_booking on bookings;
create trigger trg_notify_customer_new_booking
  after insert on bookings
  for each row
  execute function notify_customer_new_booking();

create or replace function notify_customer_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status is distinct from OLD.status and NEW.status in ('CONFIRMED','CANCELLED') then
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-customer-status-change',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer REMPLACER_PAR_LE_SECRET'
      ),
      body := jsonb_build_object('type', 'UPDATE', 'table', 'bookings', 'record', to_jsonb(NEW))
    );
  end if;
  return NEW;
end;
$$;
revoke all on function notify_customer_status_change() from public;

drop trigger if exists trg_notify_customer_status_change on bookings;
create trigger trg_notify_customer_status_change
  after update on bookings
  for each row
  execute function notify_customer_status_change();

-- ---------------------------------------------------------------------
-- Calcul des frais de déplacement — point unique de vérité pour la formule
-- commerciale HAYEVA (20 km inclus, 0,70 €/km au-delà, aller-retour), lu par
-- create_booking() ET create_guest_or_quote_booking() ci-dessous pour ne
-- jamais la dupliquer. Ne fait JAMAIS confiance à un montant envoyé par le
-- client : seule la distance (p_distance_km) vient du navigateur, le tarif
-- et le rayon inclus viennent toujours de travel_settings (source serveur).
-- distance null (adresse non reconnue, échec de géocodage...) => statut
-- 'unavailable' et frais à 0 EN ATTENTE DE VÉRIFICATION MANUELLE (jamais
-- interprété comme "déplacement gratuit" : voir distance_calculation_status,
-- affiché "⚠️ à vérifier" partout où le montant est montré).
create or replace function compute_travel_fee_cents(p_distance_km numeric)
returns table(fee_cents integer, radius_km numeric, rate_cents integer, calc_status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings travel_settings%rowtype;
  v_extra_km numeric;
begin
  select * into v_settings from travel_settings where id = true;
  if p_distance_km is null then
    return query select 0, v_settings.included_radius_km, v_settings.rate_per_km_cents, 'unavailable'::text;
    return;
  end if;
  v_extra_km := greatest(0, p_distance_km - v_settings.included_radius_km);
  return query select
    round(v_extra_km * 2 * v_settings.rate_per_km_cents)::integer,
    v_settings.included_radius_km,
    v_settings.rate_per_km_cents,
    'ok'::text;
end;
$$;
revoke all on function compute_travel_fee_cents(numeric) from public;

-- ---------------------------------------------------------------------
-- create_booking() / create_guest_or_quote_booking() recréées avec les
-- paramètres de distance en plus (toujours en dernier, valeur par défaut
-- null : aucun appel existant ne casse). p_intervention_lat/lng sont
-- réservés à un futur géocodage réel (non utilisés pour l'instant, la
-- distance étant estimée côté client par correspondance de ville — voir
-- sudmaintenance.html), gardés dès maintenant pour éviter une nouvelle
-- migration quand un vrai service de routage sera branché.
drop function if exists create_booking(text, date, time, text, uuid, uuid, text);

create or replace function create_booking(
  p_service_slug text,
  p_date date,
  p_start_time time,
  p_service_pack_slug text default null,
  p_customer_address_id uuid default null,
  p_equipment_id uuid default null,
  p_notes text default null,
  p_one_way_distance_km numeric default null,
  p_intervention_lat double precision default null,
  p_intervention_lng double precision default null
)
returns table(booking_id uuid, reference text, total_cents integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_service services%rowtype;
  v_pack service_packs%rowtype;
  v_service_pack_id uuid;
  v_price_cents integer;
  v_duration_minutes integer;
  v_total_cents integer;
  v_reference text;
  v_booking_id uuid;
  v_travel record;
begin
  if v_uid is null then
    raise exception 'Authentification requise pour réserver.';
  end if;

  select global_role into v_role from profiles where user_id = v_uid;
  if v_role is null then
    raise exception 'Profil introuvable pour ce compte.';
  end if;
  if v_role <> 'customer' then
    raise exception 'Cette fonction de réservation est réservée aux comptes particuliers.';
  end if;

  if p_customer_address_id is null then
    raise exception 'Une adresse d''intervention est requise pour réserver.';
  end if;
  if not exists (
    select 1 from customer_addresses
    where id = p_customer_address_id and customer_user_id = v_uid
  ) then
    raise exception 'Adresse inconnue ou non rattachée à votre compte.';
  end if;

  if p_equipment_id is not null and not exists (
    select 1 from customer_equipment
    where id = p_equipment_id and customer_user_id = v_uid
  ) then
    raise exception 'Équipement inconnu ou non rattaché à votre compte.';
  end if;

  if p_date < current_date then
    raise exception 'Impossible de réserver une date déjà passée.';
  end if;

  select * into v_service from services where slug = p_service_slug;
  if not found then
    raise exception 'Prestation inconnue.';
  end if;
  if not v_service.is_active then
    raise exception 'Cette prestation n''est plus disponible.';
  end if;
  if v_service.booking_type <> 'DIRECT_BOOKING' then
    raise exception 'Cette prestation fonctionne uniquement sur devis et ne peut pas être réservée directement.';
  end if;

  if coalesce(p_service_pack_slug, '') <> '' then
    select * into v_pack from service_packs where slug = p_service_pack_slug;
    if not found then
      raise exception 'Formule inconnue.';
    end if;
    if not v_pack.is_active then
      raise exception 'Cette formule n''est plus disponible.';
    end if;
    if v_pack.service_id <> v_service.id then
      raise exception 'Cette formule ne correspond pas à la prestation demandée.';
    end if;
    v_price_cents := v_pack.price_cents;
    v_duration_minutes := v_pack.duration_minutes;
    v_service_pack_id := v_pack.id;
  else
    if v_service.base_price_cents is null then
      raise exception 'Cette prestation nécessite le choix d''une formule.';
    end if;
    v_price_cents := v_service.base_price_cents;
    v_duration_minutes := v_service.duration_minutes;
    v_service_pack_id := null;
  end if;

  select * into v_travel from compute_travel_fee_cents(p_one_way_distance_km);
  v_total_cents := v_price_cents + v_travel.fee_cents;

  v_reference := 'SM-' || to_char(now(), 'YYYY') || '-' ||
    upper(substr(md5(gen_random_uuid()::text), 1, 6));

  begin
    insert into bookings (
      reference, customer_user_id, customer_address_id, equipment_id,
      service_id, service_pack_id, date, start_time, status,
      service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents,
      notes, intervention_lat, intervention_lng, one_way_distance_km,
      included_radius_km, travel_rate_per_km_cents, distance_calculation_status, distance_calculated_at
    ) values (
      v_reference, v_uid, p_customer_address_id, p_equipment_id,
      v_service.id, v_service_pack_id, p_date, p_start_time, 'PENDING',
      v_duration_minutes, v_price_cents, v_travel.fee_cents, 0, v_total_cents,
      nullif(trim(p_notes), ''), p_intervention_lat, p_intervention_lng, p_one_way_distance_km,
      v_travel.radius_km, v_travel.rate_cents, v_travel.calc_status, now()
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  return query select v_booking_id, v_reference, v_total_cents;
end;
$$;

revoke all on function create_booking(text, date, time, text, uuid, uuid, text, numeric, double precision, double precision) from public;
grant execute on function create_booking(text, date, time, text, uuid, uuid, text, numeric, double precision, double precision) to authenticated;
revoke execute on function create_booking(text, date, time, text, uuid, uuid, text, numeric, double precision, double precision) from anon;

drop function if exists create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text);

create or replace function create_guest_or_quote_booking(
  p_service_slug text,
  p_date date,
  p_start_time time,
  p_service_pack_slug text default null,
  p_notes text default null,
  p_guest_name text default null,
  p_guest_email text default null,
  p_guest_phone text default null,
  p_guest_address text default null,
  p_one_way_distance_km numeric default null,
  p_intervention_lat double precision default null,
  p_intervention_lng double precision default null
)
returns table(booking_id uuid, reference text, total_cents integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_customer_user_id uuid := null;
  v_service services%rowtype;
  v_pack service_packs%rowtype;
  v_service_pack_id uuid;
  v_price_cents integer;
  v_duration_minutes integer;
  v_reference text;
  v_booking_id uuid;
  v_travel record;
  v_total_cents integer;
begin
  if p_date < current_date then
    raise exception 'Impossible de réserver une date déjà passée.';
  end if;

  select * into v_service from services where slug = p_service_slug;
  if not found then
    raise exception 'Prestation inconnue.';
  end if;
  if not v_service.is_active then
    raise exception 'Cette prestation n''est plus disponible.';
  end if;

  if coalesce(p_service_pack_slug, '') <> '' then
    select * into v_pack from service_packs where slug = p_service_pack_slug;
    if not found then
      raise exception 'Formule inconnue.';
    end if;
    if not v_pack.is_active then
      raise exception 'Cette formule n''est plus disponible.';
    end if;
    if v_pack.service_id <> v_service.id then
      raise exception 'Cette formule ne correspond pas à la prestation demandée.';
    end if;
    v_price_cents := v_pack.price_cents;
    v_duration_minutes := v_pack.duration_minutes;
    v_service_pack_id := v_pack.id;
  else
    v_service_pack_id := null;
    if v_service.base_price_cents is not null then
      v_price_cents := v_service.base_price_cents;
      v_duration_minutes := v_service.duration_minutes;
    else
      -- Prestation sur devis sans tarif fixe : snapshot à 0, le tarif réel
      -- est communiqué par HAYEVA après étude de la demande (voir p_notes,
      -- déjà rempli côté client avec une mention explicite "sur devis"). Les
      -- frais de déplacement, eux, sont réels et calculés normalement plus
      -- bas : "devis gratuit" ne veut jamais dire "déplacement gratuit".
      v_price_cents := 0;
      v_duration_minutes := coalesce(v_service.duration_minutes, 60);
    end if;
  end if;

  if v_uid is not null then
    select global_role into v_role from profiles where user_id = v_uid;
    if v_role = 'customer' then
      v_customer_user_id := v_uid;
    end if;
  end if;

  if v_customer_user_id is null then
    if coalesce(trim(p_guest_name), '') = '' or coalesce(trim(p_guest_email), '') = '' then
      raise exception 'Merci de renseigner votre nom et votre e-mail pour confirmer la demande.';
    end if;
  end if;

  select * into v_travel from compute_travel_fee_cents(p_one_way_distance_km);
  v_total_cents := v_price_cents + v_travel.fee_cents;

  v_reference := 'SM-' || to_char(now(), 'YYYY') || '-' ||
    upper(substr(md5(gen_random_uuid()::text), 1, 6));

  begin
    insert into bookings (
      reference, customer_user_id,
      guest_name, guest_email, guest_phone, guest_address,
      service_id, service_pack_id, date, start_time, status,
      service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents,
      notes, intervention_lat, intervention_lng, one_way_distance_km,
      included_radius_km, travel_rate_per_km_cents, distance_calculation_status, distance_calculated_at
    ) values (
      v_reference, v_customer_user_id,
      case when v_customer_user_id is null then nullif(trim(p_guest_name), '') end,
      case when v_customer_user_id is null then nullif(trim(p_guest_email), '') end,
      case when v_customer_user_id is null then nullif(trim(p_guest_phone), '') end,
      case when v_customer_user_id is null then nullif(trim(p_guest_address), '') end,
      v_service.id, v_service_pack_id, p_date, p_start_time, 'PENDING',
      v_duration_minutes, v_price_cents, v_travel.fee_cents, 0, v_total_cents,
      nullif(trim(p_notes), ''), p_intervention_lat, p_intervention_lng, p_one_way_distance_km,
      v_travel.radius_km, v_travel.rate_cents, v_travel.calc_status, now()
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  return query select v_booking_id, v_reference, v_total_cents;
end;
$$;

revoke all on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, numeric, double precision, double precision) from public;
grant execute on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, numeric, double precision, double precision) to authenticated, anon;
