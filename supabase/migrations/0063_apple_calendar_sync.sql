-- ============================================================
-- Synchronisation Apple Calendar / iCloud (CalDAV) — bidirectionnelle.
-- ============================================================
-- Architecture choisie après audit de l'existant (aucune reconstruction) :
--
-- HAYEVA → Apple (push) : un nouveau trigger AFTER INSERT/UPDATE sur
-- bookings, exactement le même patron que notify_customer_status_change()
-- et notify-booking-change (0008_webhook_secret_vault.sql) — pg_net +
-- secret Vault partagé, jamais la clé service_role exposée ici. Appelle la
-- nouvelle Edge Function calendar-sync (action=push) qui construit
-- l'événement iCalendar et le dépose via CalDAV PUT sur le calendrier
-- "HAYEVA — Rendez-vous".
--
-- Apple → HAYEVA (pull, anti-double-réservation) : une nouvelle table
-- external_busy_blocks reçoit les créneaux occupés des calendriers Apple
-- configurés comme bloquants (jamais le contenu — titre, description —
-- seulement la plage horaire, voir confidentialité section 20). pg_cron
-- appelle périodiquement calendar-sync (action=pull), même patron que
-- hayeva-reminder-cycle (0053_reminder_scheduler.sql).
--
-- Anti-doublon réel (section 14) : bookings a déjà une contrainte
-- d'exclusion GiST (bookings_no_overlapping_slots) — gold standard,
-- conservée telle quelle, jamais touchée. Comme une contrainte EXCLUDE ne
-- peut pas porter sur deux tables à la fois, le blocage par un événement
-- Apple est vérifié explicitement par check_calendar_block_conflict(),
-- appelée au tout début de create_booking/create_guest_or_quote_booking/
-- admin_reschedule_booking/reschedule_own_booking, sous un verrou
-- consultatif (pg_advisory_xact_lock) qui sérialise les tentatives sur la
-- même journée — seule façon d'obtenir une vérification atomique entre
-- deux tables distinctes côté serveur (jamais confiance au navigateur).
--
-- Boucle de synchronisation (section 15, TEST10) : chaque événement créé
-- par HAYEVA porte un UID préfixé 'hayeva-' + booking id. Le pull ignore
-- strictement tout événement dont l'UID commence par ce préfixe, qu'il
-- revienne ou non dans la réponse CalDAV — jamais de doublon ni de boucle.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Connexion iCloud (une seule ligne en pratique — l'entreprise n'a
-- qu'un seul agenda professionnel). Ne contient JAMAIS le mot de passe
-- d'application lui-même (stocké uniquement dans Supabase Vault, voir
-- fonction get_apple_caldav_app_password ci-dessous) — seulement les URLs
-- CalDAV découvertes et l'identifiant Apple pour affichage admin.
-- ------------------------------------------------------------
create table if not exists calendar_connections (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'icloud' check (provider in ('icloud')),
  apple_id_email text,
  caldav_principal_url text,
  target_calendar_url text,
  target_calendar_display_name text not null default 'HAYEVA — Rendez-vous',
  connected boolean not null default false,
  last_push_sync_at timestamptz,
  last_pull_sync_at timestamptz,
  last_sync_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table calendar_connections enable row level security;
create policy "calendar_connections: admin only" on calendar_connections
  for all using (is_admin()) with check (is_admin());

comment on table calendar_connections is 'Connexion CalDAV iCloud de HAYEVA (une ligne). Le mot de passe d''application Apple n''est JAMAIS stocké ici — uniquement dans Supabase Vault (secret apple_caldav_app_password), lu uniquement par get_apple_caldav_app_password(), jamais exposé au frontend.';

-- ------------------------------------------------------------
-- 2) Calendriers Apple pris en compte pour le blocage de disponibilité
-- (section 11) — un compte iCloud peut avoir plusieurs calendriers
-- (Personnel, Anniversaires, Jours fériés...), chacun activable/
-- désactivable indépendamment comme source de blocage.
-- ------------------------------------------------------------
create table if not exists calendar_blocking_sources (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references calendar_connections(id) on delete cascade,
  calendar_url text not null,
  display_name text,
  is_blocking boolean not null default true,
  created_at timestamptz not null default now(),
  unique (connection_id, calendar_url)
);

alter table calendar_blocking_sources enable row level security;
create policy "calendar_blocking_sources: admin only" on calendar_blocking_sources
  for all using (is_admin()) with check (is_admin());

