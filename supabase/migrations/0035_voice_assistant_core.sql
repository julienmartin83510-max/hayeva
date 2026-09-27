-- ============================================================
-- HAYEVA Voice — Phase 1 : cœur du moteur en simulation (admin uniquement)
-- ============================================================
-- Portée additive uniquement — rien de ce qui existe déjà (bookings,
-- services, réservation, RLS) n'est modifié. Cette migration prépare
-- uniquement le terrain pour le simulateur "HAYEVA Voice" de l'Espace
-- Administrateur : aucun appel téléphonique réel, aucun fournisseur externe
-- branché à ce stade (Phases 2+ pour cela).
--
-- SÉCURITÉ / ISOLATION TEST : voice_test_bookings est une table
-- ENTIÈREMENT SÉPARÉE de bookings — le simulateur n'écrit jamais dans la
-- table de production, ne participe jamais à la contrainte d'exclusion de
-- créneaux réelle (bookings_no_overlapping_slots), et ne peut donc jamais
-- "consommer" un vrai créneau ni entrer en conflit avec une vraie
-- réservation. C'est la garantie demandée : "aucune action ne doit
-- accidentellement modifier les rendez-vous de production".
--
-- Toutes les tables : lecture admin uniquement (is_admin()), écriture
-- réservée à service_role (Edge Function voice-assistant-simulate) — même
-- patron que ai_conversations/ai_messages (0023_ai_assistant.sql).

-- ------------------------------------------------------------
-- Réglages — même patron singleton que ai_settings.
create table voice_assistant_settings (
  id boolean primary key default true,
  constraint voice_assistant_settings_singleton check (id = true),
  enabled boolean not null default true,          -- active/désactive le simulateur lui-même
  model_name text not null default 'openai/gpt-4o-mini',
  max_messages_per_session integer not null default 40,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into voice_assistant_settings (id) values (true);

alter table voice_assistant_settings enable row level security;
create policy "voice_assistant_settings: admin read" on voice_assistant_settings
  for select using (is_admin());
create policy "voice_assistant_settings: admin update" on voice_assistant_settings
  for update using (is_admin()) with check (is_admin());
revoke all on table voice_assistant_settings from anon, authenticated;
grant select, update on table voice_assistant_settings to authenticated;

-- ------------------------------------------------------------
-- Sessions d'appel (simulées en Phase 1 ; channel='phone' réservé aux
-- phases suivantes, jamais utilisé avant qu'un vrai fournisseur télécom
-- soit branché). call_state porte la machine d'état — TOUJOURS positionnée
-- côté serveur (Edge Function), jamais directement par le modèle : voir le
-- commentaire dans voice-assistant-simulate/index.ts.
create table voice_call_sessions (
  id uuid primary key default gen_random_uuid(),
  is_test boolean not null default true,
  channel text not null default 'simulator' check (channel in ('simulator', 'phone')),
  call_state text not null default 'greeting' check (call_state in (
    'incoming', 'greeting', 'identify_need', 'collect_information',
    'check_availability', 'propose_slots', 'confirmation', 'create_booking',
    'completed', 'human_transfer', 'callback_required', 'failed', 'cancelled'
  )),
  customer_type text check (customer_type in ('particulier', 'professionnel')),
  service_category text check (service_category in ('plomberie', 'chauffage', 'climatisation', 'autre')),
  test_booking_id uuid,   -- rempli une fois create_booking() exécuté avec succès (voir voice_test_bookings)
  summary text,           -- résumé généré en fin d'appel (préparé pour Phase 7, rempli dès que possible)
  message_count integer not null default 0,
  created_by uuid references auth.users(id) on delete set null,  -- admin qui a lancé la simulation
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  updated_at timestamptz not null default now()
);
create index voice_call_sessions_created_idx on voice_call_sessions (started_at desc);

alter table voice_call_sessions enable row level security;
create policy "voice_call_sessions: admin read" on voice_call_sessions
  for select using (is_admin());
revoke all on table voice_call_sessions from anon, authenticated;
grant select on table voice_call_sessions to authenticated;

