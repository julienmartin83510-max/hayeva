-- ============================================================
-- create_guest_or_quote_booking() — réservation directe en base pour les
-- cas que create_booking() ne couvre pas : réservation invitée (pas de
-- compte), compte connecté non-particulier consultant le formulaire
-- public, ou prestation sur devis (QUOTE_REQUEST). Remplace une tentative
-- d'insert direct côté client dans bookings, qui échoue systématiquement
-- avec "new row violates row-level security policy for table bookings"
-- malgré une policy d'insert ("bookings: create own or guest", 0001_init.sql)
-- qui autorise pourtant explicitement ce cas sur le papier — même anomalie
-- RLS déjà rencontrée et contournée sur ce projet pour
-- create_professional_account() et audit_logs (cause exacte non identifiée,
-- cf. commentaire de create_professional_account() dans 0001_init.sql).
-- Cette fonction SECURITY DEFINER contourne le problème comme les autres,
-- tout en revalidant elle-même chaque condition que la policy RLS
-- contournée était censée garantir (jamais de confiance aveugle dans les
-- paramètres reçus du client).
create or replace function create_guest_or_quote_booking(
  p_service_slug text,
  p_date date,
  p_start_time time,
  p_service_pack_slug text default null,
  p_notes text default null,
  p_guest_name text default null,
  p_guest_email text default null,
  p_guest_phone text default null,
  p_guest_address text default null
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
      -- déjà rempli côté client avec une mention explicite "sur devis").
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

  v_reference := 'SM-' || to_char(now(), 'YYYY') || '-' ||
    upper(substr(md5(gen_random_uuid()::text), 1, 6));

  begin
    insert into bookings (
      reference, customer_user_id,
      guest_name, guest_email, guest_phone, guest_address,
      service_id, service_pack_id, date, start_time, status,
      service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents,
      notes
    ) values (
      v_reference, v_customer_user_id,
      case when v_customer_user_id is null then nullif(trim(p_guest_name), '') end,
      case when v_customer_user_id is null then nullif(trim(p_guest_email), '') end,
      case when v_customer_user_id is null then nullif(trim(p_guest_phone), '') end,
      case when v_customer_user_id is null then nullif(trim(p_guest_address), '') end,
      v_service.id, v_service_pack_id, p_date, p_start_time, 'PENDING',
      v_duration_minutes, v_price_cents, 0, 0, v_price_cents,
      nullif(trim(p_notes), '')
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  return query select v_booking_id, v_reference, v_price_cents;
end;
$$;

revoke all on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text) from public;
-- Contrairement à create_booking()/create_professional_account() (réservées
-- à authenticated), celle-ci doit aussi être appelable par un visiteur non
-- connecté (réservation invitée) : anon en a donc explicitement besoin.
grant execute on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text) to authenticated, anon;
