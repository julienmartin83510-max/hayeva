-- Corrections issues de la mise en service réelle Apple Calendar.
--
-- 1) check_calendar_block_conflict() : (p_date + p_start_time) est un
--    timestamp SANS fuseau ; converti en timestamptz il était interprété
--    dans le fuseau de la session Postgres (UTC), alors que les horaires
--    HAYEVA sont en heure de Paris. Résultat : un événement Apple de 10:00
--    à 11:00 (Paris) bloquait 11:00-12:00 l'hiver / 12:00-13:00 l'été.
--    Le créneau est désormais explicitement interprété en Europe/Paris.
-- 2) admin_calendar_sync_status() : renvoie la date de dernière
--    synchronisation et n'affiche plus que les erreurs POSTÉRIEURES au
--    dernier succès (une vieille erreur "connexion_non_configuree" ne doit
--    jamais faire croire qu'une connexion qui fonctionne est en erreur).
-- 3) Nom du calendrier dédié : "HAYEVA".

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

  -- Voir 0064 pour l'ordre des marges (marge "après" un événement bloquant
  -- = recul du début du créneau candidat, et inversement).
  v_slot_start := ((p_date + p_start_time) at time zone 'Europe/Paris') - make_interval(mins => coalesce(v_margin_after, 0));
  v_slot_end := ((p_date + p_start_time) at time zone 'Europe/Paris') + make_interval(mins => p_duration_minutes) + make_interval(mins => coalesce(v_margin_before, 0));

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
revoke all on function public.check_calendar_block_conflict(date, time, integer) from public, anon, authenticated;

alter table calendar_connections alter column target_calendar_display_name set default 'HAYEVA';

create or replace function admin_calendar_sync_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_connection record;
  v_sources jsonb;
  v_recent_errors jsonb;
  v_last_ok timestamptz;
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;

  select * into v_connection from calendar_connections order by created_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'display_name', s.display_name, 'is_blocking', s.is_blocking
  ) order by s.display_name), '[]'::jsonb)
  into v_sources
  from calendar_blocking_sources s
  where s.connection_id = v_connection.id;

  select max(created_at) into v_last_ok from calendar_sync_log where status = 'ok';

  select coalesce(jsonb_agg(jsonb_build_object(
    'direction', l.direction, 'status', l.status, 'detail', l.detail, 'created_at', l.created_at
  ) order by l.created_at desc), '[]'::jsonb)
  into v_recent_errors
  from (
    select * from calendar_sync_log
    where status = 'error' and (v_last_ok is null or created_at > v_last_ok)
    order by created_at desc limit 10
  ) l;

  return jsonb_build_object(
    'connected', coalesce(v_connection.connected, false),
    'apple_id_email', v_connection.apple_id_email,
    'target_calendar_display_name', coalesce(v_connection.target_calendar_display_name, 'HAYEVA'),
    'last_push_sync_at', v_connection.last_push_sync_at,
    'last_pull_sync_at', v_connection.last_pull_sync_at,
    'last_sync_at', greatest(v_connection.last_push_sync_at, v_connection.last_pull_sync_at),
    'last_sync_error', v_connection.last_sync_error,
    'sources', v_sources,
    'blocking_count', (select count(*) from jsonb_array_elements(v_sources) e where (e->>'is_blocking')::boolean),
    'recent_errors', v_recent_errors,
    'margin_before_minutes', (select margin_before_minutes from travel_settings limit 1),
    'margin_after_minutes', (select margin_after_minutes from travel_settings limit 1)
  );
end;
$$;
revoke all on function admin_calendar_sync_status() from public, anon, authenticated;
grant execute on function admin_calendar_sync_status() to authenticated;