-- ------------------------------------------------------------
-- Journal d'événements d'une session : messages ET actions/outils déclenchés
-- ET changements d'état, dans l'ordre chronologique (une seule table à lire
-- pour reconstituer tout l'écran du simulateur). tool_args/tool_result ne
-- doivent JAMAIS contenir de secret : les outils serveur ne renvoient que
-- des données métier (créneaux, référence de réservation...), jamais une
-- clé — garanti par le code de voice-assistant-simulate, pas par la table.
create table voice_call_events (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references voice_call_sessions(id) on delete cascade,
  seq integer not null,
  type text not null check (type in ('user', 'assistant', 'tool_call', 'tool_result', 'state_change', 'system')),
  content text,           -- texte du message (user/assistant) ou note lisible (system)
  tool_name text,         -- ex. 'get_available_slots', 'create_booking'
  tool_args jsonb,        -- arguments validés envoyés à l'outil (jamais de secret)
  tool_result jsonb,      -- résultat renvoyé par l'outil (jamais de secret)
  state text,             -- nouvel état, uniquement pour type='state_change'
  created_at timestamptz not null default now(),
  unique (session_id, seq)
);
create index voice_call_events_session_idx on voice_call_events (session_id, seq);

alter table voice_call_events enable row level security;
create policy "voice_call_events: admin read" on voice_call_events
  for select using (is_admin());
revoke all on table voice_call_events from anon, authenticated;
grant select on table voice_call_events to authenticated;

-- ------------------------------------------------------------
-- Réservations de TEST créées par le simulateur — jamais dans `bookings`.
-- Champs texte libres (jamais de FK vers customer_addresses/customer_profiles) :
-- une simulation ne doit jamais pouvoir lire ni rattacher de vraie fiche
-- client, uniquement ce que "le client simulé" a dit dans la conversation.
create table voice_test_bookings (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references voice_call_sessions(id) on delete cascade,
  reference text not null unique,   -- ex. TEST-VOICE-XXXXX, jamais confondue avec une vraie réf. (SM-2026-XXXX)
  service_id uuid references services(id),          -- lecture seule du catalogue réel, jamais modifié
  service_pack_id uuid references service_packs(id),
  customer_type text check (customer_type in ('particulier', 'professionnel')),
  customer_name text,
  customer_phone text,
  customer_address text,
  date date not null,
  start_time time not null,
  duration_minutes integer not null,
  status text not null default 'CONFIRMED' check (status in ('CONFIRMED', 'CANCELLED')),
  notes text,
  created_at timestamptz not null default now(),
  cancelled_at timestamptz
);
create index voice_test_bookings_session_idx on voice_test_bookings (session_id);

alter table voice_test_bookings enable row level security;
create policy "voice_test_bookings: admin read" on voice_test_bookings
  for select using (is_admin());
revoke all on table voice_test_bookings from anon, authenticated;
grant select on table voice_test_bookings to authenticated;

-- ------------------------------------------------------------
-- get_available_slots_for_service() — LECTURE SEULE de vraies données
-- (services actifs + vraies réservations bookings pour exclure les
-- créneaux déjà pris), aucune écriture. Réutilisable telle quelle par le
-- futur flux d'appel réel (Phase 3+), pas seulement par le simulateur —
-- c'est la même logique métier que hoursForDate()/slotsForDate()
-- (index.html) et la même définition d'horaires que
-- is_slot_within_business_hours() (0017_customer_reschedule_cancel.sql),
-- jamais une troisième version des horaires HAYEVA.
--
-- SECURITY DEFINER + search_path fixe, comme les autres fonctions du
-- projet ; accès restreint à authenticated (simulateur admin) — pas anon,
-- pas encore de canal public tant qu'aucun vrai appel n'existe (Phase 3+
-- décidera si un accès élargi est nécessaire).
create or replace function get_available_slots_for_service(
  p_service_slug text,
  p_date date,
  p_max_slots integer default 5
)
returns table(start_time time, end_time time)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_service services%rowtype;
  v_duration integer;
  v_step interval;
  v_ranges time[][];
  v_dow int;
  v_range_start time;
  v_range_end time;
  v_cursor time;
  v_count integer := 0;
  v_now_floor timestamptz;
begin
  select * into v_service from services where slug = p_service_slug and is_active;
  if not found then
    return;
  end if;
  v_duration := coalesce(v_service.duration_minutes, 60);

  -- Avant l'ouverture officielle HAYEVA (01/11/2026) ou un dimanche : aucun
  -- créneau, mêmes règles que le reste du site (enforce_hayeva_opening_date,
  -- hoursForDate côté frontend).
  if p_date < date '2026-11-01' then
    return;
  end if;
  v_dow := extract(dow from p_date)::int;
  if v_dow = 0 then
    return;
  end if;

  if v_dow = 6 then
    v_ranges := array[array['08:00'::time, '12:00'::time]];
  else
    v_ranges := array[array['08:00'::time, '13:00'::time], array['14:00'::time, '18:00'::time]];
  end if;

  -- Même battement de 15 min entre deux interventions que côté frontend
  -- (blockedDurationMinutes/MINIMUM_BUFFER_MIN, index.html).
  v_step := ((v_duration + 15) || ' minutes')::interval;
  v_now_floor := now() + interval '60 minutes';

  for i in 1..array_length(v_ranges, 1) loop
    v_range_start := v_ranges[i][1];
    v_range_end := v_ranges[i][2];
    v_cursor := v_range_start;
    while v_cursor + (v_duration || ' minutes')::interval <= v_range_end and v_count < p_max_slots loop
      -- Aujourd'hui : jamais un créneau à moins d'1h (même règle que
      -- reschedule_own_booking()).
      if p_date > current_date or (p_date + v_cursor) >= v_now_floor then
        -- Exclusion des créneaux déjà pris par une VRAIE réservation active
        -- (mêmes statuts bloquants que bookings_no_overlapping_slots).
        if not exists (
          select 1 from bookings b
          where b.date = p_date
            and b.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED')
            and tsrange(b.date + b.start_time, b.date + b.start_time + (b.service_duration_minutes || ' minutes')::interval)
                && tsrange(p_date + v_cursor, p_date + v_cursor + (v_duration || ' minutes')::interval)
        ) then
          start_time := v_cursor;
          end_time := v_cursor + (v_duration || ' minutes')::interval;
          v_count := v_count + 1;
          return next;
        end if;
      end if;
      v_cursor := v_cursor + v_step;
    end loop;
  end loop;
end;
$$;

revoke all on function get_available_slots_for_service(text, date, integer) from public;
grant execute on function get_available_slots_for_service(text, date, integer) to authenticated;
revoke execute on function get_available_slots_for_service(text, date, integer) from anon;
