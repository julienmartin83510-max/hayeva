-- 0127 — Sources de campagne (QR codes, liens imprimés).
--
-- Une visite arrivée par https://hayeva.fr/?src=<code> est enregistrée dans
-- la mesure d'audience interne existante (analytics_events, déjà ouverte en
-- insertion anonyme pour event_type='page_view') avec page='src:<code>'.
-- Aucun nouveau droit, aucune donnée personnelle, aucun service tiers.
--
-- admin_analytics_summary() :
--   * exclut ces lignes techniques des pages vues et des pages populaires ;
--   * ajoute 'campaigns' : visiteurs uniques et réservations créées par
--     source sur la période (même session anonyme).

create or replace function public.admin_analytics_summary(p_period text default 'today')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
    'pageviews', (select count(*) from analytics_events where event_type = 'page_view' and created_at >= period_start and coalesce(page, '') not like 'src:%'),
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
        where event_type = 'page_view' and created_at >= period_start and page is not null and page not like 'src:%'
        group by page order by count(*) desc limit 8
      ) t
    ),
    'campaigns', (
      select coalesce(jsonb_agg(jsonb_build_object('source', src, 'visitors', visitors, 'bookings', bookings) order by visitors desc), '[]'::jsonb)
      from (
        select substr(c.page, 5) as src,
               count(distinct c.session_id) as visitors,
               count(distinct b.session_id) as bookings
        from analytics_events c
        left join analytics_events b
          on b.session_id = c.session_id and b.event_type = 'booking_completed' and b.created_at >= c.created_at
        where c.event_type = 'page_view' and c.page like 'src:%' and c.created_at >= period_start
        group by 1
        order by 2 desc
        limit 30
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
$function$;
