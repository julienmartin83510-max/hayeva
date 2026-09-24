-- ============================================================
-- Mise en conformité juridique — preuve d'acceptation des CGV et du
-- mécanisme d'exécution anticipée avant la fin du délai de rétractation
-- (Code de la consommation, art. L221-18 et s., L221-28)
-- ============================================================
-- Portée strictement additive : nouvelles colonnes sur bookings (valeurs
-- par défaut neutres, aucune ligne existante affectée) + nouveaux
-- paramètres optionnels (avec valeur par défaut) ajoutés À LA FIN des
-- fonctions create_booking() et create_guest_or_quote_booking(), sans
-- rien changer aux paramètres déjà en place. Tout le reste (validations,
-- calcul du déplacement, RLS, autres colonnes) reste identique à la
-- version en place (0014_free_travel_premium_packs.sql /
-- 0013_professional_booking_linkage.sql).
--
-- Le frontend (sudmaintenance.html) envoie déjà ces nouveaux paramètres à
-- chaque réservation depuis la refonte juridique du site ; s'il les
-- envoie avant que cette migration soit appliquée, PostgREST répond
-- PGRST202 et le frontend retente automatiquement l'appel sans ces
-- champs (voir callBookingRpc()) — aucune réservation n'est bloquée par
-- l'ordre d'application, mais la preuve de consentement n'est conservée
-- qu'à partir du moment où cette migration est exécutée.

alter table bookings
  add column if not exists cgv_version text,
  add column if not exists cgv_accepted_at timestamptz,
  add column if not exists early_execution_requested boolean not null default false,
  add column if not exists early_execution_consented_at timestamptz,
  add column if not exists withdrawal_forfeited_ack boolean not null default false;

comment on column bookings.cgv_version is 'Version des CGV affichée au client au moment de sa demande (voir CGV_VERSION côté frontend) — preuve de la version acceptée.';
comment on column bookings.early_execution_requested is 'Le client a expressément demandé que la prestation commence avant la fin du délai légal de rétractation de 14 jours (Code de la consommation, art. L221-28). Recalculé/validé côté serveur : jamais accepté tel quel si la date demandée ne le justifie pas.';
comment on column bookings.withdrawal_forfeited_ack is 'Le client reconnaît qu''il perdra son droit de rétractation une fois la prestation intégralement exécutée (Code de la consommation, art. L221-28).';

-- create_booking() : identique à 0014_free_travel_premium_packs.sql, avec
-- 3 nouveaux paramètres optionnels ajoutés à la fin et leur prise en
-- compte lors de l'insertion.
create or replace function create_booking(
  p_service_slug text,
  p_date date,
  p_start_time time,
  p_service_pack_slug text default null,
  p_customer_address_id uuid default null,
  p_equipment_id uuid default null,
  p_notes text default null,
  p_distance_quote text default null,
  p_cgv_version text default null,
  p_early_execution_requested boolean default false,
  p_withdrawal_forfeited_ack boolean default false
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

  -- Acceptation des CGV obligatoire pour toute nouvelle réservation :
  -- jamais de contrat conclu sans preuve d'acceptation conservée.
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

  v_free_travel := is_free_travel_pack(p_service_pack_slug);
  select * into v_quote from verify_distance_quote(p_distance_quote);
  select * into v_travel from compute_travel_fee_cents(
    case when v_quote.valid then v_quote.distance_km else null end,
    v_free_travel
  );
  v_total_cents := v_price_cents + v_travel.fee_cents;

  -- La demande d'exécution anticipée n'a de portée légale que si la date
  -- choisie peut effectivement tomber avant la fin du délai de
  -- rétractation de 14 jours : jamais fait confiance à un booléen envoyé
  -- tel quel par le client, toujours recalculé depuis p_date déjà validée
  -- ci-dessus (même principe que pour le déplacement gratuit).
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
$$;

revoke all on function create_booking(text, date, time, text, uuid, uuid, text, text, text, boolean, boolean) from public;
grant execute on function create_booking(text, date, time, text, uuid, uuid, text, text, text, boolean, boolean) to authenticated;
revoke execute on function create_booking(text, date, time, text, uuid, uuid, text, text, text, boolean, boolean) from anon;

-- L'ancienne signature (8 paramètres, sans les champs de consentement)
-- est supprimée : sinon elle coexisterait avec la nouvelle comme une
-- fonction distincte au lieu d'être remplacée, et resterait orpheline et
-- appelable sans preuve de CGV.
drop function if exists create_booking(text, date, time, text, uuid, uuid, text, text);

-- create_guest_or_quote_booking() : même changement (3 paramètres en
-- plus, même recalcul serveur de v_early_execution). Reste identique à la
-- version en place (0014_free_travel_premium_packs.sql /
-- 0013_professional_booking_linkage.sql) pour tout le reste.
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
  p_distance_quote text default null,
  p_cgv_version text default null,
  p_early_execution_requested boolean default false,
  p_withdrawal_forfeited_ack boolean default false
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

  -- Même recalcul serveur qu'au-dessus, et jamais appliqué à un compte
  -- professionnel (B2B), qui n'est pas concerné par le droit de
  -- rétractation des consommateurs.
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
$$;

revoke all on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, text, text, boolean, boolean) from public;
grant execute on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, text, text, boolean, boolean) to authenticated, anon;

drop function if exists create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, text);
