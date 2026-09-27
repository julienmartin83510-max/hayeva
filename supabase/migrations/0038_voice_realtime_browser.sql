-- ============================================================
-- HAYEVA Voice — assistant vocal temps réel intégré au site (WebRTC),
-- nouvelle priorité : accessible à TOUT visiteur du site public, sans
-- appeler un numéro de téléphone. Réutilise au maximum le schéma existant
-- (voice_call_sessions/voice_call_events, voice_assistant_settings) plutôt
-- que de dupliquer une nouvelle famille de tables.
-- ============================================================

-- ------------------------------------------------------------
-- Un visiteur public n'est pas forcément authentifié (created_by restera
-- alors null) : on corrèle plutôt son identifiant de session navigateur
-- (window.sudGetSessionId(), déjà utilisé par ai_conversations) — jamais une
-- vraie identité, uniquement pour le rate limiting et pour retrouver "sa"
-- session en cas de reconnexion.
alter table voice_call_sessions
  add column if not exists client_session_id text;
create index if not exists voice_call_sessions_client_session_idx on voice_call_sessions (client_session_id) where client_session_id is not null;

-- 'realtime_browser' : nouveau canal, distinct de 'simulator' (admin,
-- toujours TEST) et de 'phone' (réservé, non utilisé tant qu'aucun
-- fournisseur téléphonique n'est branché). Une session realtime_browser
-- n'est PAS is_test — c'est un vrai visiteur du site — mais elle n'écrit
-- jamais dans `bookings` non plus (voir guide_to_booking dans tools.ts : le
-- client termine sa réservation lui-même dans le vrai tunnel du site).
alter table voice_call_sessions drop constraint if exists voice_call_sessions_channel_check;
alter table voice_call_sessions add constraint voice_call_sessions_channel_check
  check (channel in ('simulator', 'phone', 'realtime_browser'));

-- ------------------------------------------------------------
-- Réglages du canal realtime navigateur — colonnes ajoutées à la table de
-- réglages existante (même moteur "HAYEVA Voice", un fournisseur LLM
-- différent : OpenAI Realtime plutôt qu'OpenRouter, car c'est le seul à
-- proposer aujourd'hui une vraie session WebRTC temps réel navigateur).
-- realtime_enabled reste à false tant qu'aucune clé OPENAI_API_KEY n'est
-- configurée côté serveur — jamais activé par erreur.
alter table voice_assistant_settings
  add column if not exists realtime_enabled boolean not null default false,
  add column if not exists realtime_model text not null default 'gpt-realtime-mini',
  add column if not exists realtime_voice text not null default 'alloy',
  add column if not exists realtime_max_messages_per_session integer not null default 30,
  add column if not exists realtime_max_sessions_per_day integer not null default 100;

-- ------------------------------------------------------------
-- Suivi d'usage quotidien — chaque session réelle a un coût (OpenAI
-- facture à la minute), donc un plafond dur par jour est indispensable
-- pour éviter une facture accidentelle (même principe que ai_usage_daily,
-- 0023_ai_assistant.sql), jamais un simple compteur informatif.
create table voice_realtime_usage_daily (
  usage_date date primary key,
  session_count integer not null default 0,
  tool_call_count integer not null default 0,
  updated_at timestamptz not null default now()
);
alter table voice_realtime_usage_daily enable row level security;
create policy "voice_realtime_usage_daily: admin read" on voice_realtime_usage_daily
  for select using (is_admin());
revoke all on table voice_realtime_usage_daily from anon, authenticated;
grant select on table voice_realtime_usage_daily to authenticated;
