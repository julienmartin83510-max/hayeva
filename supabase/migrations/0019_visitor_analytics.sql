-- ============================================================
-- Statistiques de fréquentation — mesure d'audience interne, anonyme
-- ============================================================
-- Une seule table, un seul mécanisme (pas de Realtime Presence, jamais
-- utilisé sur ce projet — réutilise le pattern Realtime postgres_changes
-- déjà en place pour le planning admin). Aucune donnée personnelle :
-- session_id est un UUID généré aléatoirement dans le navigateur, stocké en
-- sessionStorage (jamais localStorage, jamais lié à un compte), jamais
-- accompagné d'une adresse IP ou d'un identifiant de compte.
--
-- "En ligne maintenant" = distinct session_id ayant émis N'IMPORTE QUEL
-- événement (y compris 'heartbeat') dans les 2 dernières minutes — pas de
-- table séparée, juste une requête sur celle-ci.
create table analytics_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check (event_type in (
    'page_view', 'heartbeat', 'booking_started', 'booking_completed',
    'contact_clicked', 'phone_clicked'
  )),
  session_id uuid not null,
  page text,
  created_at timestamptz not null default now()
);

create index analytics_events_type_created_idx on analytics_events (event_type, created_at);
create index analytics_events_session_created_idx on analytics_events (session_id, created_at);

alter table analytics_events enable row level security;

-- Écriture seule pour tout visiteur (anonyme ou connecté) — jamais de
-- lecture, jamais de modification, jamais de suppression pour ces rôles.
create policy "analytics_events: anyone can insert" on analytics_events
  for insert
  with check (
    event_type in ('page_view','heartbeat','booking_started','booking_completed','contact_clicked','phone_clicked')
    and session_id is not null
  );

-- Lecture réservée à l'administrateur — même fonction is_admin() déjà
-- utilisée dans tout le projet, déjà testée en direct (tentative
-- d'élévation de privilège bloquée) lors de cette session.
create policy "analytics_events: admin read" on analytics_events
  for select
  using (is_admin());

revoke all on table analytics_events from anon, authenticated;
grant insert on table analytics_events to anon, authenticated;
grant select on table analytics_events to authenticated;

-- ------------------------------------------------------------
-- Anti-spam léger : un visiteur (ou un bot/script) ne peut pas noyer la
-- table en insérant en boucle. SECURITY DEFINER nécessaire ici : anon n'a
-- aucun droit SELECT sur cette table (voir plus haut), donc un trigger en
-- SECURITY INVOKER (par défaut) échouerait sur le "select count(*)"
-- ci-dessous avec une erreur de permission — le trigger doit pouvoir lire
-- au-delà des droits de l'appelant, comme toute autre fonction SECURITY
-- DEFINER de ce projet. Ligne simplement ignorée (return null) au-delà du
-- seuil : jamais d'erreur renvoyée au navigateur, cohérent avec l'envoi
-- "fire-and-forget" déjà utilisé côté frontend. Seuil volontairement large
-- (20 événements/minute) : un usage normal (un heartbeat/minute + quelques
-- clics) n'approche jamais cette limite.
create or replace function analytics_events_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recent_count integer;
begin
  select count(*) into v_recent_count
  from analytics_events
  where session_id = NEW.session_id
    and created_at > now() - interval '60 seconds';
  if v_recent_count >= 20 then
    return null;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_analytics_events_rate_limit on analytics_events;
create trigger trg_analytics_events_rate_limit
  before insert on analytics_events
  for each row execute function analytics_events_rate_limit();

-- ------------------------------------------------------------
-- Realtime : sans cet enregistrement dans la publication, l'abonnement
-- postgres_changes de l'onglet admin Statistiques (admLoadStats(), canal
-- 'admin-stats-changes') ne se déclencherait jamais — même bug déjà
-- rencontré et corrigé pour la table bookings (voir
-- 0015_bookings_realtime.sql), corrigé ici directement plutôt que de
-- laisser le même piège se reproduire. Idempotent, sans risque à rejouer.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'analytics_events'
  ) then
    alter publication supabase_realtime add table analytics_events;
  end if;
end $$;

-- Purge manuelle/planifiée (pas de cron automatique configuré ici — cette
-- instance Supabase n'a pas été vérifiée comme disposant de pg_cron) :
-- 13 mois, plafond recommandé par la CNIL pour les outils de mesure
-- d'audience exemptés de consentement.
create or replace function cleanup_old_analytics_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (is_admin() or auth.role() = 'service_role') then
    raise exception 'Réservé à l''administrateur.';
  end if;
  delete from analytics_events where created_at < now() - interval '13 months';
end;
$$;
revoke all on function cleanup_old_analytics_events() from public;
grant execute on function cleanup_old_analytics_events() to authenticated;
