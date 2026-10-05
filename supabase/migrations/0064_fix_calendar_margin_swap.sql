-- Correction : dans check_calendar_block_conflict(), margin_before_minutes et
-- margin_after_minutes étaient appliqués de façon inversée lors de
-- l'extension du créneau candidat, ce qui annulait la marge "après" un
-- événement bloquant et appliquait à la place la marge "avant" au mauvais
-- endroit. Mis en évidence par un test fonctionnel réel (créneau démarrant
-- juste après la fin d'un blocage + marge après de 30 min, qui n'était pas
-- bloqué alors qu'il aurait dû l'être).
create or replace function public.check_calendar_block_conflict(p_date date, p_start_time time without time zone, p_duration_minutes integer)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_margin_before integer;
  v_margin_after integer;
  v_slot_start timestamptz;
  v_slot_end timestamptz;
  v_conflict boolean;
begin
  perform pg_advisory_xact_lock(hashtext('hayeva_calendar_block_' || p_date::text));

  select coalesce(margin_before_minutes, 0), coalesce(margin_after_minutes, 0)
    into v_margin_before, v_margin_after
    from travel_settings limit 1;

  v_slot_start := (p_date + p_start_time) - make_interval(mins => coalesce(v_margin_after, 0));
  v_slot_end := (p_date + p_start_time) + make_interval(mins => p_duration_minutes) + make_interval(mins => coalesce(v_margin_before, 0));

  select exists (
    select 1
    from external_busy_blocks b
    join calendar_blocking_sources s on s.id = b.source_id
    where s.is_blocking = true
      and tstzrange(b.starts_at, b.ends_at) && tstzrange(v_slot_start, v_slot_end)
  ) into v_conflict;

  if v_conflict then
    raise exception 'Ce créneau est indisponible (agenda synchronisé). Choisissez un autre horaire.';
  end if;
end;
$function$;
