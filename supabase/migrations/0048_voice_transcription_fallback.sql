-- ============================================================
-- HAYEVA Voice — repli audio pour les navigateurs sans SpeechRecognition
-- (notamment Safari/iOS et tout navigateur iOS, qui utilise le même moteur
-- WebKit imposé par Apple — Chrome iOS compris). Le navigateur enregistre
-- un court extrait audio (MediaRecorder), l'envoie à la nouvelle Edge
-- Function voice-transcribe qui le transcrit côté serveur, puis le texte
-- obtenu repart dans le MÊME moteur conversationnel que le reste de HAYEVA
-- Voice (voice-public-chat, tools.ts, state-machine.ts) — jamais un second
-- assistant, jamais un second système de réservation.
--
-- Coût : contrairement à l'API Realtime d'OpenAI (refusée explicitement
-- par le propriétaire du site pour son coût), une transcription Whisper
-- classique coûte une fraction de centime par requête. Un plafond
-- quotidien dur reste néanmoins en place, même principe que
-- voice_realtime_usage_daily (0038_voice_realtime_browser.sql) : jamais un
-- simple compteur informatif.
-- ============================================================

alter table voice_assistant_settings
  add column if not exists transcription_max_per_day integer not null default 300,
  add column if not exists transcription_max_seconds integer not null default 45;

create table voice_transcription_usage_daily (
  usage_date date primary key,
  request_count integer not null default 0,
  updated_at timestamptz not null default now()
);
alter table voice_transcription_usage_daily enable row level security;
create policy "voice_transcription_usage_daily: admin read" on voice_transcription_usage_daily
  for select using (is_admin());
revoke all on table voice_transcription_usage_daily from anon, authenticated;
grant select on table voice_transcription_usage_daily to authenticated;
