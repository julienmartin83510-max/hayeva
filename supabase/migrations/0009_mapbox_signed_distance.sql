-- ============================================================
-- Distance routière réelle (Mapbox) validée côté serveur par signature
-- ============================================================
-- Remplace l'estimation par correspondance de ville (TRAVEL_TOWNS/haversine,
-- côté frontend uniquement) par un vrai calcul d'itinéraire routier
-- (Mapbox Directions API, appelé depuis l'Edge Function calculate-travel-
-- distance avec le token secret Mapbox — jamais exposé au navigateur).
--
-- SÉCURITÉ (point explicitement demandé) : create_booking() et
-- create_guest_or_quote_booking() ne font plus confiance à un nombre de
-- kilomètres envoyé tel quel par le client. Le client envoie désormais un
-- "devis de distance" SIGNÉ par calculate-travel-distance (HMAC-SHA256,
-- secret partagé stocké une seule fois dans Vault — même pattern que
-- webhook_secret, pour ne pas répéter le problème de désynchronisation déjà
-- rencontré). Le serveur vérifie la signature et l'âge du devis avant de
-- faire confiance à la distance qu'il contient ; un devis absent, invalide
-- ou expiré est traité exactement comme une distance inconnue
-- (distance_calculation_status = 'unavailable'), jamais comme 0 km.

create extension if not exists pgcrypto;

