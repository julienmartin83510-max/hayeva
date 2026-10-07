-- 0123 — Interventions : démarrage sûr et compte rendu figé après validation.
--
-- 1) start_intervention : uniquement un rendez-vous CONFIRMÉ (ou déjà en
--    cours) ; verrou sur la réservation => deux appuis simultanés sur
--    « Commencer » ne créent jamais deux fiches.
-- 2) Une fiche FINALIZED est figée : signatures, observations, points de
--    contrôle et photos ne peuvent plus être modifiés ni supprimés
--    silencieusement (seul le suivi d'envoi d'e-mail évolue encore).

create or replace function public.start_intervention(p_booking_id uuid, p_technician_name text)
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

  select * into v_booking from bookings where id = p_booking_id for update;
  if not found then
    raise exception 'Réservation introuvable.';
  end if;

  select interventions.id into v_existing_id from interventions
    where interventions.booking_id = p_booking_id and interventions.report_status = 'DRAFT'
    order by interventions.created_at desc limit 1;

  if v_existing_id is not null then
    return query select v_existing_id, p_booking_id;
    return;
  end if;

  if v_booking.status not in ('CONFIRMED', 'IN_PROGRESS') then
    raise exception 'Seul un rendez-vous confirmé peut démarrer une intervention.';
  end if;

  perform set_config('app.allow_status_change', 'on', true);
  update bookings set status = 'IN_PROGRESS', updated_at = now() where id = p_booking_id;
  perform set_config('app.allow_status_change', 'off', true);

  insert into interventions (booking_id, technician_name, started_at)
  values (p_booking_id, p_technician_name, now())
  returning interventions.id into v_existing_id;

  return query select v_existing_id, p_booking_id;
end;
$$;

create or replace function public.interventions_freeze_finalized()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    if OLD.report_status = 'FINALIZED' then
      raise exception 'Compte rendu validé : suppression impossible.' using errcode = '42501';
    end if;
    return OLD;
  end if;
  if OLD.report_status = 'FINALIZED'
     and (to_jsonb(NEW) - 'email_status' - 'email_sent_at') is distinct from (to_jsonb(OLD) - 'email_status' - 'email_sent_at') then
    raise exception 'Compte rendu validé : modification impossible (signatures et contenu figés).' using errcode = '42501';
  end if;
  return NEW;
end;
$$;

create or replace trigger trg_interventions_freeze_finalized
  before update or delete on public.interventions
  for each row execute function public.interventions_freeze_finalized();

create or replace function public.intervention_children_freeze()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_iv uuid;
begin
  if TG_TABLE_NAME = 'intervention_items' then
    v_iv := case when TG_OP = 'DELETE' then OLD.intervention_id else NEW.intervention_id end;
  else
    v_iv := case when TG_OP = 'DELETE' then coalesce(OLD.intervention_id, (select intervention_id from intervention_items where id = OLD.intervention_item_id))
                 else coalesce(NEW.intervention_id, (select intervention_id from intervention_items where id = NEW.intervention_item_id)) end;
  end if;
  if exists (select 1 from interventions where id = v_iv and report_status = 'FINALIZED') then
    raise exception 'Compte rendu validé : contenu figé.' using errcode = '42501';
  end if;
  return case when TG_OP = 'DELETE' then OLD else NEW end;
end;
$$;

create or replace trigger trg_intervention_items_freeze
  before insert or update or delete on public.intervention_items
  for each row execute function public.intervention_children_freeze();
create or replace trigger trg_intervention_photos_freeze
  before insert or update or delete on public.intervention_photos
  for each row execute function public.intervention_children_freeze();

revoke execute on function public.interventions_freeze_finalized() from public, anon, authenticated;
revoke execute on function public.intervention_children_freeze() from public, anon, authenticated;