-- ------------------------------------------------------------
-- 3) Créneaux occupés importés depuis Apple (section 10, 20) — jamais le
-- titre ni la description de l'événement personnel, uniquement la plage
-- horaire : le client ne doit jamais pouvoir déduire la nature de
-- l'indisponibilité (confidentialité, section 20). external_uid identifie
-- l'événement Apple d'origine pour une mise à jour propre (jamais un
-- doublon) lors d'un pull ultérieur.
-- ------------------------------------------------------------
create table if not exists external_busy_blocks (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references calendar_blocking_sources(id) on delete cascade,
  external_uid text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  is_all_day boolean not null default false,
  etag text,
  synced_at timestamptz not null default now(),
  unique (source_id, external_uid)
);
create index if not exists idx_external_busy_blocks_range on external_busy_blocks using gist (tstzrange(starts_at, ends_at));

alter table external_busy_blocks enable row level security;
create policy "external_busy_blocks: admin only" on external_busy_blocks
  for all using (is_admin()) with check (is_admin());
-- Aucune policy pour anon/authenticated : le client ne doit jamais pouvoir
-- lire le contenu de ces blocages directement (seul le résultat déjà
-- filtré — créneau disponible/indisponible — est exposé, via les fonctions
-- de réservation elles-mêmes).

-- ------------------------------------------------------------
-- 4) Journal technique de synchronisation (section 15, 16, 18) — permet
-- d'afficher les erreurs dans l'administration et de diagnostiquer un
-- échec iCloud temporaire sans jamais perdre l'information.
-- ------------------------------------------------------------
create table if not exists calendar_sync_log (
  id uuid primary key default gen_random_uuid(),
  direction text not null check (direction in ('push', 'pull')),
  booking_id uuid references bookings(id) on delete set null,
  status text not null check (status in ('ok', 'error')),
  detail text,
  created_at timestamptz not null default now()
);
create index if not exists idx_calendar_sync_log_created on calendar_sync_log (created_at desc);

alter table calendar_sync_log enable row level security;
create policy "calendar_sync_log: admin only" on calendar_sync_log
  for all using (is_admin()) with check (is_admin());

-- ------------------------------------------------------------
-- 5) Traçabilité par réservation (section 5, 18) — jamais seulement le
-- titre de l'événement pour le retrouver : l'UID est la seule référence
-- fiable (section 5 du cahier des charges, explicite sur ce point).
-- ------------------------------------------------------------
alter table bookings
  add column if not exists calendar_event_uid text,
  add column if not exists calendar_sync_status text not null default 'NOT_SYNCED'
    check (calendar_sync_status in ('NOT_SYNCED', 'PENDING', 'SYNCED', 'ERROR')),
  add column if not exists calendar_last_sync_at timestamptz,
  add column if not exists calendar_sync_error text;

create unique index if not exists idx_bookings_calendar_event_uid on bookings (calendar_event_uid) where calendar_event_uid is not null;

