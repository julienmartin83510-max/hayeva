-- EVA — Siri prépare des actions, l'iPhone confirme ; réauthentification pour les actions sensibles.
--
-- 1) Réauthentification : les actions sensibles (envoi de documents, rendez-vous,
--    argent, réglages) exigent une connexion RÉCENTE (10 min par défaut). La
--    preuve est l'horodatage de connexion contenu dans le jeton de session
--    Supabase (« amr »), vérifié ici, côté serveur : un jeton ancien ou un appel
--    venant de Siri (sans connexion) est refusé avec REAUTH_REQUISE. Sur
--    l'iPhone, la saisie du mot de passe peut être remplie par le trousseau
--    iCloud après Face ID (fonction d'iOS, non contrôlée par HAYEVA).
-- 2) Siri peut PRÉPARER des propositions (jamais les confirmer) si l'appareil y
--    est autorisé (scope « propose ») : fiche client, devis et facture en
--    brouillon, confirmation ou déplacement de rendez-vous. La confirmation se
--    fait dans EVA, avec la réauthentification si l'action est sensible.
-- Extensible : la liste des actions sensibles et celle des actions préparables
-- par Siri sont des réglages (eva_settings), pas du code figé.
-- Aucune donnée existante n'est modifiée ou supprimée.

alter table public.eva_settings
  add column if not exists reauth_minutes integer not null default 10 check (reauth_minutes between 1 and 60),
  add column if not exists reauth_kinds text[] not null default array[
    'quote_send', 'invoice_issue', 'invoice_payment', 'reschedule', 'booking_cancel', 'booking_create',
    'wallet_adjust', 'referrer_status', 'referrer_code', 'service_publish', 'client_update'],
  add column if not exists siri_propose_intents text[] not null default array[
    'client_create', 'booking_confirm', 'move_booking', 'quote_estimate', 'invoice_last'];

alter table public.eva_devices add column if not exists scope text not null default 'read' check (scope in ('read', 'propose'));

-- ------------------------------------------------------- réauthentification
-- Vrai si la dernière connexion (mot de passe, lien magique, OTP…) date de moins
-- de reauth_minutes. Lit les revendications du jeton de session de la requête.
create or replace function public._eva_reauth_ok()
returns boolean language plpgsql stable security definer set search_path = public as $$
declare c jsonb; v_last numeric; v_min int;
begin
  c := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  if c is null or jsonb_typeof(c -> 'amr') <> 'array' then return false; end if;
  select max((x ->> 'timestamp')::numeric) into v_last from jsonb_array_elements(c -> 'amr') x where (x ->> 'timestamp') ~ '^[0-9]+(\.[0-9]+)?$';
  select reauth_minutes into v_min from eva_settings where id = 1;
  return v_last is not null and v_last >= extract(epoch from now()) - coalesce(v_min, 10) * 60;
exception when others then return false;
end $$;

create or replace function public._eva_require_reauth()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not _eva_reauth_ok() then raise exception 'REAUTH_REQUISE'; end if;
end $$;

-- Confirmation d'une proposition : réauthentification si l'action est sensible.
do $$ begin
  if to_regprocedure('public._eva_confirm_proposal_core(uuid, boolean)') is null then
    alter function public.eva_confirm_proposal(uuid, boolean) rename to _eva_confirm_proposal_core;
  end if;
