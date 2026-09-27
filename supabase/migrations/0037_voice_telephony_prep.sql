-- ============================================================
-- HAYEVA Voice — Phase 3 (préparation) : métadonnées d'appel réel +
-- configuration téléphonie/coupe-circuits.
-- ============================================================
-- Portée additive uniquement. AUCUN fournisseur téléphonique n'est encore
-- branché à ce stade (voir voice_telephony_settings.provider = null tant que
-- l'administrateur n'a pas configuré un vrai compte/numéro) — cette
-- migration prépare uniquement le terrain (schéma + page admin) pour ne pas
-- bloquer la Phase 3 sur du travail qui ne dépend d'aucun secret externe.

-- ------------------------------------------------------------
-- Métadonnées d'un VRAI appel (téléphonie), en plus de ce qui existe déjà
-- pour la simulation (channel, call_state, INFO_COLUMNS...). Toujours
-- nullable : une session de simulateur (channel='simulator') n'utilise
-- jamais ces colonnes.
alter table voice_call_sessions
  add column if not exists direction text check (direction in ('inbound', 'outbound')),
  add column if not exists caller_number text,          -- numéro appelant (E.164) — jamais utilisé seul comme authentification (voir tools.ts)
  add column if not exists called_number text,          -- numéro HAYEVA composé
  add column if not exists provider text,                -- ex. 'telnyx' — quel adaptateur TelephonyProvider a géré cet appel
  add column if not exists external_call_id text,        -- identifiant d'appel côté fournisseur, pour corréler les webhooks
  add column if not exists telephony_status text check (telephony_status in (
    'ringing', 'in_progress', 'completed', 'no_answer', 'busy', 'failed', 'cancelled'
  )),                                                     -- statut TÉLÉPHONIQUE (décroché/raccroché...), distinct de call_state (avancement conversationnel)
  add column if not exists customer_user_id uuid references customer_profiles(user_id) on delete set null, -- rempli seulement si le numéro appelant correspond à un client existant (Phase 4, get_customer)
  add column if not exists booking_id uuid references bookings(id) on delete set null; -- RDV RÉEL créé par ce vrai appel (jamais rempli par le simulateur, qui utilise test_booking_id/voice_test_bookings)

create index if not exists voice_call_sessions_external_call_idx on voice_call_sessions (provider, external_call_id) where external_call_id is not null;
create index if not exists voice_call_sessions_caller_idx on voice_call_sessions (caller_number) where caller_number is not null;

-- ------------------------------------------------------------
-- Configuration téléphonie + coupe-circuits (Admin → HAYEVA Voice →
-- Téléphonie). Même patron singleton que voice_assistant_settings.
-- Tant que provider/phone_number sont null, la page admin affiche
-- "🔴 Non configuré" et AUCUN appel automatisé ne peut être initié — un vrai
-- numéro/fournisseur ne sera renseigné qu'une fois le compte externe créé
-- par l'administrateur (jamais par ce système).
create table voice_telephony_settings (
  id boolean primary key default true,
  constraint voice_telephony_settings_singleton check (id = true),

  provider text check (provider in ('telnyx', 'twilio')),  -- null tant qu'aucun fournisseur n'est configuré
  phone_number text,                                        -- numéro HAYEVA au format E.164, ex. +33...

  -- Coupe-circuits globaux (§"KILL SWITCH") — chacun par défaut à false :
  -- rien ne peut se déclencher automatiquement tant qu'un administrateur ne
  -- l'active pas explicitement, même une fois un fournisseur configuré.
  voice_enabled boolean not null default false,             -- interrupteur général HAYEVA Voice (téléphonie réelle)
  inbound_enabled boolean not null default false,
  outbound_enabled boolean not null default false,          -- "Être rappelé" (Phase 5)
  ai_booking_enabled boolean not null default false,        -- l'IA peut réellement créer/modifier/annuler un RDV en production
  human_transfer_enabled boolean not null default false,
  human_transfer_number text,                                -- numéro vers lequel transférer (§"TRANSFERT HUMAIN")

  -- Limites de dépense (§"LIMITES DE DÉPENSES") — 0/null = pas de limite
  -- explicite fixée ; à définir avant toute activation réelle.
  max_outbound_calls_per_day integer,
  max_call_duration_minutes integer,
  max_callbacks_per_day integer,

  mode text not null default 'test' check (mode in ('test', 'production')), -- bascule explicite, jamais implicite

  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into voice_telephony_settings (id) values (true);

alter table voice_telephony_settings enable row level security;
create policy "voice_telephony_settings: admin read" on voice_telephony_settings
  for select using (is_admin());
create policy "voice_telephony_settings: admin update" on voice_telephony_settings
  for update using (is_admin()) with check (is_admin());
revoke all on table voice_telephony_settings from anon, authenticated;
grant select, update on table voice_telephony_settings to authenticated;

-- ------------------------------------------------------------
-- Demandes de rappel ("Être rappelé par HAYEVA", Phase 5) — table dédiée dès
-- maintenant (remplace le simple événement journalisé côté simulateur pour
-- les VRAIS rappels), avec anti-abus (voir index/contrainte ci-dessous).
create table voice_callback_requests (
  id uuid primary key default gen_random_uuid(),
  phone_number text not null,             -- E.164, normalisé côté serveur avant insertion (jamais tel quel depuis le frontend)
  reason text,
  status text not null default 'pending' check (status in (
    'pending', 'calling', 'answered', 'no_answer', 'busy', 'failed', 'completed', 'cancelled'
  )),
  session_id uuid references voice_call_sessions(id) on delete set null, -- rempli une fois l'appel sortant lancé
  source text not null default 'website' check (source in ('website', 'admin')),
  requested_ip inet,                      -- pour le rate limiting anti-abus (jamais affiché tel quel à un client)
  created_at timestamptz not null default now(),
  called_at timestamptz,
  completed_at timestamptz
);
create index voice_callback_requests_phone_idx on voice_callback_requests (phone_number, created_at desc);
create index voice_callback_requests_status_idx on voice_callback_requests (status, created_at desc);

alter table voice_callback_requests enable row level security;
create policy "voice_callback_requests: admin read" on voice_callback_requests
  for select using (is_admin());
-- L'INSERT public (formulaire "Être rappelé") passera par une Edge Function
-- avec service_role (rate limiting + normalisation serveur, jamais un
-- insert direct depuis le frontend) — donc aucune policy insert pour
-- anon/authenticated ici, exactement comme pour les autres tables sensibles
-- du projet.
revoke all on table voice_callback_requests from anon, authenticated;
grant select on table voice_callback_requests to authenticated;