-- ------------------------------------------------------------
-- 6) Marge avant/après intervention (section 13) — réutilise travel_settings
-- (table à une seule ligne, déjà le bon endroit pour un réglage global
-- d'entreprise, voir 0007_travel_and_emails.sql) plutôt qu'une nouvelle
-- table à une ligne redondante.
-- ------------------------------------------------------------
alter table travel_settings
  add column if not exists margin_before_minutes integer not null default 0 check (margin_before_minutes >= 0 and margin_before_minutes <= 240),
  add column if not exists margin_after_minutes integer not null default 0 check (margin_after_minutes >= 0 and margin_after_minutes <= 240);

-- ------------------------------------------------------------
-- 7) Lecture sécurisée du mot de passe d'application Apple — même patron
-- que get_quote_signing_secret, MAIS avec le correctif déjà appliqué en
-- 0062 à find_or_create_client : EXECUTE immédiatement révoqué pour
-- anon/authenticated (jamais appelable depuis le frontend, uniquement par
-- les fonctions SECURITY DEFINER ci-dessous et l'Edge Function via le rôle
-- service_role qui n'est jamais soumis à ces GRANT/REVOKE).
-- ------------------------------------------------------------
create or replace function get_apple_caldav_app_password()
returns text
language sql
security definer
set search_path = public
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'apple_caldav_app_password';
$$;
revoke all on function get_apple_caldav_app_password() from public, anon, authenticated;

-- ------------------------------------------------------------
-- 8) Vérification de blocage externe (section 10, 14) — appelée en tout
-- début des 4 fonctions de réservation/déplacement ci-dessous. Le verrou
-- consultatif (clé = date demandée) sérialise les tentatives concurrentes
-- sur le même jour : seule façon d'obtenir une vérification atomique
-- lorsque deux tables distinctes sont en jeu (external_busy_blocks ne peut
-- pas partager l'EXCLUDE GiST de bookings). Les marges avant/après
-- (section 13) sont appliquées ici, pas dans les données stockées.
-- ------------------------------------------------------------
create or replace function check_calendar_block_conflict(p_date date, p_start_time time, p_duration_minutes integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_margin_before integer;
  v_margin_after integer;
  v_slot_start timestamptz;
  v_slot_end timestamptz;
  v_conflict boolean;
begin
  perform pg_advisory_xact_lock(hashtext('hayeva_calendar_block_' || p_date::text));

  select coalesce(margin_before_minutes, 0), coalesce(margin_after_minutes, 0)
    into v_margin_before, v_margin_after
    from travel_settings limit 1;

  v_slot_start := (p_date + p_start_time) - make_interval(mins => coalesce(v_margin_before, 0));
  v_slot_end := (p_date + p_start_time) + make_interval(mins => p_duration_minutes) + make_interval(mins => coalesce(v_margin_after, 0));

  select exists (
    select 1
    from external_busy_blocks b
    join calendar_blocking_sources s on s.id = b.source_id
    where s.is_blocking = true
      and tstzrange(b.starts_at, b.ends_at) && tstzrange(v_slot_start, v_slot_end)
  ) into v_conflict;

  if v_conflict then
    raise exception 'Ce créneau est indisponible (agenda synchronisé). Choisissez un autre horaire.';
  end if;
end;
$$;
revoke all on function check_calendar_block_conflict(date, time, integer) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 9) Intégration dans les 4 points d'entrée réels de création/déplacement
-- d'une réservation (section 6, 7, 14) — un seul appel ajouté en tête de
-- chacune, aucune autre ligne modifiée. CREATE OR REPLACE reprend le corps
-- exact déjà en production (audité ci-dessus), jamais réécrit.
-- ------------------------------------------------------------
create or replace function public.create_booking(p_service_slug text, p_date date, p_start_time time without time zone, p_service_pack_slug text DEFAULT NULL::text, p_customer_address_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text, p_distance_quote text DEFAULT NULL::text, p_cgv_version text DEFAULT NULL::text, p_early_execution_requested boolean DEFAULT false, p_withdrawal_forfeited_ack boolean DEFAULT false)
 RETURNS TABLE(booking_id uuid, reference text, total_cents integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_quote record;
  v_free_travel boolean;
  v_early_execution boolean;
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

  if coalesce(trim(p_cgv_version), '') = '' then
    raise exception 'Vous devez accepter les Conditions générales de vente pour confirmer votre demande.';
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

  perform check_calendar_block_conflict(p_date, p_start_time, v_duration_minutes);

  v_free_travel := is_free_travel_pack(p_service_pack_slug);
  select * into v_quote from verify_distance_quote(p_distance_quote);
  select * into v_travel from compute_travel_fee_cents(
    case when v_quote.valid then v_quote.distance_km else null end,
    v_free_travel
  );
  v_total_cents := v_price_cents + v_travel.fee_cents;

  v_early_execution := coalesce(p_early_execution_requested, false)
    and p_date < (current_date + interval '14 days');

  v_reference := 'SM-' || to_char(now(), 'YYYY') || '-' ||
    upper(substr(md5(gen_random_uuid()::text), 1, 6));

  begin
    insert into bookings (
      reference, customer_user_id, customer_address_id, equipment_id,
      service_id, service_pack_id, date, start_time, status,
      service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents,
      notes, intervention_lat, intervention_lng, one_way_distance_km,
      included_radius_km, travel_rate_per_km_cents, distance_calculation_status, distance_calculated_at,
      cgv_version, cgv_accepted_at,
      early_execution_requested, early_execution_consented_at, withdrawal_forfeited_ack
    ) values (
      v_reference, v_uid, p_customer_address_id, p_equipment_id,
      v_service.id, v_service_pack_id, p_date, p_start_time, 'PENDING',
      v_duration_minutes, v_price_cents, v_travel.fee_cents, 0, v_total_cents,
      nullif(trim(p_notes), ''),
      case when v_quote.valid then v_quote.lat else null end,
      case when v_quote.valid then v_quote.lng else null end,
      case when v_quote.valid then v_quote.distance_km else null end,
      v_travel.radius_km, v_travel.rate_cents, v_travel.calc_status, now(),
      p_cgv_version, now(),
      v_early_execution, case when v_early_execution then now() else null end,
      v_early_execution and coalesce(p_withdrawal_forfeited_ack, false)
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  return query select v_booking_id, v_reference, v_total_cents;
end;
$function$;

create or replace function public.create_guest_or_quote_booking(p_service_slug text, p_date date, p_start_time time without time zone, p_service_pack_slug text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_guest_name text DEFAULT NULL::text, p_guest_email text DEFAULT NULL::text, p_guest_phone text DEFAULT NULL::text, p_guest_address text DEFAULT NULL::text, p_distance_quote text DEFAULT NULL::text, p_cgv_version text DEFAULT NULL::text, p_early_execution_requested boolean DEFAULT false, p_withdrawal_forfeited_ack boolean DEFAULT false)
 RETURNS TABLE(booking_id uuid, reference text, total_cents integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_customer_user_id uuid := null;
  v_professional_account_id uuid := null;
  v_service services%rowtype;
  v_pack service_packs%rowtype;
  v_service_pack_id uuid;
  v_price_cents integer;
  v_duration_minutes integer;
  v_reference text;
  v_booking_id uuid;
  v_travel record;
  v_quote record;
  v_total_cents integer;
  v_free_travel boolean;
  v_early_execution boolean;
begin
  if p_date < current_date then
    raise exception 'Impossible de réserver une date déjà passée.';
  end if;

  if coalesce(trim(p_cgv_version), '') = '' then
    raise exception 'Vous devez accepter les Conditions générales de vente pour confirmer votre demande.';
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
      v_price_cents := 0;
      v_duration_minutes := coalesce(v_service.duration_minutes, 60);
    end if;
  end if;

  perform check_calendar_block_conflict(p_date, p_start_time, v_duration_minutes);

  if v_uid is not null then
    select global_role into v_role from profiles where user_id = v_uid;
    if v_role = 'customer' then
      v_customer_user_id := v_uid;
    elsif v_role = 'professional' then
      select professional_account_id into v_professional_account_id
      from professional_members where user_id = v_uid limit 1;
    end if;
  end if;

  if v_customer_user_id is null and v_professional_account_id is null then
    if coalesce(trim(p_guest_name), '') = '' or coalesce(trim(p_guest_email), '') = '' then
      raise exception 'Merci de renseigner votre nom et votre e-mail pour confirmer la demande.';
    end if;
  end if;

  v_free_travel := is_free_travel_pack(p_service_pack_slug);
  select * into v_quote from verify_distance_quote(p_distance_quote);
  select * into v_travel from compute_travel_fee_cents(
    case when v_quote.valid then v_quote.distance_km else null end,
    v_free_travel
  );
  v_total_cents := v_price_cents + v_travel.fee_cents;

  v_early_execution := coalesce(p_early_execution_requested, false)
    and p_date < (current_date + interval '14 days')
    and v_professional_account_id is null;

  v_reference := 'SM-' || to_char(now(), 'YYYY') || '-' ||
    upper(substr(md5(gen_random_uuid()::text), 1, 6));

  begin
    insert into bookings (
      reference, customer_user_id, professional_account_id,
      guest_name, guest_email, guest_phone, guest_address,
      service_id, service_pack_id, date, start_time, status,
      service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents,
      notes, intervention_lat, intervention_lng, one_way_distance_km,
      included_radius_km, travel_rate_per_km_cents, distance_calculation_status, distance_calculated_at,
      cgv_version, cgv_accepted_at,
      early_execution_requested, early_execution_consented_at, withdrawal_forfeited_ack
    ) values (
      v_reference, v_customer_user_id, v_professional_account_id,
      nullif(trim(p_guest_name), ''),
      nullif(trim(p_guest_email), ''),
      nullif(trim(p_guest_phone), ''),
      nullif(trim(p_guest_address), ''),
      v_service.id, v_service_pack_id, p_date, p_start_time, 'PENDING',
      v_duration_minutes, v_price_cents, v_travel.fee_cents, 0, v_total_cents,
      nullif(trim(p_notes), ''),
      case when v_quote.valid then v_quote.lat else null end,
      case when v_quote.valid then v_quote.lng else null end,
      case when v_quote.valid then v_quote.distance_km else null end,
      v_travel.radius_km, v_travel.rate_cents, v_travel.calc_status, now(),
      p_cgv_version, now(),
      v_early_execution, case when v_early_execution then now() else null end,
      v_early_execution and coalesce(p_withdrawal_forfeited_ack, false)
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  return query select v_booking_id, v_reference, v_total_cents;
end;
$function$;

create or replace function public.admin_reschedule_booking(p_booking_id uuid, p_date date, p_start_time time without time zone)
 RETURNS TABLE(booking_id uuid, reference text, date date, start_time time without time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_booking bookings%rowtype;
  v_secret text;
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;

  select * into v_booking from bookings where id = p_booking_id;
  if not found then
    raise exception 'Réservation introuvable.';
  end if;

  if v_booking.status not in ('PENDING', 'CONFIRMED', 'IN_PROGRESS') then
    raise exception 'Ce rendez-vous ne peut plus être déplacé.';
  end if;

  perform check_calendar_block_conflict(p_date, p_start_time, v_booking.service_duration_minutes);

  begin
    update bookings
    set date = p_date, start_time = p_start_time, updated_at = now()
    where id = p_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau est déjà occupé par une autre réservation confirmée.';
  end;

  begin
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-booking-change',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
      body := jsonb_build_object(
        'event', 'rescheduled',
        'booking_id', p_booking_id,
        'old_date', v_booking.date,
        'old_start_time', v_booking.start_time,
        'new_date', p_date,
        'new_start_time', p_start_time
      )
    );
  exception
    when others then
      null;
  end;

  return query select p_booking_id, v_booking.reference, p_date, p_start_time;
end;
$function$;

create or replace function public.reschedule_own_booking(p_booking_id uuid, p_date date, p_start_time time without time zone)
 RETURNS TABLE(booking_id uuid, reference text, date date, start_time time without time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_booking bookings%rowtype;
  v_secret text;
begin
  if v_uid is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_booking from bookings where id = p_booking_id and customer_user_id = v_uid;
  if not found then
    raise exception 'Réservation introuvable ou non autorisée.';
  end if;

  if v_booking.status not in ('PENDING', 'CONFIRMED') then
    raise exception 'Ce rendez-vous ne peut plus être déplacé.';
  end if;

  if p_date < current_date then
    raise exception 'Impossible de déplacer un rendez-vous vers une date déjà passée.';
  end if;
  if p_date = current_date and p_start_time < (localtime + interval '60 minutes') then
    raise exception 'Merci de choisir un horaire au moins 1h à l''avance.';
  end if;
  if not is_slot_within_business_hours(p_date, p_start_time, v_booking.service_duration_minutes) then
    raise exception 'Ce créneau est en dehors de nos horaires d''ouverture.';
  end if;

  perform check_calendar_block_conflict(p_date, p_start_time, v_booking.service_duration_minutes);

  begin
    update bookings
    set date = p_date, start_time = p_start_time, updated_at = now()
    where id = p_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  begin
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-booking-change',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
      body := jsonb_build_object(
        'event', 'rescheduled',
        'booking_id', p_booking_id,
        'old_date', v_booking.date,
        'old_start_time', v_booking.start_time,
        'new_date', p_date,
        'new_start_time', p_start_time
      )
    );
  exception
    when others then
      null;
  end;

  return query select p_booking_id, v_booking.reference, p_date, p_start_time;
end;
$function$;

-- ------------------------------------------------------------
-- 10) Push HAYEVA → Apple (section 4, 6, 7, 8) — un seul trigger couvrant
-- création, confirmation, déplacement et annulation, même patron pg_net +
-- Vault que les triggers de notification existants (0008). Ne bloque
-- JAMAIS l'opération HAYEVA elle-même en cas d'échec (exception avalée,
-- consigné dans calendar_sync_status='ERROR' + calendar_sync_log — section
-- 16 : une panne iCloud ne doit jamais rendre HAYEVA inutilisable).
-- ------------------------------------------------------------
create or replace function sync_booking_to_calendar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
  v_action text;
begin
  if TG_OP = 'UPDATE' and NEW.status is distinct from OLD.status and NEW.status = 'CONFIRMED' then
    v_action := 'upsert';
  elsif TG_OP = 'UPDATE' and NEW.status is distinct from OLD.status and NEW.status = 'CANCELLED' and OLD.calendar_event_uid is not null then
    v_action := 'delete';
  elsif TG_OP = 'UPDATE' and NEW.status = 'CONFIRMED' and (NEW.date is distinct from OLD.date or NEW.start_time is distinct from OLD.start_time) then
    v_action := 'upsert';
  else
    return NEW;
  end if;

  begin
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/calendar-sync',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
      body := jsonb_build_object('action', v_action, 'booking_id', NEW.id)
    );
  exception
    when others then
      null;
  end;

  return NEW;
end;
$$;

drop trigger if exists trg_sync_booking_to_calendar on bookings;
create trigger trg_sync_booking_to_calendar
  after update on bookings
  for each row execute function sync_booking_to_calendar();

comment on function sync_booking_to_calendar is 'Déclenche la synchronisation Apple Calendar (push) de façon best-effort — un échec iCloud ne doit jamais faire échouer la mise à jour de la réservation elle-même (voir section 16 du cahier des charges).';

-- ------------------------------------------------------------
-- 11) RPC admin (section 17, 18) — lecture d'état + réglages, utilisées par
-- la nouvelle section "Agenda & synchronisation" de l'administration
-- (index.html). Aucune ne retourne jamais le mot de passe d'application.
-- ------------------------------------------------------------
create or replace function admin_calendar_sync_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_connection record;
  v_sources jsonb;
  v_recent_errors jsonb;
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;

  select * into v_connection from calendar_connections order by created_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'calendar_url', s.calendar_url, 'display_name', s.display_name, 'is_blocking', s.is_blocking
  ) order by s.display_name), '[]'::jsonb)
  into v_sources
  from calendar_blocking_sources s
  where s.connection_id = v_connection.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'direction', l.direction, 'status', l.status, 'detail', l.detail, 'created_at', l.created_at
  ) order by l.created_at desc), '[]'::jsonb)
  into v_recent_errors
  from (select * from calendar_sync_log where status = 'error' order by created_at desc limit 10) l;

  return jsonb_build_object(
    'connected', coalesce(v_connection.connected, false),
    'apple_id_email', v_connection.apple_id_email,
    'target_calendar_display_name', coalesce(v_connection.target_calendar_display_name, 'HAYEVA — Rendez-vous'),
    'last_push_sync_at', v_connection.last_push_sync_at,
    'last_pull_sync_at', v_connection.last_pull_sync_at,
    'last_sync_error', v_connection.last_sync_error,
    'sources', v_sources,
    'recent_errors', v_recent_errors,
    'margin_before_minutes', (select margin_before_minutes from travel_settings limit 1),
    'margin_after_minutes', (select margin_after_minutes from travel_settings limit 1)
  );