end $$;
create or replace function public.eva_confirm_proposal(p_id uuid, p_confirm boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_kind text; v_status text;
begin
  select kind, status into v_kind, v_status from eva_proposals where id = p_id;
  if v_status = 'PENDING' and v_kind = any(coalesce((select reauth_kinds from eva_settings where id = 1), '{}')) then
    perform _eva_require_reauth();
  end if;
  return _eva_confirm_proposal_core(p_id, p_confirm);
end $$;

-- Réglages sensibles : mêmes exigences.
do $$
declare r record;
begin
  for r in select * from (values
      ('admin_set_work_hours', 'jsonb, integer'), ('admin_confirm_vat_regime', 'text, numeric'),
      ('eva_siri_set', 'boolean'), ('eva_device_create', 'text, integer')) v(fn, args) loop
    if to_regprocedure(format('public._%s_core(%s)', r.fn, r.args)) is null then
      execute format('alter function public.%I(%s) rename to %I', r.fn, r.args, '_' || r.fn || '_core');
    end if;
  end loop;
end $$;
create or replace function public.admin_set_work_hours(p_work_hours jsonb, p_travel_margin integer)
returns jsonb language plpgsql security definer set search_path = public as $$
begin perform _eva_require_reauth(); return _admin_set_work_hours_core(p_work_hours, p_travel_margin); end $$;
create or replace function public.admin_confirm_vat_regime(p_regime text, p_rate numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
begin perform _eva_require_reauth(); return _admin_confirm_vat_regime_core(p_regime, p_rate); end $$;
create or replace function public.eva_siri_set(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin if coalesce(p_enabled, false) then perform _eva_require_reauth(); end if; return _eva_siri_set_core(p_enabled); end $$;
-- Création d'un accès Siri : réauthentification ; le scope choisi est enregistré.
create or replace function public.eva_device_create(p_label text, p_days integer default 365, p_scope text default 'read')
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  perform _eva_require_reauth();
  if coalesce(p_scope, 'read') not in ('read', 'propose') then raise exception 'Autorisation inconnue.'; end if;
  r := _eva_device_create_core(p_label, p_days);
  update eva_devices set scope = coalesce(p_scope, 'read') where id = (r ->> 'device_id')::uuid;
  return r || jsonb_build_object('scope', coalesce(p_scope, 'read'));
end $$;
drop function if exists public.eva_device_create(text, integer);

-- Liste des appareils : avec l'autorisation de chacun.
create or replace function public.eva_devices_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  return jsonb_build_object('siri_enabled', (select siri_enabled from eva_settings where id = 1),
    'reauth_minutes', (select reauth_minutes from eva_settings where id = 1),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'label', d.label, 'hint', d.token_hint, 'created_at', d.created_at, 'expires_at', d.expires_at,
        'revoked_at', d.revoked_at, 'last_used_at', d.last_used_at, 'use_count', d.use_count, 'scope', d.scope,
        'active', d.revoked_at is null and d.expires_at > now()) order by d.created_at desc)
      from eva_devices d), '[]'::jsonb));
end $$;

