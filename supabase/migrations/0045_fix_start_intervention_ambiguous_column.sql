-- Correctif : start_intervention() (0044_intervention_reports.sql) échouait
-- systématiquement avec "column reference booking_id is ambiguous" — le nom
-- de colonne OUT "booking_id" de la fonction entrait en conflit avec
-- interventions.booking_id dans la clause WHERE de la requête de recherche
-- d'un brouillon existant. Repéré en testant réellement la fonction sur un
-- vrai rendez-vous avant de considérer ce module terminé.
-- Correctif : qualifie la colonne de table (interventions.booking_id) au
-- lieu du nom nu — comportement inchangé, juste la référence désambiguïsée.

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

  select interventions.id into v_existing_id from interventions
    where interventions.booking_id = p_booking_id and interventions.report_status = 'DRAFT'
    order by interventions.created_at desc limit 1;

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
  returning interventions.id into v_existing_id;

  return query select v_existing_id, p_booking_id;
end;
$$;
