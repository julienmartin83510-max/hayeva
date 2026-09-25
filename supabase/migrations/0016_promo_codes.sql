-- ============================================================
-- Codes promotionnels — schéma + application réelle (jamais côté client seul)
-- ============================================================
-- Système générique (le premier code, HAYEVA100, n'est qu'une donnée parmi
-- d'autres) : chaque code cible explicitement UN élément du prix
-- (applies_to), jamais la réservation entière — c'est cette contrainte de
-- structure (pas une simple convention) qui empêche HAYEVA100 (-100%) de
-- s'appliquer ailleurs qu'au déplacement, voir compute_promo_discount()
-- plus bas : le rabais est systématiquement plafonné au montant de
-- l'élément ciblé, jamais au total.
--
-- Réutilise bookings.discount_cents, qui existait déjà depuis 0001_init.sql
-- (colonne "remise", jamais utilisée jusqu'ici, déjà protégée par
-- protect_booking_financial_fields() et déjà affichée automatiquement dans
-- l'Espace Client — voir ecLoadAppointments côté frontend, "Réduction −X")
-- plutôt que d'ajouter une colonne redondante.
--
-- Sécurité : la validité ET l'éligibilité sont revérifiées entièrement côté
-- serveur, à l'intérieur de create_booking()/create_guest_or_quote_booking()
-- (SECURITY DEFINER, non soumises à RLS) — jamais fait confiance à un
-- montant de réduction envoyé par le client. La vérification "aperçu" côté
-- navigateur (preview_promo_code, plus bas) n'est qu'un confort d'affichage
-- avant validation finale ; elle ne consomme jamais une utilisation.

-- ---------------------------------------------------------------------
-- 1. Table des codes
-- ---------------------------------------------------------------------
create table promo_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  discount_type text not null check (discount_type in ('PERCENT','FIXED_CENTS')),
  discount_value numeric not null check (discount_value > 0),
  -- Élément du prix concerné par la réduction — jamais le total directement :
  -- même une réduction TOTAL reste plafonnée à prestation+déplacement par
  -- compute_promo_discount() (jamais un montant négatif inventé au-delà).
  applies_to text not null default 'TRAVEL_FEE' check (applies_to in ('TRAVEL_FEE','SERVICE_PRICE','TOTAL')),
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  max_uses integer check (max_uses is null or max_uses > 0),
  max_uses_per_customer integer check (max_uses_per_customer is null or max_uses_per_customer > 0),
  -- Condition d'éligibilité optionnelle, revérifiée côté serveur à chaque
  -- réservation si renseignée (voir validate_promo_code()) : NONE = ouvert à
  -- quiconque connaît le code (cas de HAYEVA100 — jamais annoncé publiquement,
  -- seulement suggéré via le bandeau d'éligibilité du parcours de
  -- réservation, voir best_active_promo() plus bas). Les deux autres valeurs
  -- couvrent les deux types de conditions demandées pour ce bandeau.
  eligibility_rule text not null default 'NONE'
    check (eligibility_rule in ('NONE','NEW_CUSTOMER','OUTSIDE_FREE_RADIUS')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  constraint promo_codes_percent_range check (
    discount_type <> 'PERCENT' or (discount_value > 0 and discount_value <= 100)
  )
);
-- Un code est toujours comparé normalisé (majuscules, sans espaces) : l'index
-- unique porte donc sur la forme normalisée, pas sur la colonne brute, pour
-- empêcher deux lignes "HAYEVA100" / "hayeva100" de coexister.
create unique index idx_promo_codes_code_normalized on promo_codes (upper(trim(code)));
create index idx_promo_codes_active on promo_codes (is_active);

alter table promo_codes enable row level security;
create policy "promo_codes: admin read" on promo_codes
  for select using (is_admin());
create policy "promo_codes: admin write" on promo_codes
  for insert with check (is_admin());
create policy "promo_codes: admin update" on promo_codes
  for update using (is_admin()) with check (is_admin());
create policy "promo_codes: admin delete" on promo_codes
  for delete using (is_admin());

-- Pas de trigger générique pour updated_at (aucune autre table du projet
-- n'en a — ex. professional_accounts.updated_at n'est jamais mis à jour
-- automatiquement non plus) : le panneau Administration le fixe lui-même
-- explicitement à chaque écriture directe (update ... set updated_at = now()).

-- ---------------------------------------------------------------------
-- 2. Historique des utilisations — sert à la fois à compter les
--    utilisations restantes (max_uses / max_uses_per_customer) et à afficher
--    "combien de fois utilisé" dans le panneau Administration.
-- ---------------------------------------------------------------------
create table promo_code_redemptions (
  id uuid primary key default gen_random_uuid(),
  promo_code_id uuid not null references promo_codes(id) on delete cascade,
  booking_id uuid not null references bookings(id) on delete cascade,
  customer_user_id uuid references auth.users(id) on delete set null,
  guest_email text,
  discount_cents integer not null,
  created_at timestamptz not null default now(),
  unique (booking_id)
);
create index idx_promo_redemptions_code on promo_code_redemptions (promo_code_id);
create index idx_promo_redemptions_customer on promo_code_redemptions (customer_user_id);
create index idx_promo_redemptions_guest_email on promo_code_redemptions (lower(guest_email));

alter table promo_code_redemptions enable row level security;
-- Écrite uniquement par create_booking()/create_guest_or_quote_booking()
-- (SECURITY DEFINER, propriétaire de la table donc hors RLS) : aucune
-- policy d'écriture cliente, même principe que audit_logs (0001_init.sql).
create policy "promo_code_redemptions: admin read" on promo_code_redemptions
  for select using (is_admin());

-- Vue de confort pour le panneau Administration : un code + son nombre
-- d'utilisations, en une seule lecture. security_invoker fait respecter les
-- policies RLS des deux tables sous-jacentes avec les droits de l'appelant
-- réel (donc toujours réservée à is_admin(), jamais une fuite pour anon/
-- authenticated) plutôt que les droits du propriétaire de la vue.
create view promo_codes_admin
  with (security_invoker = true) as
  select
    p.*,
    coalesce(r.used_count, 0) as used_count
  from promo_codes p
  left join (
    select promo_code_id, count(*) as used_count
    from promo_code_redemptions
    group by promo_code_id
  ) r on r.promo_code_id = p.id
  order by p.created_at desc;
grant select on promo_codes_admin to authenticated;

-- ---------------------------------------------------------------------
-- 3. bookings — traçabilité du code appliqué (discount_cents existe déjà)
-- ---------------------------------------------------------------------
alter table bookings add column promo_code_id uuid references promo_codes(id) on delete set null;
alter table bookings add column promo_code text;

-- Même protection que les autres colonnes financières (0001/0007/0012) :
-- un client ne peut jamais s'attribuer ou modifier une réduction via un
-- UPDATE direct — seule la logique serveur de create_booking()/
-- create_guest_or_quote_booking() (SECURITY DEFINER) les écrit à la création,
-- plus jamais modifiables ensuite (aucun parcours ne permet de changer le
-- code promo d'une réservation déjà créée, y compris pour l'admin).
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
  -- promo_code_id / promo_code : jamais modifiables par personne après
  -- création, admin y compris (un code appliqué à la création reste une
  -- trace historique fixe, comme service_price_cents) — pas de branche
  -- is_admin() ici, contrairement aux colonnes ci-dessus.
  new.promo_code_id := old.promo_code_id;
  new.promo_code := old.promo_code;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Calcul du rabais — plafonné à l'élément ciblé, jamais au total
-- ---------------------------------------------------------------------
create or replace function compute_promo_discount(
  p_promo promo_codes,
  p_service_price_cents integer,
  p_travel_fee_cents integer
)
returns integer
language sql
immutable
set search_path = public
as $$
  select case p_promo.applies_to
    when 'TRAVEL_FEE' then least(
      greatest(p_travel_fee_cents, 0),
      case when p_promo.discount_type = 'PERCENT'
        then round(p_travel_fee_cents * p_promo.discount_value / 100.0)::integer
        else p_promo.discount_value::integer end
    )
    when 'SERVICE_PRICE' then least(
      greatest(p_service_price_cents, 0),
      case when p_promo.discount_type = 'PERCENT'
        then round(p_service_price_cents * p_promo.discount_value / 100.0)::integer
        else p_promo.discount_value::integer end
    )
    else least(
      greatest(p_service_price_cents + p_travel_fee_cents, 0),
      case when p_promo.discount_type = 'PERCENT'
        then round((p_service_price_cents + p_travel_fee_cents) * p_promo.discount_value / 100.0)::integer
        else p_promo.discount_value::integer end
    )
  end;
$$;
revoke execute on function compute_promo_discount(promo_codes, integer, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Validation + verrouillage — utilisée UNIQUEMENT à l'intérieur de
--    create_booking()/create_guest_or_quote_booking() (jamais exposée
--    directement : elle ne fait aucune vérification de rôle elle-même,
--    ses appelants sont déjà SECURITY DEFINER et maîtrisent v_customer_user_id/
--    guest_email). pg_advisory_xact_lock sérialise les appels concurrents
--    sur le MÊME code (empêche deux réservations quasi simultanées de
--    dépasser ensemble max_uses).
-- ---------------------------------------------------------------------
create or replace function validate_promo_code(
  p_code text,
  p_customer_user_id uuid,
  p_guest_email text,
  p_service_price_cents integer,
  p_travel_fee_cents integer
)
returns table(valid boolean, promo_id uuid, promo_code_out text, discount_cents integer, reason text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_promo promo_codes%rowtype;
  v_norm_code text := upper(trim(coalesce(p_code, '')));
  v_norm_email text := lower(trim(coalesce(p_guest_email, '')));
  v_used_total integer;
  v_used_by_customer integer;
  v_has_prior_booking boolean;
  v_discount integer;
begin
  if v_norm_code = '' then
    return query select false, null::uuid, null::text, 0, 'empty'::text;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext('promo:' || v_norm_code));

  select * into v_promo from promo_codes where upper(trim(code)) = v_norm_code;
  if not found or not v_promo.is_active
     or (v_promo.starts_at is not null and v_promo.starts_at > now())
     or (v_promo.ends_at is not null and v_promo.ends_at < now()) then
    return query select false, null::uuid, null::text, 0, 'invalid'::text;
    return;
  end if;

  if v_promo.max_uses is not null then
    select count(*) into v_used_total from promo_code_redemptions where promo_code_id = v_promo.id;
    if v_used_total >= v_promo.max_uses then
      return query select false, v_promo.id, v_promo.code, 0, 'exhausted'::text;
      return;
    end if;
  end if;

  if v_promo.max_uses_per_customer is not null then
    select count(*) into v_used_by_customer from promo_code_redemptions
      where promo_code_id = v_promo.id
        and ((p_customer_user_id is not null and customer_user_id = p_customer_user_id)
             or (p_customer_user_id is null and v_norm_email <> '' and lower(guest_email) = v_norm_email));
    if v_used_by_customer >= v_promo.max_uses_per_customer then
      return query select false, v_promo.id, v_promo.code, 0, 'already_used'::text;
      return;
    end if;
  end if;

  if v_promo.eligibility_rule = 'NEW_CUSTOMER' then
    if p_customer_user_id is null then
      return query select false, v_promo.id, v_promo.code, 0, 'not_eligible'::text;
      return;
    end if;
    select exists(select 1 from bookings where customer_user_id = p_customer_user_id) into v_has_prior_booking;
    if v_has_prior_booking then
      return query select false, v_promo.id, v_promo.code, 0, 'not_eligible'::text;
      return;
    end if;
  elsif v_promo.eligibility_rule = 'OUTSIDE_FREE_RADIUS' then
    if coalesce(p_travel_fee_cents, 0) <= 0 then
      return query select false, v_promo.id, v_promo.code, 0, 'not_eligible'::text;
      return;
    end if;
  end if;

  v_discount := compute_promo_discount(v_promo, coalesce(p_service_price_cents, 0), coalesce(p_travel_fee_cents, 0));
  return query select true, v_promo.id, v_promo.code, v_discount, 'ok'::text;
end;
$$;
revoke execute on function validate_promo_code(text, uuid, text, integer, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Aperçu — appelable directement par le navigateur (bouton "Appliquer"),
--    jamais une consommation d'utilisation : rejoue exactement la même
--    validation que celle qui sera refaite à l'insertion réelle, sans
--    jamais écrire dans promo_code_redemptions.
-- ---------------------------------------------------------------------
create or replace function preview_promo_code(
  p_code text,
  p_service_price_cents integer default 0,
  p_travel_fee_cents integer default 0,
  p_guest_email text default null
)
returns table(
  valid boolean, promo_id uuid, promo_code_out text, promo_name text,
  discount_type text, discount_value numeric, applies_to text,
  discount_cents integer, reason text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_customer_user_id uuid := null;
  v_result record;
  v_promo promo_codes%rowtype;
begin
  if v_uid is not null then
    select global_role into v_role from profiles where user_id = v_uid;
    if v_role = 'customer' then
      v_customer_user_id := v_uid;
    end if;
  end if;

  select * into v_result from validate_promo_code(
    p_code, v_customer_user_id, p_guest_email, p_service_price_cents, p_travel_fee_cents
  );

  -- discount_type/discount_value/applies_to : nécessaires au frontend pour
  -- recalculer le montant en direct si le prix ou le trajet change ensuite
  -- (ex. adresse resaisie après avoir déjà appliqué le code) — jamais
  -- recalculé côté client seul au moment de la réservation elle-même,
  -- revalidé pour de bon par create_booking()/create_guest_or_quote_booking().
  if v_result.promo_id is not null then
    select * into v_promo from promo_codes where id = v_result.promo_id;
  end if;

  return query select
    v_result.valid, v_result.promo_id, v_result.promo_code_out, v_promo.name,
    v_promo.discount_type, v_promo.discount_value, v_promo.applies_to,
    v_result.discount_cents, v_result.reason;
end;
$$;
revoke execute on function preview_promo_code(text, integer, integer, text) from public;
grant execute on function preview_promo_code(text, integer, integer, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Bandeau d'éligibilité — suggère le meilleur code actif ciblant un
--    élément donné (ex. déplacement), sans jamais lister tous les codes ni
--    exposer max_uses/eligibility_rule au navigateur (uniquement code+nom+
--    type+valeur, ce qu'il faut pour l'affichage). N'exclut que les codes
--    déjà épuisés globalement — une vérification par client précise serait
--    disproportionnée pour un simple message informatif (l'aperçu, lui,
--    revérifie tout au moment réel d'appliquer le code).
-- ---------------------------------------------------------------------
create or replace function best_active_promo(p_applies_to text)
returns table(promo_code_out text, promo_name text, discount_type text, discount_value numeric)
language sql
stable
security definer
set search_path = public
as $$
  select p.code, p.name, p.discount_type, p.discount_value
  from promo_codes p
  where p.is_active
    and p.applies_to = p_applies_to
    and (p.starts_at is null or p.starts_at <= now())
    and (p.ends_at is null or p.ends_at >= now())
    and (
      p.max_uses is null
      or (select count(*) from promo_code_redemptions r where r.promo_code_id = p.id) < p.max_uses
    )
  order by p.discount_value desc, p.created_at asc
  limit 1;
$$;
revoke execute on function best_active_promo(text) from public;
grant execute on function best_active_promo(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. create_booking() / create_guest_or_quote_booking() — recréées avec
--    p_promo_code en dernier paramètre (défaut null, aucun appel existant
--    ne casse). Le rabais est TOUJOURS recalculé et revalidé ici, jamais
--    reçu tel quel du client.
-- ---------------------------------------------------------------------
drop function if exists create_booking(text, date, time, text, uuid, uuid, text, text);

create or replace function create_booking(
  p_service_slug text,
  p_date date,
  p_start_time time,
  p_service_pack_slug text default null,
  p_customer_address_id uuid default null,
  p_equipment_id uuid default null,
  p_notes text default null,
  p_distance_quote text default null,
  p_promo_code text default null
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
  v_promo record;
  v_promo_id uuid := null;
  v_promo_code_final text := null;
  v_discount_cents integer := 0;
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

  if coalesce(trim(p_promo_code), '') <> '' then
    select * into v_promo from validate_promo_code(p_promo_code, v_uid, null, v_price_cents, v_travel.fee_cents);
    if not v_promo.valid then
      raise exception 'Ce code promo n''est pas valide pour cette réservation.';
    end if;
    v_discount_cents := v_promo.discount_cents;
    v_promo_id := v_promo.promo_id;
    v_promo_code_final := v_promo.promo_code_out;
  end if;

  v_total_cents := v_price_cents + v_travel.fee_cents - v_discount_cents;

  v_reference := 'SM-' || to_char(now(), 'YYYY') || '-' ||
    upper(substr(md5(gen_random_uuid()::text), 1, 6));

  begin
    insert into bookings (
      reference, customer_user_id, customer_address_id, equipment_id,
      service_id, service_pack_id, date, start_time, status,
      service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents,
      notes, intervention_lat, intervention_lng, one_way_distance_km,
      included_radius_km, travel_rate_per_km_cents, distance_calculation_status, distance_calculated_at,
      promo_code_id, promo_code
    ) values (
      v_reference, v_uid, p_customer_address_id, p_equipment_id,
      v_service.id, v_service_pack_id, p_date, p_start_time, 'PENDING',
      v_duration_minutes, v_price_cents, v_travel.fee_cents, v_discount_cents, v_total_cents,
      nullif(trim(p_notes), ''),
      case when v_quote.valid then v_quote.lat else null end,
      case when v_quote.valid then v_quote.lng else null end,
      case when v_quote.valid then v_quote.distance_km else null end,
      v_travel.radius_km, v_travel.rate_cents, v_travel.calc_status, now(),
      v_promo_id, v_promo_code_final
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  if v_discount_cents > 0 then
    insert into promo_code_redemptions (promo_code_id, booking_id, customer_user_id, guest_email, discount_cents)
    values (v_promo_id, v_booking_id, v_uid, null, v_discount_cents);
  end if;

  return query select v_booking_id, v_reference, v_total_cents;
end;
$$;

revoke all on function create_booking(text, date, time, text, uuid, uuid, text, text, text) from public;
grant execute on function create_booking(text, date, time, text, uuid, uuid, text, text, text) to authenticated;
revoke execute on function create_booking(text, date, time, text, uuid, uuid, text, text, text) from anon;

drop function if exists create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, text);

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
  p_promo_code text default null
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
  v_promo record;
  v_promo_id uuid := null;
  v_promo_code_final text := null;
  v_discount_cents integer := 0;
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

  if coalesce(trim(p_promo_code), '') <> '' then
    select * into v_promo from validate_promo_code(
      p_promo_code, v_customer_user_id,
      case when v_customer_user_id is null then p_guest_email else null end,
      v_price_cents, v_travel.fee_cents
    );
    if not v_promo.valid then
      raise exception 'Ce code promo n''est pas valide pour cette réservation.';
    end if;
    v_discount_cents := v_promo.discount_cents;
    v_promo_id := v_promo.promo_id;
    v_promo_code_final := v_promo.promo_code_out;
  end if;

  v_total_cents := v_price_cents + v_travel.fee_cents - v_discount_cents;

  v_reference := 'SM-' || to_char(now(), 'YYYY') || '-' ||
    upper(substr(md5(gen_random_uuid()::text), 1, 6));

  begin
    insert into bookings (
      reference, customer_user_id,
      guest_name, guest_email, guest_phone, guest_address,
      service_id, service_pack_id, date, start_time, status,
      service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents,
      notes, intervention_lat, intervention_lng, one_way_distance_km,
      included_radius_km, travel_rate_per_km_cents, distance_calculation_status, distance_calculated_at,
      promo_code_id, promo_code
    ) values (
      v_reference, v_customer_user_id,
      case when v_customer_user_id is null then nullif(trim(p_guest_name), '') end,
      case when v_customer_user_id is null then nullif(trim(p_guest_email), '') end,
      case when v_customer_user_id is null then nullif(trim(p_guest_phone), '') end,
      case when v_customer_user_id is null then nullif(trim(p_guest_address), '') end,
      v_service.id, v_service_pack_id, p_date, p_start_time, 'PENDING',
      v_duration_minutes, v_price_cents, v_travel.fee_cents, v_discount_cents, v_total_cents,
      nullif(trim(p_notes), ''),
      case when v_quote.valid then v_quote.lat else null end,
      case when v_quote.valid then v_quote.lng else null end,
      case when v_quote.valid then v_quote.distance_km else null end,
      v_travel.radius_km, v_travel.rate_cents, v_travel.calc_status, now(),
      v_promo_id, v_promo_code_final
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  if v_discount_cents > 0 then
    insert into promo_code_redemptions (promo_code_id, booking_id, customer_user_id, guest_email, discount_cents)
    values (
      v_promo_id, v_booking_id, v_customer_user_id,
      case when v_customer_user_id is null then lower(trim(p_guest_email)) else null end,
      v_discount_cents
    );
  end if;

  return query select v_booking_id, v_reference, v_total_cents;
end;
$$;

revoke all on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, text, text) from public;
grant execute on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, text, text) to authenticated, anon;

-- ---------------------------------------------------------------------
-- 9. Code de lancement — HAYEVA100
-- ---------------------------------------------------------------------
-- 100% du déplacement, jamais de la prestation (applies_to='TRAVEL_FEE',
-- structurellement plafonné par compute_promo_discount() ci-dessus).
-- eligibility_rule='NONE' : le code lui-même reste un simple coupon,
-- utilisable par quiconque le connaît (jamais annoncé publiquement — voir
-- best_active_promo(), utilisée uniquement pour le bandeau d'éligibilité du
-- parcours de réservation, qui décide lui-même QUAND le suggérer).
-- Idempotent (rejouable sans risque) : upsert sur la forme normalisée du
-- code, exactement l'expression de l'index unique créé plus haut.
insert into promo_codes (code, name, discount_type, discount_value, applies_to, is_active, eligibility_rule)
values ('HAYEVA100', 'Déplacement offert', 'PERCENT', 100, 'TRAVEL_FEE', true, 'NONE')
on conflict ((upper(trim(code)))) do update set
  name = excluded.name,
  discount_type = excluded.discount_type,
  discount_value = excluded.discount_value,
  applies_to = excluded.applies_to,
  is_active = true,
  eligibility_rule = excluded.eligibility_rule,
  updated_at = now();

notify pgrst, 'reload schema';
