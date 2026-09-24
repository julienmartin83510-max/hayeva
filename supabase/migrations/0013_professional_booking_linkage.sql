-- ============================================================
-- Rattachement des réservations professionnelles à professional_account_id
-- ============================================================
-- Constat (audit demandé avant toute modification) : create_guest_or_quote_
-- booking() ne reconnaît que global_role='customer' pour rattacher une
-- réservation à un compte (customer_user_id). Un compte 'professional'
-- authentifié tombe dans la branche "invité" : la réservation est bien
-- enregistrée, mais avec professional_account_id = NULL. Vérifié en direct
-- sur les données réelles : 0 réservation sur 19 avait professional_
-- account_id renseigné. Conséquence : aucune réservation professionnelle
-- n'est techniquement récupérable pour son propre compte — les policies RLS
-- existantes ("bookings: owner or admin read", 0001_init.sql) restreignent
-- déjà correctement l'accès via professional_account_id in (select
-- my_professional_account_ids()), mais il n'y a rien à filtrer puisque la
-- colonne n'est jamais renseignée. Ce n'est donc pas un problème d'affichage
-- (Espace Professionnel) ni de policy RLS (déjà correcte, aucune modifiée
-- ici) : uniquement ce maillon manquant à l'écriture.
--
-- Changement, strictement additif et rétrocompatible : quand l'appelant
-- authentifié a global_role='professional', son professional_account_id
-- (via professional_members, même fonction que my_professional_account_ids()
-- utilise déjà pour les policies) est résolu et inséré. Les champs
-- guest_name/guest_email/guest_phone/guest_address restent envoyés et
-- stockés tels quels (aucun changement du formulaire frontend nécessaire —
-- il continue d'envoyer ces valeurs exactement comme avant) : ils servent de
-- coordonnées de contact affichées à l'admin (admContactFor priorise déjà
-- guest_name s'il est présent), le professional_account_id servant, lui,
-- uniquement à la visibilité RLS pour le compte concerné. Le parcours
-- particulier (create_booking) et invité pur (sans session) sont totalement
-- inchangés.
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

  select * into v_quote from verify_distance_quote(p_distance_quote);
  select * into v_travel from compute_travel_fee_cents(case when v_quote.valid then v_quote.distance_km else null end);
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