end;
$$;

create or replace function admin_set_calendar_source_blocking(p_source_id uuid, p_is_blocking boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  update calendar_blocking_sources set is_blocking = p_is_blocking where id = p_source_id;
end;
$$;

create or replace function admin_set_calendar_margins(p_before_minutes integer, p_after_minutes integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  if p_before_minutes < 0 or p_before_minutes > 240 or p_after_minutes < 0 or p_after_minutes > 240 then
    raise exception 'Marge invalide (0 à 240 minutes).';
  end if;
  update travel_settings set margin_before_minutes = p_before_minutes, margin_after_minutes = p_after_minutes;
end;
$$;

-- Déclenche une synchronisation immédiate (bouton "Synchroniser maintenant",
-- section 17) — best-effort, ne bloque jamais l'appel admin lui-même.
create or replace function admin_trigger_calendar_sync()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
  perform net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/calendar-sync',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
    body := jsonb_build_object('action', 'pull')
  );
end;
$$;

revoke all on function admin_calendar_sync_status() from public, anon, authenticated;
revoke all on function admin_set_calendar_source_blocking(uuid, boolean) from public, anon, authenticated;
revoke all on function admin_set_calendar_margins(integer, integer) from public, anon, authenticated;
revoke all on function admin_trigger_calendar_sync() from public, anon, authenticated;
grant execute on function admin_calendar_sync_status() to authenticated;
grant execute on function admin_set_calendar_source_blocking(uuid, boolean) to authenticated;
grant execute on function admin_set_calendar_margins(integer, integer) to authenticated;
grant execute on function admin_trigger_calendar_sync() to authenticated;

-- ------------------------------------------------------------
-- 12) Pull périodique (section 15) — même patron que hayeva-reminder-cycle
-- (0053_reminder_scheduler.sql) : pg_cron + pg_net + secret Vault partagé.
-- Toutes les 15 minutes, jamais plus fréquent (pas de dépendance à ce
-- qu'un navigateur reste ouvert, section 15).
-- ------------------------------------------------------------
select cron.schedule(
  'hayeva-calendar-pull-cycle',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/calendar-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'webhook_secret')
    ),
    body := jsonb_build_object('action', 'pull')
  );
  $$
);
