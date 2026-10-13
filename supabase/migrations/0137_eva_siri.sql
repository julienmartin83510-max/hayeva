-- EVA — phase 3 : accès « Dis Siri, EVA » (Raccourcis iPhone), en LECTURE SEULE.
--
-- Principe :
--  * L'administrateur crée depuis EVA un « appareil » (son iPhone) : un jeton
--    aléatoire est affiché UNE seule fois ; seule son empreinte SHA-256 est
--    conservée. Le jeton est révocable à tout moment et expire (365 jours max).
--  * L'accès Siri est DÉSACTIVÉ par défaut (réglage eva_settings.siri_enabled).
--  * La fonction serveur eva-siri (Edge Function) appelle eva_siri_run avec la
--    clé de service ; eva_siri_run vérifie le jeton puis exécute la demande
--    AU NOM de l'administrateur qui a créé l'appareil, à travers les mêmes
--    garde-fous qu'EVA (administrateur, EVA et agent activés, limites, journal).
--  * Seules les LECTURES sont permises : aucune action (création, envoi,
--    annulation…) ne peut être déclenchée par la voix hors de l'application.
-- Aucune donnée existante n'est modifiée ou supprimée par cette migration.

alter table public.eva_settings add column if not exists siri_enabled boolean not null default false;

create table if not exists public.eva_devices (
  id uuid primary key default gen_random_uuid(),
  label text not null check (char_length(label) between 2 and 60),
  token_hash text not null unique,
  token_hint text not null,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_used_at timestamptz,
  use_count integer not null default 0,
  minute_start timestamptz,
  minute_count integer not null default 0
);
-- Aucune politique : table accessible uniquement par les fonctions ci-dessous.
alter table public.eva_devices enable row level security;
revoke all on public.eva_devices from anon, authenticated;

-- Lectures autorisées par la voix (liste fermée).
create or replace function public._eva_siri_read_intents()
returns text[] language sql immutable as $$
  select array['agenda', 'brief', 'free_slots', 'conflicts', 'find_client', 'quotes_pending', 'invoices_todo', 'attention', 'finance',
               'client_quotes', 'awaiting', 'capabilities', 'agenda_range', 'stats', 'catalog', 'client_detail', 'maintenance_due', 'invoices_list']
$$;

-- --------------------------------------------------------- administration
create or replace function public.eva_siri_set(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  update eva_settings set siri_enabled = coalesce(p_enabled, false), updated_at = now(), updated_by = auth.uid() where id = 1;
  perform _eva_log(null, 'settings', null, 'settings', jsonb_build_object('siri_enabled', coalesce(p_enabled, false)));
  return jsonb_build_object('ok', true, 'siri_enabled', coalesce(p_enabled, false));
end $$;

create or replace function public.eva_device_create(p_label text, p_days integer default 365)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_token text; v_id uuid; v_exp timestamptz; v_label text := nullif(left(regexp_replace(trim(coalesce(p_label, '')), '\s+', ' ', 'g'), 60), '');
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  if v_label is null or char_length(v_label) < 2 then raise exception 'Nommez l''appareil (ex. : iPhone de Julien).'; end if;
  if coalesce(p_days, 0) not between 1 and 365 then raise exception 'Durée de validité : 1 à 365 jours.'; end if;
  if (select count(*) from eva_devices where revoked_at is null and expires_at > now()) >= 5 then
    raise exception 'Cinq appareils actifs au maximum : révoquez-en un d''abord.';
  end if;
  v_token := 'eva_' || encode(gen_random_bytes(24), 'hex');
  v_exp := now() + make_interval(days => p_days);
  insert into eva_devices (label, token_hash, token_hint, created_by, expires_at)
  values (v_label, encode(digest(v_token, 'sha256'), 'hex'), right(v_token, 4), auth.uid(), v_exp)
  returning id into v_id;
  perform _eva_log(null, 'siri:device_create', null, 'settings', jsonb_build_object('device_id', v_id, 'label', v_label));
  -- Le jeton n'est renvoyé qu'ici, une seule fois ; il n'est stocké nulle part en clair.
  return jsonb_build_object('ok', true, 'device_id', v_id, 'token', v_token, 'expires_at', v_exp);
end $$;

create or replace function public.eva_device_revoke(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  update eva_devices set revoked_at = now() where id = p_id and revoked_at is null;
  if not found then raise exception 'Appareil introuvable ou déjà révoqué.'; end if;
  perform _eva_log(null, 'siri:device_revoke', null, 'settings', jsonb_build_object('device_id', p_id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.eva_devices_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  return jsonb_build_object('siri_enabled', (select siri_enabled from eva_settings where id = 1),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'label', d.label, 'hint', d.token_hint, 'created_at', d.created_at, 'expires_at', d.expires_at,
        'revoked_at', d.revoked_at, 'last_used_at', d.last_used_at, 'use_count', d.use_count,
        'active', d.revoked_at is null and d.expires_at > now()) order by d.created_at desc)
      from eva_devices d), '[]'::jsonb));