-- --------------------------------------------- Siri : préparer une action
-- Appelée UNIQUEMENT par la fonction serveur eva-siri (clé de service).
-- Ne confirme JAMAIS : crée une proposition « en attente », visible dans EVA.
create or replace function public.eva_siri_propose(p_token_hash text, p_intent text, p_args jsonb, p_command text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d eva_devices; a jsonb := coalesce(p_args, '{}'::jsonb); r jsonb; v_client uuid; v_name text; v_b bookings; n int;
  v_kind text; v_payload jsonb; v_est jsonb; v_m jsonb; v_li jsonb; v_today date := (now() at time zone 'Europe/Paris')::date; v_key text;
begin
  select * into d from eva_devices where token_hash = p_token_hash for update;
  if not found or d.revoked_at is not null or d.expires_at <= now() then raise exception 'APPAREIL_NON_AUTORISE'; end if;
  if not coalesce((select siri_enabled from eva_settings where id = 1), false) then raise exception 'SIRI_DESACTIVE'; end if;
  if d.scope <> 'propose' then raise exception 'LECTURE_SEULE'; end if;
  if not (p_intent = any(coalesce((select siri_propose_intents from eva_settings where id = 1), '{}'))) then raise exception 'LECTURE_SEULE'; end if;
  if d.minute_start is not null and d.minute_start > now() - interval '1 minute' then
    if d.minute_count >= 20 then raise exception 'TROP_DE_DEMANDES'; end if;
    update eva_devices set minute_count = minute_count + 1, last_used_at = now(), use_count = use_count + 1 where id = d.id;
  else
    update eva_devices set minute_start = now(), minute_count = 1, last_used_at = now(), use_count = use_count + 1 where id = d.id;
  end if;
  -- Identité de l'administrateur, SANS horodatage de connexion : aucune action sensible ne peut être confirmée par cette voie.
  perform set_config('request.jwt.claim.sub', d.created_by::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', d.created_by, 'role', 'authenticated')::text, true);

  -- Client cité (ou identifiant fourni).
  if a ? 'client' or a ? 'client_id' then
    r := _eva_resolve_client(a);
    v_client := nullif(r ->> 'client_id', '')::uuid;
    if v_client is null and p_intent <> 'client_create' then
      return jsonb_build_object('ok', false, 'need', case when jsonb_array_length(coalesce(r -> 'clients', '[]'::jsonb)) > 1
        then 'Plusieurs clients correspondent à ' || coalesce(a ->> 'client', 'ce nom') || ' : précisez le prénom, ou ouvrez EVA.'
        else 'Je ne trouve pas ' || coalesce(a ->> 'client', 'ce client') || ' dans vos clients.' end);
    end if;
    select trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')) into v_name from clients where id = v_client;
  end if;

  if p_intent = 'client_create' then
    if coalesce(a ->> 'last_name', '') = '' and coalesce(a ->> 'first_name', '') = '' then
      return jsonb_build_object('ok', false, 'need', 'Dites le nom du client et son téléphone, par exemple : crée un client Paul Durand 06 12 34 56 78.');
    end if;
    if coalesce(a ->> 'phone', '') = '' and coalesce(a ->> 'email', '') = '' then
      return jsonb_build_object('ok', false, 'need', 'Il me faut aussi un téléphone ou un e-mail pour créer la fiche.');
    end if;
    v_kind := 'client_create';
    v_payload := jsonb_build_object('first_name', a ->> 'first_name', 'last_name', a ->> 'last_name', 'phone', a ->> 'phone', 'email', a ->> 'email');

  elsif p_intent = 'booking_confirm' then
    if v_client is null then return jsonb_build_object('ok', false, 'need', 'Quelle demande ? Dites par exemple : confirme la demande de Madame Lefèvre.'); end if;
    select count(*) into n from bookings where client_id = v_client and status = 'PENDING' and date >= v_today;
    if n = 0 then return jsonb_build_object('ok', false, 'need', 'Aucune demande de rendez-vous en attente pour ' || v_name || '.'); end if;
    if n > 1 then return jsonb_build_object('ok', false, 'need', v_name || ' a plusieurs demandes en attente : choisissez dans EVA.'); end if;
    select * into v_b from bookings where client_id = v_client and status = 'PENDING' and date >= v_today limit 1;
    v_kind := 'booking_confirm'; v_payload := jsonb_build_object('booking_id', v_b.id);

  elsif p_intent = 'move_booking' then
    if v_client is null then return jsonb_build_object('ok', false, 'need', 'Quel rendez-vous ? Dites par exemple : déplace le rendez-vous de Monsieur Martin à jeudi 14 h.'); end if;
    if coalesce(a ->> 'to_date', '') = '' or coalesce(a ->> 'to_time', '') = '' then
      return jsonb_build_object('ok', false, 'need', 'À quel jour et à quelle heure ? Dites par exemple : à jeudi 14 h.');
    end if;
    select count(*) into n from bookings where client_id = v_client and status in ('PENDING', 'CONFIRMED') and date >= v_today
       and (coalesce(a ->> 'from_date', '') = '' or date = (a ->> 'from_date')::date);
    if n = 0 then return jsonb_build_object('ok', false, 'need', 'Aucun rendez-vous à venir pour ' || v_name || '.'); end if;
    if n > 1 then return jsonb_build_object('ok', false, 'need', v_name || ' a plusieurs rendez-vous à venir : précisez la date actuelle, ou choisissez dans EVA.'); end if;
    select * into v_b from bookings where client_id = v_client and status in ('PENDING', 'CONFIRMED') and date >= v_today
       and (coalesce(a ->> 'from_date', '') = '' or date = (a ->> 'from_date')::date) limit 1;
    v_kind := 'reschedule'; v_payload := jsonb_build_object('booking_id', v_b.id, 'date', a ->> 'to_date', 'start', a ->> 'to_time');

  elsif p_intent = 'quote_estimate' then
    if v_client is null then return jsonb_build_object('ok', false, 'need', 'Pour quel client ? Dites par exemple : prépare un devis de désembouage pour Monsieur Martin.'); end if;
    if coalesce(a ->> 'service', '') = '' then return jsonb_build_object('ok', false, 'need', 'Quelle prestation faut-il chiffrer pour ' || v_name || ' ?'); end if;
    v_est := _eva_quote_estimate(a ->> 'service', v_client, null);
    select x into v_m from jsonb_array_elements(coalesce(v_est -> 'matches', '[]'::jsonb)) x where x ->> 'price_cents' is not null limit 2;
    select count(*) into n from jsonb_array_elements(coalesce(v_est -> 'matches', '[]'::jsonb)) x where x ->> 'price_cents' is not null;
    if n = 0 then return jsonb_build_object('ok', false, 'need', 'Aucune prestation à prix fixe ne correspond à ' || (a ->> 'service') || ' : à chiffrer dans EVA.'); end if;
    if n > 1 then return jsonb_build_object('ok', false, 'need', 'Plusieurs prestations correspondent à ' || (a ->> 'service') || ' : choisissez dans EVA.'); end if;
    v_kind := 'quote_draft'; v_payload := jsonb_build_object('client_id', v_client, 'items', jsonb_build_array(jsonb_build_object('kind', v_m ->> 'kind', 'id', v_m ->> 'id')), 'distance_km', null);

  elsif p_intent = 'invoice_last' then
    v_li := _eva_last_intervention();
    if v_li is null or v_li = 'null'::jsonb then return jsonb_build_object('ok', false, 'need', 'Aucune intervention terminée à facturer.'); end if;
    if v_li -> 'invoice' is not null and v_li -> 'invoice' <> 'null'::jsonb then
      return jsonb_build_object('ok', false, 'need', 'La dernière intervention a déjà une facture (' || coalesce(v_li -> 'invoice' ->> 'reference', 'brouillon') || ').');
    end if;
    v_kind := 'invoice_draft'; v_payload := jsonb_build_object('source', 'booking', 'id', v_li ->> 'booking_id');
  else
    raise exception 'LECTURE_SEULE';
  end if;

  v_key := 'siri:' || left(replace(d.id::text, '-', ''), 12) || ':' || left(md5(lower(coalesce(p_command, '')) || p_intent || coalesce(p_args::text, '')), 20) || ':' || to_char(now(), 'YYMMDDHH24MI');
  begin
    r := eva_propose(v_kind, v_payload, v_key);
  exception when others then
    return jsonb_build_object('ok', false, 'need', case when sqlerrm like '%DOSSIER_OCCUPE%' then 'Une proposition attend déjà sur ce dossier : ouvrez EVA pour la confirmer ou l''annuler.'
      when sqlerrm like '%AGENT_DESACTIVE%' then 'Cet agent est désactivé dans les réglages d''EVA.' else sqlerrm end);
  end;
  perform _eva_log('Siri : ' || coalesce(p_command, ''), 'siri:propose:' || v_kind, null, 'proposed', jsonb_build_object('proposal_id', r ->> 'proposal_id', 'device', d.label));
  return jsonb_build_object('ok', true, 'proposal_id', r ->> 'proposal_id', 'title', coalesce(r ->> 'title', (select title from eva_proposals where id = (r ->> 'proposal_id')::uuid)),
    'level', coalesce((r ->> 'level')::int, (select level from eva_proposals where id = (r ->> 'proposal_id')::uuid)),
    'sensitive', v_kind = any(coalesce((select reauth_kinds from eva_settings where id = 1), '{}')), 'device', d.label);
end $$;

-- Lecture pour l'application : la proposition à ouvrir depuis le lien Siri.
create or replace function public.eva_proposal_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  return (select jsonb_build_object('id', p.id, 'proposal_id', p.id, 'kind', p.kind, 'agent', p.agent, 'level', p.level, 'title', p.title, 'consequences', p.consequences,
    'status', p.status, 'error', p.error, 'sensitive', p.kind = any(coalesce((select reauth_kinds from eva_settings where id = 1), '{}'))) from eva_proposals p where p.id = p_id);
end $$;

-- ------------------------------------------------------------------ droits
do $$
declare f text;
begin
  foreach f in array array['public._eva_reauth_ok()', 'public._eva_require_reauth()', 'public._eva_confirm_proposal_core(uuid, boolean)',
      'public._admin_set_work_hours_core(jsonb, integer)', 'public._admin_confirm_vat_regime_core(text, numeric)',
      'public._eva_siri_set_core(boolean)', 'public._eva_device_create_core(text, integer)', 'public.eva_siri_propose(text, text, jsonb, text)'] loop
    execute 'revoke all on function ' || f || ' from public, anon, authenticated';
  end loop;
  execute 'grant execute on function public.eva_siri_propose(text, text, jsonb, text) to service_role';
  foreach f in array array['public.eva_confirm_proposal(uuid, boolean)', 'public.admin_set_work_hours(jsonb, integer)', 'public.admin_confirm_vat_regime(text, numeric)',
      'public.eva_siri_set(boolean)', 'public.eva_device_create(text, integer, text)', 'public.eva_devices_list()', 'public.eva_proposal_get(uuid)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

insert into public.eva_tools (key, agent, label, level, status, example, note, sort) values
  ('siri_propose', 'eva', 'Préparer une action par Siri (confirmée ensuite dans EVA)', 2, 'disponible', 'Dis Siri, EVA… confirme la demande de Madame Lefèvre',
   'Fiche client, devis et facture en brouillon, confirmer ou déplacer un rendez-vous', 71),
  ('reauth', 'eva', 'Réauthentification pour les actions sensibles', 3, 'disponible', null,
   'Envoi de documents, rendez-vous, argent, réglages : connexion de moins de 10 minutes', 72)
on conflict (key) do update set agent = excluded.agent, label = excluded.label, level = excluded.level, status = excluded.status,
  example = excluded.example, note = excluded.note, sort = excluded.sort;
