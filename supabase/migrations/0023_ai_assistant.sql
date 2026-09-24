-- ============================================================
-- Assistant IA HAYEVA — client (triage) + admin (aide au chiffrage)
-- ============================================================
-- Architecture : le frontend ne parle JAMAIS directement à l'API IA ni à
-- ces tables en écriture — tout passe par les Edge Functions ai-assistant/
-- ai-assistant-pro (service_role), qui appliquent quotas/validation avant
-- d'écrire. Empêche un visiteur de contourner les limites de coût en
-- insérant directement des lignes ai_conversations/ai_messages, et empêche
-- toute lecture de conversation par un visiteur normal.
--
-- IMPORTANT : cette table ne contient JAMAIS de prix — l'assistant ne doit
-- jamais en énoncer (contrainte appliquée dans le prompt système de la
-- fonction ai-assistant, pas ici). Le prix réel vient toujours de
-- window.sudBooking.search() côté client, la même donnée déjà utilisée par
-- le reste du site, jamais dupliquée ni recalculée par le modèle.

-- ------------------------------------------------------------
-- Réglages + coupe-circuit immédiat.
create table ai_settings (
  id boolean primary key default true,
  constraint ai_settings_singleton check (id = true),
  enabled boolean not null default false,
  model_name text not null default 'claude-haiku-4-5-20251001',
  daily_request_cap integer not null default 200,
  max_messages_per_session integer not null default 20,
  max_message_length integer not null default 600,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into ai_settings (id) values (true);

alter table ai_settings enable row level security;
create policy "ai_settings: admin read" on ai_settings
  for select using (is_admin());
create policy "ai_settings: admin update" on ai_settings
  for update using (is_admin()) with check (is_admin());
revoke all on table ai_settings from anon, authenticated;
grant select, update on table ai_settings to authenticated;

-- Vue publique minimale : le bouton flottant doit savoir s'afficher, sans
-- jamais exposer les quotas/le nom du modèle à un visiteur (même principe
-- que travel_settings_public).
create or replace view ai_settings_public as
  select enabled from ai_settings;
grant select on ai_settings_public to anon, authenticated;

-- ------------------------------------------------------------
-- Conversations — session_id anonyme (même concept que analytics_events :
-- UUID généré navigateur, sessionStorage, jamais lié à un compte sauf si le
-- client est déjà connecté).
create table ai_conversations (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null,
  source text not null check (source in ('client','admin_pro')),
  customer_type text check (customer_type in ('particulier','professionnel')),
  customer_user_id uuid references auth.users(id) on delete set null,
  message_count integer not null default 0,
  started_at timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);
create index ai_conversations_session_idx on ai_conversations (session_id, started_at);

alter table ai_conversations enable row level security;
create policy "ai_conversations: admin read" on ai_conversations
  for select using (is_admin());
revoke all on table ai_conversations from anon, authenticated;
grant select on table ai_conversations to authenticated;

-- ------------------------------------------------------------
-- Messages — contenu tronqué à l'écriture par l'Edge Function
-- (max_message_length), jamais de pièce jointe/donnée sensible.
create table ai_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references ai_conversations(id) on delete cascade,
  role text not null check (role in ('user','assistant')),
  content text not null,
  created_at timestamptz not null default now()
);
create index ai_messages_conversation_idx on ai_messages (conversation_id, created_at);

alter table ai_messages enable row level security;
create policy "ai_messages: admin read" on ai_messages
  for select using (is_admin());
revoke all on table ai_messages from anon, authenticated;
grant select on table ai_messages to authenticated;

-- ------------------------------------------------------------
-- Usage quotidien — alimenté uniquement par les Edge Functions
-- (service_role), lu par l'admin pour "conversations aujourd'hui / requêtes
-- / estimation de consommation".
create table ai_usage_daily (
  usage_date date primary key,
  request_count integer not null default 0,
  estimated_input_tokens bigint not null default 0,
  estimated_output_tokens bigint not null default 0
);

alter table ai_usage_daily enable row level security;
create policy "ai_usage_daily: admin read" on ai_usage_daily
  for select using (is_admin());
revoke all on table ai_usage_daily from anon, authenticated;
grant select on table ai_usage_daily to authenticated;
