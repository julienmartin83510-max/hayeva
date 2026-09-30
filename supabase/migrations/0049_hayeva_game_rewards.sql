-- ============================================================
-- Jeu "La Maison HAYEVA" — codes de récompense
-- ============================================================
-- Une seule table, écrite exclusivement côté serveur (Edge Function
-- game-generate-code, service_role) : le jeu lui-même (score, missions,
-- indices) reste une expérience côté navigateur sans valeur réelle, mais
-- le code de récompense a une vraie valeur commerciale — jamais généré ou
-- validé uniquement côté frontend (même principe que les autres tables
-- sensibles du projet : le LLM/le client propose, le serveur décide).
--
-- Anti-abus : client_session_id est UNIQUE — un même navigateur (même
-- sessionStorage, même sessionId que window.sudGetSessionId()) ne peut
-- obtenir qu'un seul code, quel que soit le nombre de rechargements de
-- page ou de parties rejouées.
create table game_reward_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  client_session_id uuid not null unique,
  customer_user_id uuid references auth.users(id) on delete set null,
  status text not null default 'created' check (status in ('created','claimed','redeemed','expired','cancelled')),
  score int,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  redeemed_at timestamptz,
  expires_at timestamptz not null default (now() + interval '90 days'),
  admin_note text
);

create index game_reward_codes_status_idx on game_reward_codes (status, created_at);
create index game_reward_codes_client_session_idx on game_reward_codes (client_session_id);

alter table game_reward_codes enable row level security;

-- Aucun accès direct anonyme/authentifié classique : la génération et la
-- vérification passent par les Edge Functions (service_role, qui contourne
-- RLS). Seul un compte admin peut consulter/gérer directement depuis
-- l'administration HAYEVA (même patron que les autres policies "admin" du
-- projet, sur profiles.global_role).
create policy "game_reward_codes: admin full access"
  on game_reward_codes
  for all
  using (exists (
    select 1 from profiles where profiles.user_id = auth.uid() and profiles.global_role = 'admin'
  ))
  with check (exists (
    select 1 from profiles where profiles.user_id = auth.uid() and profiles.global_role = 'admin'
  ));

-- Élargit la mesure d'audience existante (analytics_events, voir
-- 0019_visitor_analytics.sql, déjà élargie une fois par 0040) pour les
-- événements du jeu — jamais un second système d'analytics.
alter table analytics_events drop constraint if exists analytics_events_event_type_check;
alter table analytics_events add constraint analytics_events_event_type_check check (event_type in (
  'page_view', 'heartbeat', 'booking_started', 'booking_completed',
  'contact_clicked', 'phone_clicked',
  'story_video_opened', 'story_video_started', 'story_video_25', 'story_video_50',
  'story_video_75', 'story_video_completed', 'story_video_closed',
  'story_video_services_clicked', 'story_video_booking_clicked',
  'game_opened', 'game_started', 'game_mission_started', 'game_mission_completed',
  'game_hint_used', 'game_completed', 'reward_parent_gate_opened',
  'reward_code_generated', 'reward_code_redeemed'
));