-- Adresses enregistrées : lat/lng ajoutés pour permettre un vrai calcul
-- routier aussi pour une adresse déjà enregistrée par un client connecté
-- (géocodée une fois au moment de l'enregistrement de l'adresse). Les
-- adresses existantes gardent lat/lng = null (statut 'unavailable' tant
-- qu'elles n'ont pas été re-sélectionnées via l'autocomplétion) — aucune
-- donnée existante n'est modifiée ni supposée.
alter table customer_addresses add column lat double precision;
alter table customer_addresses add column lng double precision;

-- ---------------------------------------------------------------------
-- Secret de signature des devis de distance — une seule entrée Vault, lue
-- à la fois par les fonctions SQL (vérification) et par l'Edge Function
-- calculate-travel-distance (signature), via get_quote_signing_secret()
-- ci-dessous plutôt que par un secret Edge Function dupliqué : une seule
-- source, aucun risque de désynchronisation comme celui déjà rencontré
-- avec WEBHOOK_SECRET.
--
-- ATTENTION AVANT D'EXÉCUTER : remplace REMPLACER_PAR_UN_SECRET par une
-- valeur aléatoire (ex. sortie de `openssl rand -hex 32`), différente de
-- WEBHOOK_SECRET. Ne commite jamais la vraie valeur.
do $$
declare
  v_id uuid;
begin
  select id into v_id from vault.secrets where name = 'quote_signing_secret';
  if v_id is null then
    perform vault.create_secret('REMPLACER_PAR_UN_SECRET', 'quote_signing_secret', 'Signature HMAC des devis de distance Mapbox (calculate-travel-distance <-> create_booking)');
  else
    perform vault.update_secret(v_id, 'REMPLACER_PAR_UN_SECRET');
  end if;
end $$;

-- Accessible UNIQUEMENT par service_role (donc uniquement depuis l'Edge
-- Function, jamais depuis le navigateur avec la clé anon/authenticated) :
-- c'est ce qui permet à calculate-travel-distance de signer un devis avec
-- le même secret que celui que create_booking() utilisera pour le vérifier.
create or replace function get_quote_signing_secret()
returns text
language sql
security definer
set search_path = public
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'quote_signing_secret';
$$;
revoke all on function get_quote_signing_secret() from public;
grant execute on function get_quote_signing_secret() to service_role;

-- ---------------------------------------------------------------------
-- Vérifie un devis de distance signé : "<payload base64>.<signature hex>",
-- payload JSON {"lat":..,"lng":..,"distance_km":..,"issued_at":<epoch ms>}.
-- Un devis invalide, mal signé, ou vieux de plus de 30 minutes (le client a
-- eu largement le temps de confirmer sa demande ; au-delà, mieux vaut
-- recalculer qu'utiliser un tarif potentiellement périmé) est rejeté :
-- valid=false, jamais une distance inventée.
create or replace function verify_distance_quote(p_quote text)
returns table(valid boolean, distance_km numeric, lat double precision, lng double precision)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
  v_dot_pos int;
  v_payload_b64 text;
  v_signature text;
  v_expected_sig text;
  v_payload json;
  v_issued_at bigint;
begin
  if p_quote is null or p_quote = '' then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;

  v_dot_pos := position('.' in p_quote);
  if v_dot_pos = 0 then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;
  v_payload_b64 := substring(p_quote from 1 for v_dot_pos - 1);
  v_signature := substring(p_quote from v_dot_pos + 1);

  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'quote_signing_secret';
  if v_secret is null then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;

  v_expected_sig := encode(hmac(v_payload_b64, v_secret, 'sha256'), 'hex');
  if v_expected_sig <> v_signature then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;

  begin
    v_payload := convert_from(decode(v_payload_b64, 'base64'), 'UTF8')::json;
  exception when others then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end;

  v_issued_at := (v_payload->>'issued_at')::bigint;
  if v_issued_at is null or (extract(epoch from now()) * 1000 - v_issued_at) > (30 * 60 * 1000) then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;

  return query select
    true,
    (v_payload->>'distance_km')::numeric,
    (v_payload->>'lat')::double precision,
    (v_payload->>'lng')::double precision;
end;
$$;
revoke all on function verify_distance_quote(text) from public;

-- ---------------------------------------------------------------------
-- create_booking() / create_guest_or_quote_booking() recréées : remplacent
-- p_one_way_distance_km/p_intervention_lat/p_intervention_lng (des nombres
-- bruts, donc falsifiables) par un unique p_distance_quote (le devis signé).
-- La distance utilisée pour le calcul est TOUJOURS celle extraite du devis
-- vérifié, jamais une valeur transmise séparément.
drop function if exists create_booking(text, date, time, text, uuid, uuid, text, numeric, double precision, double precision);

create or replace function create_booking(
  p_service_slug text,
  p_date date,
  p_start_time time,
  p_service_pack_slug text default null,
  p_customer_address_id uuid default null,
  p_equipment_id uuid default null,
  p_notes text default null,
  p_distance_quote text default null
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
  v_quote record;
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

  select * into v_quote from verify_distance_quote(p_distance_quote);
  select * into v_travel from compute_travel_fee_cents(case when v_quote.valid then v_quote.distance_km else null end);
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
      nullif(trim(p_notes), ''),
      case when v_quote.valid then v_quote.lat else null end,
      case when v_quote.valid then v_quote.lng else null end,
      case when v_quote.valid then v_quote.distance_km else null end,
      v_travel.radius_km, v_travel.rate_cents, v_travel.calc_status, now()
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  return query select v_booking_id, v_reference, v_total_cents;
end;
$$;

revoke all on function create_booking(text, date, time, text, uuid, uuid, text, text) from public;
grant execute on function create_booking(text, date, time, text, uuid, uuid, text, text) to authenticated;
revoke execute on function create_booking(text, date, time, text, uuid, uuid, text, text) from anon;

drop function if exists create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, numeric, double precision, double precision);

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
  p_distance_quote text default null
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
  v_quote record;
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

  select * into v_quote from verify_distance_quote(p_distance_quote);
  select * into v_travel from compute_travel_fee_cents(case when v_quote.valid then v_quote.distance_km else null end);
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
      nullif(trim(p_notes), ''),
      case when v_quote.valid then v_quote.lat else null end,
      case when v_quote.valid then v_quote.lng else null end,
      case when v_quote.valid then v_quote.distance_km else null end,
      v_travel.radius_km, v_travel.rate_cents, v_travel.calc_status, now()
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  return query select v_booking_id, v_reference, v_total_cents;
end;
$$;

revoke all on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, text) from public;
grant execute on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, text) to authenticated, anon;
