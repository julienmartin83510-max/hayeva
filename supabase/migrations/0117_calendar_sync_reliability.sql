-- 0117 — Fiabilisation de la synchronisation HAYEVA -> Apple Calendar.
-- Étend le système existant (calendar-sync + pg_net), sans en créer un second :
--  * re-synchronise sur TOUTE modification utile (date, heure, durée,
--    prestation, adresse, client, notes), pas seulement date/heure ;
--  * supprime l'événement quand le RDV quitte un statut actif (annulé,
--    absent, remis en attente) ou est supprimé de la base ;
--  * statut PENDING posé avant l'appel : si pg_net échoue, le cron de
--    reprise (action pull -> retryFailedPushes) relance automatiquement ;
--  * RPC admin de resynchronisation manuelle.
-- Une réservation = un UID déterministe hayeva-<id> => jamais de doublon.

create or replace function public.calendar_sync_action(p_old public.bookings, p_new public.bookings)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_new_active boolean := p_new.status in ('CONFIRMED', 'IN_PROGRESS', 'COMPLETED');
  v_old_active boolean := p_old.status in ('CONFIRMED', 'IN_PROGRESS', 'COMPLETED');
begin
  if v_new_active then
    if not v_old_active then return 'upsert'; end if;
    if p_new.date is distinct from p_old.date
      or p_new.start_time is distinct from p_old.start_time
      or p_new.service_duration_minutes is distinct from p_old.service_duration_minutes
      or p_new.service_id is distinct from p_old.service_id
      or p_new.service_pack_id is distinct from p_old.service_pack_id
      or p_new.customer_address_id is distinct from p_old.customer_address_id
      or p_new.guest_address is distinct from p_old.guest_address
      or p_new.guest_name is distinct from p_old.guest_name
      or p_new.guest_phone is distinct from p_old.guest_phone
      or p_new.guest_email is distinct from p_old.guest_email
      or p_new.client_id is distinct from p_old.client_id
      or p_new.customer_user_id is distinct from p_old.customer_user_id
      or p_new.notes is distinct from p_old.notes then
      return 'upsert';
    end if;
    return null;
  end if;
  if v_old_active and p_old.calendar_event_uid is not null then
    return 'delete';
  end if;
  return null;
end;
$$;

-- Appel serveur unique vers calendar-sync (secret lu dans le Vault).
create or replace function public.calendar_sync_post(p_action text, p_booking_id uuid, p_uid text default null)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
  v_id bigint;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
  select net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/calendar-sync',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
    body := jsonb_strip_nulls(jsonb_build_object('action', p_action, 'booking_id', p_booking_id, 'uid', p_uid))
  ) into v_id;
  return v_id;
end;
$$;
revoke all on function public.calendar_sync_post(text, uuid, text) from public, anon, authenticated;

-- BEFORE : marque PENDING (s'exécute après les gardes, ordre alphabétique).
create or replace function public.bookings_calendar_mark_pending()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    if NEW.status in ('CONFIRMED', 'IN_PROGRESS', 'COMPLETED') then
      NEW.calendar_sync_status := 'PENDING';
      NEW.calendar_sync_error := null;
    end if;
  elsif public.calendar_sync_action(OLD, NEW) is not null then
    NEW.calendar_sync_status := 'PENDING';
    NEW.calendar_sync_error := null;
  end if;
  return NEW;
end;
$$;

create or replace trigger trg_zz_calendar_pending
  before insert or update on public.bookings
  for each row execute function public.bookings_calendar_mark_pending();

-- AFTER UPDATE : dispatch (remplace l'ancienne logique date/heure seulement).
create or replace function public.sync_booking_to_calendar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text := public.calendar_sync_action(OLD, NEW);
begin
  if v_action is null then return NEW; end if;
  begin
    perform public.calendar_sync_post(v_action, NEW.id, case when v_action = 'delete' then OLD.calendar_event_uid end);
  exception when others then
    null; -- reste PENDING : reprise automatique par le cron
  end;
  return NEW;
end;
$$;

-- AFTER INSERT : inchangé fonctionnellement (statuts actifs + email client).
create or replace function public.sync_booking_to_calendar_on_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  if NEW.status not in ('CONFIRMED', 'IN_PROGRESS', 'COMPLETED') then
    return NEW;
  end if;
  begin
    perform public.calendar_sync_post('upsert', NEW.id);
  exception when others then null;
  end;
  if NEW.status = 'CONFIRMED' then
    begin
      select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
      perform net.http_post(
        url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-customer-status-change',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
        body := jsonb_build_object('type', 'UPDATE', 'table', 'bookings', 'record', to_jsonb(NEW))
      );
    exception when others then null;
    end;
  end if;
  return NEW;
end;
$$;

-- AFTER DELETE : l'événement associé est supprimé (UID transmis, la ligne
-- n'existant plus).
create or replace function public.sync_booking_delete_to_calendar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.calendar_event_uid is not null then
    begin
      perform public.calendar_sync_post('delete', OLD.id, OLD.calendar_event_uid);
    exception when others then null;
    end;
  end if;
  return OLD;
end;
$$;

create or replace trigger trg_sync_booking_to_calendar_delete
  after delete on public.bookings
  for each row execute function public.sync_booking_delete_to_calendar();

-- Resynchronisation manuelle (admin uniquement).
create or replace function public.admin_resync_booking_calendar(p_booking_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.bookings;
  v_action text;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into b from public.bookings where id = p_booking_id;
  if not found then raise exception 'booking_not_found'; end if;
  if b.status in ('CONFIRMED', 'IN_PROGRESS', 'COMPLETED') then
    v_action := 'upsert';
  elsif b.calendar_event_uid is not null then
    v_action := 'delete';
  else
    update public.bookings set calendar_sync_status = 'NOT_SYNCED', calendar_sync_error = null where id = p_booking_id;
    return 'nothing_to_sync';
  end if;
  update public.bookings set calendar_sync_status = 'PENDING', calendar_sync_error = null where id = p_booking_id;
  perform public.calendar_sync_post(v_action, p_booking_id, case when v_action = 'delete' then b.calendar_event_uid end);
  return v_action;
end;
$$;
revoke all on function public.admin_resync_booking_calendar(uuid) from public, anon;
grant execute on function public.admin_resync_booking_calendar(uuid) to authenticated;
