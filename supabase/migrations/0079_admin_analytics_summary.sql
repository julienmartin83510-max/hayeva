-- ============================================================
-- Correctif — tableau de bord Statistiques (Administration) affichait
-- "En ligne maintenant" non nul mais "Visiteurs/Pages vues aujourd'hui" à
-- zéro, alors que de vraies données existaient pour aujourd'hui.
-- ============================================================
-- CAUSE RÉELLE (confirmée en inspectant la configuration PostgREST du
-- projet : max_rows = 1000) : admLoadStats() (frontend) récupérait les
-- lignes BRUTES des 30 derniers jours de analytics_events via un simple
-- .select(...).gte('created_at', ...) SANS .order() ni pagination. Avec
-- plus de 1000 lignes réellement présentes sur 30 jours (usage réel +
-- tests de cette phase de développement), PostgREST tronque silencieusement
-- la réponse à 1000 lignes, sans garantie sur lesquelles — celles
-- d'aujourd'hui pouvaient donc être entièrement absentes du lot renvoyé,
-- alors que "En ligne maintenant" (admStatsCountOnline) utilise une
-- requête séparée, minuscule (fenêtre de 2 minutes), jamais concernée par
-- cette troncature — d'où l'incohérence observée.
--
-- CORRECTIF : les agrégats (visiteurs/pages vues/7j/30j/graphique/
-- entonnoir/pages populaires) sont désormais calculés côté serveur par
-- cette fonction — count(distinct ...) sur TOUTE la table sans jamais
-- rapatrier les lignes brutes vers le navigateur, donc plus jamais soumis
-- à la limite max_rows. Les bornes de journée utilisent explicitement
-- "at time zone 'Europe/Paris'" (jamais l'horloge locale du navigateur de
-- l'admin, qui n'est pas garantie être réglée sur Paris).
--
-- Aucune donnée supprimée ni réinitialisée : les 2500+ lignes déjà
-- enregistrées dans analytics_events restent intactes et sont maintenant
-- correctement comptées par cette fonction (vérifié : les événements
-- d'aujourd'hui existent réellement en base, ils n'avaient jamais été
-- perdus — seulement jamais affichés, bug purement côté lecture).
create or replace function admin_analytics_summary(p_period text default 'today')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  period_start timestamptz;
  week_start timestamptz;
  month_start timestamptz;
  result jsonb;
begin
  if not is_admin() then
    raise exception 'Réservé à l''administration.';
  end if;
  if p_period not in ('today', '7d', '30d') then
    p_period := 'today';
  end if;

  week_start := (date_trunc('day', now() at time zone 'Europe/Paris') - interval '6 days') at time zone 'Europe/Paris';
  month_start := (date_trunc('day', now() at time zone 'Europe/Paris') - interval '29 days') at time zone 'Europe/Paris';
  period_start := case p_period
    when '7d' then week_start
    when '30d' then month_start
    else (date_trunc('day', now() at time zone 'Europe/Paris')) at time zone 'Europe/Paris'
  end;

  select jsonb_build_object(
    'period', p_period,
    'period_start', period_start,
    'visitors', (select count(distinct session_id) from analytics_events where event_type = 'page_view' and created_at >= period_start),
    'pageviews', (select count(*) from analytics_events where event_type = 'page_view' and created_at >= period_start),
    'visitors_7d', (select count(distinct session_id) from analytics_events where event_type = 'page_view' and created_at >= week_start),
    'visitors_30d', (select count(distinct session_id) from analytics_events where event_type = 'page_view' and created_at >= month_start),
    'booking_started', (select count(distinct session_id) from analytics_events where event_type = 'booking_started' and created_at >= period_start),
    'booking_completed', (select count(distinct session_id) from analytics_events where event_type = 'booking_completed' and created_at >= period_start),
    'contact_clicked', (select count(*) from analytics_events where event_type = 'contact_clicked' and created_at >= period_start),
    'phone_clicked', (select count(*) from analytics_events where event_type = 'phone_clicked' and created_at >= period_start),
    'top_pages', (
      select coalesce(jsonb_agg(jsonb_build_object('page', page, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (
        select page, count(*) as cnt from analytics_events
        where event_type = 'page_view' and created_at >= period_start and page is not null
        group by page order by count(*) desc limit 8
      ) t
    ),
    'daily_7d', (
      select jsonb_agg(jsonb_build_object(
        'date', to_char(d, 'YYYY-MM-DD'),
        'visitors', (
          select count(distinct session_id) from analytics_events
          where event_type = 'page_view'
            and created_at >= (d at time zone 'Europe/Paris')
            and created_at < ((d + interval '1 day') at time zone 'Europe/Paris')
        )
      ) order by d)
      from generate_series(
        date_trunc('day', now() at time zone 'Europe/Paris') - interval '6 days',
        date_trunc('day', now() at time zone 'Europe/Paris'),
        interval '1 day'
      ) d
    )
  ) into result;

  return result;
end;
$$;

revoke all on function admin_analytics_summary(text) from public;
grant execute on function admin_analytics_summary(text) to authenticated;
revoke execute on function admin_analytics_summary(text) from anon;

-- Index composite utile aux agrégations ci-dessus (event_type + created_at
-- existait déjà via analytics_events_type_created_idx, 0019) — ajout d'un
-- index couvrant également session_id pour accélérer count(distinct...)
-- sans scan complet à chaque appel.
create index if not exists analytics_events_type_created_session_idx
  on analytics_events (event_type, created_at, session_id);