end $$;

-- ------------------------------------------------------------ passerelle
-- Appelée UNIQUEMENT par la fonction serveur eva-siri (clé de service).
create or replace function public.eva_siri_run(p_token_hash text, p_intent text, p_args jsonb, p_command text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d eva_devices; v_res jsonb;
begin
  select * into d from eva_devices where token_hash = p_token_hash for update;
  if not found or d.revoked_at is not null or d.expires_at <= now() then raise exception 'APPAREIL_NON_AUTORISE'; end if;
  if not coalesce((select siri_enabled from eva_settings where id = 1), false) then raise exception 'SIRI_DESACTIVE'; end if;
  if not (p_intent = any(_eva_siri_read_intents())) then raise exception 'LECTURE_SEULE'; end if;
  -- Débit propre à l'appareil : 20 demandes par minute.
  if d.minute_start is not null and d.minute_start > now() - interval '1 minute' then
    if d.minute_count >= 20 then raise exception 'TROP_DE_DEMANDES'; end if;
    update eva_devices set minute_count = minute_count + 1, last_used_at = now(), use_count = use_count + 1 where id = d.id;
  else
    update eva_devices set minute_start = now(), minute_count = 1, last_used_at = now(), use_count = use_count + 1 where id = d.id;
  end if;
  -- Identité de l'administrateur qui a créé l'appareil, pour cette transaction
  -- seulement : les garde-fous d'EVA (rôle admin, réglages, limites, journal) s'appliquent.
  perform set_config('request.jwt.claim.sub', d.created_by::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', d.created_by, 'role', 'authenticated')::text, true);
  if p_intent in ('agenda_range', 'stats', 'catalog', 'client_detail', 'maintenance_due', 'invoices_list') then
    v_res := eva_query(p_intent, coalesce(p_args, '{}'::jsonb), 'Siri : ' || coalesce(p_command, ''));
  else
    v_res := eva_run(p_intent, coalesce(p_args, '{}'::jsonb), 'Siri : ' || coalesce(p_command, ''));
  end if;
  return v_res || jsonb_build_object('device', d.label);
end $$;

-- ------------------------------------------------------------------ droits
revoke all on function public._eva_siri_read_intents() from public, anon, authenticated;
revoke all on function public.eva_siri_run(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.eva_siri_run(text, text, jsonb, text) to service_role;
do $$
declare f text;
begin
  foreach f in array array['public.eva_siri_set(boolean)', 'public.eva_device_create(text, integer)', 'public.eva_device_revoke(uuid)', 'public.eva_devices_list()'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

insert into public.eva_tools (key, agent, label, level, status, example, note, sort) values
  ('siri', 'eva', 'Questions par « Dis Siri, EVA » (Raccourcis iPhone)', 1, 'disponible', 'Dis Siri, EVA… qu''est-ce que j''ai demain ?',
   'Lecture seule ; les actions se confirment dans l''application', 70)
on conflict (key) do update set agent = excluded.agent, label = excluded.label, level = excluded.level, status = excluded.status,
  example = excluded.example, note = excluded.note, sort = excluded.sort;
