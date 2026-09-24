-- ============================================================
-- Déplacement 100% offert sur les packs d'entretien "Premium"
-- ============================================================
-- Portée : uniquement les 3 packs d'entretien haut de gamme (climatisation,
-- chaudière gaz, chaudière fioul) — jamais les autres prestations/packs, dont
-- les règles de déplacement (20 km inclus puis 0,70 €/km aller-retour)
-- restent strictement inchangées.
--
-- Calcul définitif toujours côté serveur (jamais confiance dans un montant
-- envoyé par le navigateur, même règle que pour la distance signée) : le
-- forfait à 0 € est décidé ici, dans compute_travel_fee_cents(), à partir du
-- slug de pack réellement transmis aux fonctions de réservation — jamais
-- d'un indicateur "gratuit" que le client pourrait forger côté JS.
create or replace function is_free_travel_pack(p_pack_slug text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select coalesce(p_pack_slug, '') in (
    'clim-premium',
    'chauffage-chaudiere-gaz-premium',
    'chauffage-chaudiere-fioul-premium'
  );
$$;
revoke all on function is_free_travel_pack(text) from public;
grant execute on function is_free_travel_pack(text) to authenticated, anon;

-- L'ancienne signature à un seul paramètre (numeric) est supprimée : sinon
-- elle coexisterait avec la nouvelle (numeric, boolean) comme une fonction
-- distincte au lieu d'être remplacée, et resterait orpheline.
drop function if exists compute_travel_fee_cents(numeric);

create or replace function compute_travel_fee_cents(p_distance_km numeric, p_free_travel boolean default false)
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
  if p_free_travel then
    -- Statut 'ok' (pas 'unavailable') : c'est un 0 € délibéré et connu, pas
    -- une distance non calculée en attente de vérification manuelle.
    return query select 0, v_settings.included_radius_km, v_settings.rate_per_km_cents, 'ok'::text;
    return;
  end if;
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
revoke all on function compute_travel_fee_cents(numeric, boolean) from public;

-- create_booking() : seul changement, un v_free_travel calculé depuis le pack
-- demandé, passé à compute_travel_fee_cents(). Tout le reste (validations,
-- colonnes, exceptions) est identique à la version en place
-- (0009_mapbox_signed_distance.sql).
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
  v_free_travel boolean;
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

  v_free_travel := is_free_travel_pack(p_service_pack_slug);
  select * into v_quote from verify_distance_quote(p_distance_quote);
  select * into v_travel from compute_travel_fee_cents(
    case when v_quote.valid then v_quote.distance_km else null end,
    v_free_travel
  );
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

-- create_guest_or_quote_booking() : même changement unique (v_free_travel).
-- Reste identique à la version en place (0013_professional_booking_linkage.sql).
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

  v_reference := 'SM-' || to_char(now(), 'YYYY') || '-' ||
    upper(substr(md5(gen_random_uuid()::text), 1, 6));

  begin
    insert into bookings (
      reference, customer_user_id, professional_account_id,
      guest_name, guest_email, guest_phone, guest_address,
      service_id, service_pack_id, date, start_time, status,
      service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents,
      notes, intervention_lat, intervention_lng, one_way_distance_km,
      included_radius_km, travel_rate_per_km_cents, distance_calculation_status, distance_calculated_at
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
