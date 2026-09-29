-- ============================================================
-- Fiche d'intervention HAYEVA — compte rendu, checklist enrichie, photos,
-- signatures, déplacement admin d'un rendez-vous, statut "en intervention".
-- ============================================================
-- Réutilise entièrement le modèle déjà en place (0001_init.sql) :
-- interventions / intervention_items / intervention_photos / customer_equipment
-- existaient déjà (posés en Phase A, jamais branchés côté admin jusqu'ici).
-- Cette migration est PUREMENT ADDITIVE : aucune colonne existante modifiée
-- de façon destructive, aucune ligne supprimée, aucun statut retiré.
--
-- bookings.status contient déjà IN_PROGRESS et NO_SHOW depuis 0001_init.sql
-- (jamais exposés dans ADMIN_STATUS_OPTIONS côté frontend jusqu'ici) : c'est
-- le statut "EN INTERVENTION" demandé, pas besoin d'en inventer un nouveau.

-- ------------------------------------------------------------
-- interventions : cycle de vie complet (brouillon -> finalisé), équipement
-- concerné, observations/recommandations, signatures, statut d'envoi email.
-- ------------------------------------------------------------
alter table interventions
  add column if not exists equipment_id uuid references customer_equipment(id) on delete set null,
  add column if not exists report_status text not null default 'DRAFT'
    check (report_status in ('DRAFT', 'FINALIZED')),
  add column if not exists report_number text unique,
  add column if not exists started_at timestamptz,
  add column if not exists ended_at timestamptz,
  add column if not exists observations text,
  add column if not exists recommendations text,
  add column if not exists client_signature_name text,
  add column if not exists client_signature_data text,
  add column if not exists client_signed_at timestamptz,
  add column if not exists technician_signature_name text,
  add column if not exists technician_signature_data text,
  add column if not exists technician_signed_at timestamptz,
  add column if not exists email_status text not null default 'NOT_SENT'
    check (email_status in ('NOT_SENT', 'PENDING', 'SENT', 'FAILED')),
  add column if not exists email_sent_at timestamptz;

comment on column interventions.report_status is 'DRAFT tant que la fiche est en cours de remplissage (autosave) ; FINALIZED une fois les deux signatures posées et la fiche validée — jamais réécrite en DRAFT ensuite (une correction ultérieure doit créer une nouvelle intervention/addenda, pas rouvrir celle-ci).';
comment on column interventions.email_status is 'Suivi indépendant de report_status : un échec d''envoi ne doit jamais faire perdre ni annuler le compte rendu déjà enregistré. SENT/FAILED posés par send-intervention-report une fois la fiche FINALIZED.';

create index if not exists idx_interventions_equipment on interventions(equipment_id);
create index if not exists idx_interventions_report_status on interventions(report_status);

-- ------------------------------------------------------------
-- intervention_items : checklist adaptable. status élargi avec 'OK' et
-- 'NOT_APPLICABLE' (les 3 valeurs existantes FUNCTIONAL/WATCH/
-- INTERVENTION_RECOMMENDED restent utilisées telles quelles par le compte
-- rendu particulier déjà affiché côté Espace Client — jamais retirées).
-- measured_value : valeur mesurée optionnelle (ex. "12°C", "3.2 bar").
-- ------------------------------------------------------------
alter table intervention_items drop constraint if exists intervention_items_status_check;
alter table intervention_items add constraint intervention_items_status_check
  check (status in ('OK', 'FUNCTIONAL', 'WATCH', 'INTERVENTION_RECOMMENDED', 'ANOMALY', 'NOT_APPLICABLE'));
alter table intervention_items add column if not exists measured_value text;
alter table intervention_items add column if not exists sort_order integer not null default 0;

-- intervention_photos : tag optionnel (avant/pendant/après/anomalie/équipement).
alter table intervention_photos add column if not exists tag text
  check (tag in ('AVANT', 'PENDANT', 'APRES', 'ANOMALIE', 'EQUIPEMENT'));
alter table intervention_photos add column if not exists file_name text;

-- ------------------------------------------------------------
-- Bucket Storage privé pour les photos d'intervention — même patron que
-- 'quote-attachments' (0026_quote_options_attachments.sql) : jamais public,
-- accès uniquement via les policies storage.objects ci-dessous.
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('intervention-photos', 'intervention-photos', false, 8388608, array[
  'image/jpeg', 'image/png', 'image/webp'
])
on conflict (id) do update set
  public = false,
  file_size_limit = 8388608,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

create policy "intervention-photos: admin full access" on storage.objects
  for all using (bucket_id = 'intervention-photos' and is_admin())
  with check (bucket_id = 'intervention-photos' and is_admin());

create policy "intervention-photos: owner customer read" on storage.objects
  for select using (
    bucket_id = 'intervention-photos'
    and exists (
      select 1 from intervention_photos ip
      join intervention_items ii on ii.id = ip.intervention_item_id
      join interventions i on i.id = ii.intervention_id
      join bookings b on b.id = i.booking_id
      where ip.storage_path = storage.objects.name
        and ii.visibility = 'customer_visible'
        and b.customer_user_id = auth.uid()
    )
  );

-- ------------------------------------------------------------
-- admin_reschedule_booking() : un admin déplace une réservation.
-- Le déplacement du côté client (reschedule_own_booking, 0017) fait déjà une
-- UPDATE en place sur la même ligne (jamais de doublon) — même patron ici,
-- avec is_admin() au lieu de la vérification de propriété, et sans la
-- fenêtre "1h à l'avance" (un admin peut légitimement replanifier un
-- rendez-vous du jour même en dernière minute). L'ancienne date/heure n'est
-- jamais recréée en base : seule cette ligne change, donc l'ancien créneau
-- disparaît immédiatement de tout écran filtrant sur bookings.date/start_time.
-- ------------------------------------------------------------
create or replace function admin_reschedule_booking(
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
$$;

revoke all on function admin_reschedule_booking(uuid, date, time) from public;
grant execute on function admin_reschedule_booking(uuid, date, time) to authenticated;
revoke execute on function admin_reschedule_booking(uuid, date, time) from anon;

-- ------------------------------------------------------------
-- start_intervention() : bascule un rendez-vous en IN_PROGRESS et crée (ou
-- réutilise) la ligne interventions DRAFT correspondante — jamais deux
-- interventions DRAFT actives pour le même booking (idempotent : rappeler
-- cette fonction sur un booking déjà IN_PROGRESS renvoie l'intervention
-- existante au lieu d'en recréer une, ce qui protège contre un double-clic).
-- ------------------------------------------------------------
create or replace function start_intervention(p_booking_id uuid, p_technician_name text)
returns table(intervention_id uuid, booking_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking bookings%rowtype;
  v_existing_id uuid;
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;

  select * into v_booking from bookings where id = p_booking_id;
  if not found then
    raise exception 'Réservation introuvable.';
  end if;

  select id into v_existing_id from interventions
    where booking_id = p_booking_id and report_status = 'DRAFT'
    order by created_at desc limit 1;

  if v_existing_id is not null then
    return query select v_existing_id, p_booking_id;
    return;
  end if;

  if v_booking.status not in ('CONFIRMED', 'PENDING') then
    raise exception 'Ce rendez-vous ne peut pas démarrer une intervention dans son état actuel.';
  end if;

  perform set_config('app.allow_status_change', 'on', true);
  update bookings set status = 'IN_PROGRESS', updated_at = now() where id = p_booking_id;

  insert into interventions (booking_id, technician_name, started_at)
  values (p_booking_id, p_technician_name, now())
  returning id into v_existing_id;

  return query select v_existing_id, p_booking_id;
end;
$$;

revoke all on function start_intervention(uuid, text) from public;
grant execute on function start_intervention(uuid, text) to authenticated;
revoke execute on function start_intervention(uuid, text) from anon;

-- ------------------------------------------------------------
-- finalize_intervention() : valide définitivement la fiche (signatures déjà
-- enregistrées par l'appelant via update() classique, protégé par la policy
-- "pro or admin full access" existante) et termine le rendez-vous. Ordre
-- volontaire : la ligne interventions doit déjà porter report_status=
-- 'FINALIZED' par un update() préalable de l'appelant avant que cette
-- fonction ne touche au booking — jamais l'inverse, pour ne jamais marquer
-- un rendez-vous COMPLETED si l'enregistrement de la fiche a échoué avant.
-- ------------------------------------------------------------
create or replace function finalize_intervention_booking(p_booking_id uuid)
returns table(booking_id uuid, status text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;

  perform set_config('app.allow_status_change', 'on', true);
  update bookings set status = 'COMPLETED', updated_at = now() where id = p_booking_id;

  return query select p_booking_id, 'COMPLETED'::text;
end;
$$;

revoke all on function finalize_intervention_booking(uuid) from public;
grant execute on function finalize_intervention_booking(uuid) to authenticated;
revoke execute on function finalize_intervention_booking(uuid) from anon;
