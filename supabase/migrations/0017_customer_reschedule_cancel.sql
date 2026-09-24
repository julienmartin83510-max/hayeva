-- ============================================================
-- Le client déplace ou annule lui-même son rendez-vous (Espace Client)
-- ============================================================
-- Portée additive : 2 nouvelles colonnes sur bookings, une échappatoire
-- contrôlée dans le trigger de verrouillage existant, 2 nouvelles fonctions
-- RPC SECURITY DEFINER (même patron que create_booking()/
-- create_guest_or_quote_booking()). Rien de ce qui existe déjà n'est
-- modifié dans son comportement pour un appelant admin ou service_role.

alter table bookings
  add column if not exists cancelled_by text check (cancelled_by in ('customer', 'admin')),
  add column if not exists cancelled_at timestamptz;

comment on column bookings.cancelled_by is 'Qui a fait passer cette réservation à CANCELLED — ''customer'' via cancel_own_booking(), ''admin'' laissé à null pour l''instant (annulation depuis l''admin déjà existante, non rétroactive). Colonne purement informative, jamais utilisée par la contrainte d''exclusion ni les filtres existants (qui continuent de ne regarder que status).';
comment on column bookings.cancelled_at is 'Horodatage de l''annulation, posé uniquement par cancel_own_booking().';

-- ------------------------------------------------------------
-- Échappatoire contrôlée pour le verrou de statut
-- ------------------------------------------------------------
-- protect_booking_financial_fields() (0012_admin_requests_and_push.sql)
-- verrouille déjà `status` pour tout appelant non-admin/non-service_role —
-- un client ne peut donc pas passer sa propre réservation à CANCELLED par
-- un simple .update(). On ajoute UNE SEULE échappatoire : un drapeau de
-- transaction (current_setting/set_config) que seule notre fonction
-- cancel_own_booking() peut positionner avant son UPDATE — un client ne
-- peut pas positionner ce drapeau depuis PostgREST (il ne peut exécuter que
-- les fonctions/requêtes explicitement exposées, jamais du SQL arbitraire),
-- donc le verrou reste entier pour tout .update() direct venant du client.
-- Tout le reste de la fonction (montants, distance, admin_viewed_at...)
-- est inchangé — recopié tel quel.
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
    if coalesce(current_setting('app.allow_status_change', true), '') <> 'on' then
      new.status := old.status;
    end if;
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

-- ------------------------------------------------------------
-- Horaires d'ouverture — copie SQL de hoursForDate()/slotsForDate()
-- (sudmaintenance.html) pour ne jamais faire confiance au créneau envoyé
-- par le client : Lun-Ven 8h-13h puis 14h-18h, Sam 8h-12h, Dim fermé.
-- ------------------------------------------------------------
create or replace function is_slot_within_business_hours(p_date date, p_start_time time, p_duration_minutes integer)
returns boolean
language sql
immutable
set search_path = public
as $$
  select case extract(dow from p_date)::int
    when 0 then false
    when 6 then p_start_time >= time '08:00' and (p_start_time + (p_duration_minutes * interval '1 minute')) <= time '12:00'
    else (
      (p_start_time >= time '08:00' and (p_start_time + (p_duration_minutes * interval '1 minute')) <= time '13:00')
      or (p_start_time >= time '14:00' and (p_start_time + (p_duration_minutes * interval '1 minute')) <= time '18:00')
    )
  end;
$$;
revoke all on function is_slot_within_business_hours(date, time, integer) from public;
grant execute on function is_slot_within_business_hours(date, time, integer) to authenticated, anon;

-- ------------------------------------------------------------
-- reschedule_own_booking() : déplace une réservation dont le client
-- connecté est propriétaire.
-- ------------------------------------------------------------
create or replace function reschedule_own_booking(
  p_booking_id uuid,
  p_date date,
  p_start_time time
)
returns table(booking_id uuid, reference text, date date, start_time time)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking bookings%rowtype;
  v_secret text;
begin
  if v_uid is null then
    raise exception 'Authentification requise.';
  end if;

  -- La requête WHERE fait à la fois l'authentification et l'autorisation :
  -- si la réservation n'existe pas OU n'appartient pas à v_uid, "not found"
  -- ci-dessous est strictement identique dans les deux cas — jamais de fuite
  -- d'existence sur la réservation d'un autre client.
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

  begin
    update bookings
    set date = p_date, start_time = p_start_time, updated_at = now()
    where id = p_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  -- Notification admin + client (best-effort, asynchrone via pg_net — un
  -- souci de notification ne doit jamais faire échouer le déplacement déjà
  -- enregistré). Même mécanisme (Vault + pg_net) que les triggers de
  -- notification existants (0008_webhook_secret_vault.sql).
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
      -- Ne bloque jamais le déplacement pour un souci de notification.
      null;
  end;

  return query select p_booking_id, v_booking.reference, p_date, p_start_time;
end;
$$;

revoke all on function reschedule_own_booking(uuid, date, time) from public;
grant execute on function reschedule_own_booking(uuid, date, time) to authenticated;
revoke execute on function reschedule_own_booking(uuid, date, time) from anon;

-- ------------------------------------------------------------
-- cancel_own_booking() : annule une réservation dont le client connecté
-- est propriétaire. Le statut passe à CANCELLED (même valeur que
-- l'annulation admin — jamais un nouveau statut, voir cancelled_by pour
-- distinguer qui a annulé) : déclenche automatiquement l'e-mail client
-- déjà existant (notify_customer_status_change) et libère le créneau
-- (la contrainte d'exclusion ne bloque que PENDING/CONFIRMED/IN_PROGRESS/
-- COMPLETED).
-- ------------------------------------------------------------
create or replace function cancel_own_booking(p_booking_id uuid)
returns table(booking_id uuid, reference text)
language plpgsql
security definer
set search_path = public
as $$
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
    raise exception 'Ce rendez-vous ne peut plus être annulé.';
  end if;

  perform set_config('app.allow_status_change', 'on', true);
  update bookings
  set status = 'CANCELLED', cancelled_by = 'customer', cancelled_at = now(), updated_at = now()
  where id = p_booking_id;

  begin
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-booking-change',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
      body := jsonb_build_object(
        'event', 'cancelled_by_customer',
        'booking_id', p_booking_id,
        'date', v_booking.date,
        'start_time', v_booking.start_time
      )
    );
  exception
    when others then
      null;
  end;

  return query select p_booking_id, v_booking.reference;
end;
$$;

revoke all on function cancel_own_booking(uuid) from public;
grant execute on function cancel_own_booking(uuid) to authenticated;
revoke execute on function cancel_own_booking(uuid) from anon;
