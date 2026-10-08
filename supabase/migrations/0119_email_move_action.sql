-- 0119 — E-mail admin « Nouvelle demande » : action DÉPLACER (en plus de
-- ACCEPTER / REFUSER, 0071). Jeton dédié (hash SHA-256 seul stocké, usage
-- unique, expiration), créneaux libres calculés côté serveur, déplacement
-- atomique (verrou FOR UPDATE + contrainte d'exclusion), idempotent.

create table if not exists public.booking_move_tokens (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.booking_move_tokens enable row level security;
revoke all on public.booking_move_tokens from anon, authenticated;

-- Créneaux libres d'une date pour une réservation donnée : mêmes horaires
-- d'ouverture que le site (lun-ven 8h-13h / 14h-18h, sam 8h-12h), pas de
-- (durée + 15 min), hors autres RDV actifs et hors indisponibilités Apple.
create or replace function public.booking_free_slots(p_booking_id uuid, p_date date)
returns setof time
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.bookings;
  v_dur integer;
  v_step integer;
  v_dow integer := extract(isodow from p_date);
  v_ranges int4range[];
  r int4range;
  t integer;
  v_open date;
  v_mb integer;
  v_ma integer;
  v_now_paris timestamp := now() at time zone 'Europe/Paris';
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or p_date is null then return; end if;
  select opening_date into v_open from public.booking_settings limit 1;
  if p_date < greatest(coalesce(v_open, p_date), v_now_paris::date) then return; end if;
  select coalesce(margin_before_minutes, 0), coalesce(margin_after_minutes, 0) into v_mb, v_ma from public.travel_settings limit 1;
  v_dur := coalesce(b.service_duration_minutes, 60);
  v_step := v_dur + 15;
  if v_dow = 7 then return;
  elsif v_dow = 6 then v_ranges := array[int4range(480, 720)];
  else v_ranges := array[int4range(480, 780), int4range(840, 1080)];
  end if;
  foreach r in array v_ranges loop
    t := lower(r);
    while t + v_dur <= upper(r) loop
      if (p_date + make_interval(mins => t)) > v_now_paris + interval '60 minutes'
         and not exists (
           select 1 from public.bookings o
            where o.id <> b.id and o.date = p_date
              and o.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED')
              and tsrange(o.date + o.start_time, o.date + o.start_time + make_interval(mins => coalesce(o.service_duration_minutes, 60)))
                  && tsrange(p_date + make_interval(mins => t), p_date + make_interval(mins => t + v_dur)))
         and not exists (
           select 1 from public.external_busy_blocks x
             join public.calendar_blocking_sources s on s.id = x.source_id and s.is_blocking
            where tstzrange(x.starts_at, x.ends_at)
                  && tstzrange(((p_date + make_interval(mins => t)) at time zone 'Europe/Paris') - make_interval(mins => coalesce(v_ma, 0)),
                               ((p_date + make_interval(mins => t + v_dur)) at time zone 'Europe/Paris') + make_interval(mins => coalesce(v_mb, 0))))
      then
        return next (time '00:00' + make_interval(mins => t));
      end if;
      t := t + v_step;
    end loop;
  end loop;
end;
$$;
revoke execute on function public.booking_free_slots(uuid, date) from public, anon, authenticated;

-- Déplacement depuis l'e-mail. p_date null => infos ; p_date sans
-- p_execute => créneaux libres ; p_execute => déplacement.
-- Demande en attente : déplacée ET acceptée (e-mail client « confirmé »
-- avec la nouvelle date, événement Apple créé). RDV déjà confirmé :
-- déplacé (e-mail client « déplacé », même événement Apple mis à jour).
create or replace function public.process_booking_email_move(
  p_token_hash text, p_date date default null, p_start_time time default null, p_execute boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tok public.booking_move_tokens;
  b public.bookings;
  v_client text;
  v_service text;
  v_info jsonb;
  v_secret text;
  v_slots jsonb;
begin
  if coalesce(length(p_token_hash), 0) <> 64 then
    return jsonb_build_object('result', 'invalid');
  end if;
  select * into v_tok from public.booking_move_tokens where token_hash = p_token_hash for update;
  if not found then return jsonb_build_object('result', 'invalid'); end if;
  select * into b from public.bookings where id = v_tok.booking_id for update;
  if not found then return jsonb_build_object('result', 'invalid'); end if;

  select coalesce(
           (select nullif(trim(concat_ws(' ', cp.first_name, cp.last_name)), '') from customer_profiles cp where cp.user_id = b.customer_user_id),
           (select pa.legal_name from professional_accounts pa where pa.id = b.professional_account_id),
           nullif(b.guest_name, ''), 'Client') into v_client;
  select name into v_service from services where id = b.service_id;
  v_info := jsonb_build_object('reference', b.reference, 'client', v_client,
    'service', coalesce(v_service, 'Intervention'), 'date', b.date,
    'start_time', to_char(b.start_time, 'HH24:MI'), 'duration', b.service_duration_minutes,
    'status', b.status, 'cancellation_type', b.cancellation_type);

  if v_tok.used_at is not null or b.status not in ('PENDING', 'CONFIRMED') then
    return jsonb_build_object('result', 'already', 'booking', v_info);
  end if;
  if v_tok.expires_at < now() or b.date < (now() at time zone 'Europe/Paris')::date then
    return jsonb_build_object('result', 'expired', 'booking', v_info);
  end if;
  if p_date is null then
    return jsonb_build_object('result', 'ready', 'booking', v_info);
  end if;
  select coalesce(jsonb_agg(to_char(s, 'HH24:MI')), '[]'::jsonb) into v_slots from public.booking_free_slots(b.id, p_date) s;
  if not p_execute then
    return jsonb_build_object('result', 'slots', 'booking', v_info, 'date', p_date, 'slots', v_slots);
  end if;
  if p_start_time is null or not (v_slots ? to_char(p_start_time, 'HH24:MI')) then
    return jsonb_build_object('result', 'slot_taken', 'booking', v_info, 'date', p_date, 'slots', v_slots);
  end if;

  perform set_config('app.allow_status_change', 'on', true);
  begin
    update public.bookings
       set date = p_date, start_time = p_start_time,
           status = case when b.status = 'PENDING' then 'CONFIRMED' else b.status end,
           admin_viewed_at = coalesce(admin_viewed_at, now()), updated_at = now()
     where id = b.id;
  exception when exclusion_violation then
    return jsonb_build_object('result', 'slot_taken', 'booking', v_info, 'date', p_date, 'slots', v_slots);
  end;
  perform set_config('app.allow_status_change', 'off', true);

  update public.booking_move_tokens set used_at = now() where booking_id = b.id and used_at is null;
  update public.booking_action_tokens set used_at = now() where booking_id = b.id and used_at is null;

  if b.status = 'CONFIRMED' then
    begin
      select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
      perform net.http_post(
        url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-booking-change',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
        body := jsonb_build_object('event', 'rescheduled', 'by', 'admin', 'booking_id', b.id,
          'old_date', b.date, 'old_start_time', b.start_time, 'new_date', p_date, 'new_start_time', p_start_time));
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('result', 'done', 'action', 'move',
    'booking', v_info || jsonb_build_object('date', p_date, 'start_time', to_char(p_start_time, 'HH24:MI'), 'status', 'CONFIRMED',
                                            'old_date', b.date, 'old_start_time', to_char(b.start_time, 'HH24:MI'), 'was_pending', b.status = 'PENDING'));
end;
$$;
revoke execute on function public.process_booking_email_move(text, date, time, boolean) from public, anon, authenticated;

-- ACCEPTER / REFUSER : inchangés, sauf que l'acceptation laisse le jeton
-- DÉPLACER utilisable (déplacer un RDV accepté reste possible depuis l'e-mail),
-- et que le nom du compte client prime sur le nom saisi.
create or replace function public.process_booking_email_action(p_token_hash text, p_action text, p_execute boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token booking_action_tokens%rowtype;
  v_booking bookings%rowtype;
  v_client text;
  v_service text;
  v_info jsonb;
begin
  if p_action not in ('confirm', 'refuse') or coalesce(length(p_token_hash), 0) <> 64 then
    return jsonb_build_object('result', 'invalid');
  end if;

  select * into v_token from booking_action_tokens
   where token_hash = p_token_hash and action = p_action
   for update;
  if not found then
    return jsonb_build_object('result', 'invalid');
  end if;

  select * into v_booking from bookings where id = v_token.booking_id for update;
  if not found then
    return jsonb_build_object('result', 'invalid');
  end if;

  select coalesce(
           (select nullif(trim(concat_ws(' ', cp.first_name, cp.last_name)), '') from customer_profiles cp where cp.user_id = v_booking.customer_user_id),
           (select pa.legal_name from professional_accounts pa where pa.id = v_booking.professional_account_id),
           nullif(v_booking.guest_name, ''),
           'Client')
    into v_client;
  select name into v_service from services where id = v_booking.service_id;

  v_info := jsonb_build_object(
    'reference', v_booking.reference,
    'client', v_client,
    'service', coalesce(v_service, 'Intervention'),
    'date', v_booking.date,
    'start_time', to_char(v_booking.start_time, 'HH24:MI'),
    'status', v_booking.status,
    'cancellation_type', v_booking.cancellation_type
  );

  if v_token.used_at is not null or v_booking.status <> 'PENDING' then
    return jsonb_build_object('result', 'already', 'booking', v_info);
  end if;
  if v_token.expires_at < now() or v_booking.date < (now() at time zone 'Europe/Paris')::date then
    return jsonb_build_object('result', 'expired', 'booking', v_info);
  end if;
  if not p_execute then
    return jsonb_build_object('result', 'ready', 'booking', v_info);
  end if;

  perform set_config('app.allow_status_change', 'on', true);
  if p_action = 'confirm' then
    update bookings set status = 'CONFIRMED', admin_viewed_at = coalesce(admin_viewed_at, now()), updated_at = now()
     where id = v_booking.id;
  else
    update bookings
       set status = 'CANCELLED', cancelled_by = 'admin', cancelled_at = now(),
           cancellation_type = 'refused', cancellation_reason_code = 'creneau_indisponible',
           admin_viewed_at = coalesce(admin_viewed_at, now()), updated_at = now()
     where id = v_booking.id;
    update booking_move_tokens set used_at = now() where booking_id = v_booking.id and used_at is null;
  end if;
  perform set_config('app.allow_status_change', 'off', true);

  update booking_action_tokens set used_at = now() where booking_id = v_booking.id and used_at is null;

  return jsonb_build_object('result', 'done', 'action', p_action,
    'booking', v_info || jsonb_build_object('status', case when p_action = 'confirm' then 'CONFIRMED' else 'CANCELLED' end));
end;
$$;
revoke execute on function public.process_booking_email_action(text, text, boolean) from public, anon, authenticated;
