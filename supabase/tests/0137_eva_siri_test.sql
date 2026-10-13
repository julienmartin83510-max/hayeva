-- Scénarios de test de la migration 0137 (EVA, accès Siri en lecture seule).
-- UNIQUEMENT sur une base locale jetable (données fictives créées ici), après 0135, 0136 et 0137.
-- Jamais sur la base de production.
\set ON_ERROR_STOP on
\pset pager off
set client_min_messages = notice;

create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'ÉCHEC : %', msg; end if;
  raise notice 'OK  %', msg;
end $$;
create or replace function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(u::text, ''), false), set_config('request.jwt.claim.role', case when u is null then 'anon' else 'authenticated' end, false),
         -- Session « fraîche » (connexion il y a moins d'une minute), comme après une connexion réelle.
         set_config('request.jwt.claims', case when u is null then '' else jsonb_build_object('sub', u, 'role', 'authenticated', 'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint)))::text end, false);
$$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;
-- Propose puis confirme ; renvoie le résultat de la confirmation.
create or replace function pg_temp.do_it(p_kind text, p_payload jsonb, p_key text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  r := eva_propose(p_kind, p_payload, p_key);
  return eva_confirm_proposal((r ->> 'proposal_id')::uuid, true);
end $$;

insert into vault.secrets (name, secret) values ('webhook_secret', 'local-test-secret') on conflict (name) do nothing;
update booking_settings set opening_date = date '2027-01-02' where id = 1;
do $$ declare u record; begin
  for u in select * from (values
    ('00000000-0000-0000-0000-0000000000a1'::uuid, 'admin@test.local', 'admin', 'Ada', 'Admin', '0600000001', '1 rue Admin'),
    ('00000000-0000-0000-0000-0000000000c1'::uuid, 'martin@test.local', 'customer', 'Paul', 'Martin', '0699887766', '2 place Centrale'),
    ('00000000-0000-0000-0000-0000000000c2'::uuid, 'dupont@test.local', 'customer', 'Jean', 'Dupont', '0611223344', '5 rue des Pins')) v(id, email, role, fn, ln, ph, addr) loop
    insert into auth.users (id, email) values (u.id, u.email) on conflict do nothing;
    insert into profiles (user_id, email, global_role) values (u.id, u.email, u.role) on conflict (user_id) do update set global_role = excluded.global_role;
    insert into customer_profiles (user_id, first_name, last_name, phone) values (u.id, u.fn, u.ln, u.ph) on conflict (user_id) do nothing;
    perform find_or_create_client(u.id, u.email, u.ph, u.fn, u.ln, u.addr);
  end loop;
end $$;
update clients set city = 'Le Muy', postal_code = '83490' where email = 'martin@test.local';
\set ADMIN '\'00000000-0000-0000-0000-0000000000a1\''
\set MARTIN '\'00000000-0000-0000-0000-0000000000c1\''
select pg_temp.as_user(:ADMIN);

-- Rendez-vous fictif pour les lectures.
insert into bookings (customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select :MARTIN::uuid, (select id from clients where email = 'martin@test.local'), (select id from services where slug = 'plomberie-mitigeur-lavabo'), date '2027-01-12', time '09:00', 'CONFIRMED', 60, 9900, 9900;

-- =====================================================================
\echo '=== A. Appareils : création, empreinte, liste'
-- =====================================================================
create temp table t_dev as select eva_device_create('iPhone de test', 30) r;
select pg_temp.ok((select r ->> 'token' ~ '^eva_[0-9a-f]{48}$' from t_dev), 'A1 jeton aléatoire (192 bits) renvoyé une seule fois');
select pg_temp.ok((select count(*) = 0 from eva_devices where token_hash = (select r ->> 'token' from t_dev) or token_hint = (select r ->> 'token' from t_dev)), 'A2 jeton jamais stocké en clair');
select pg_temp.ok((select token_hash = encode(extensions.digest((select r ->> 'token' from t_dev), 'sha256'), 'hex') from eva_devices), 'A3 empreinte SHA-256 conservée');
select pg_temp.ok((select (eva_devices_list() -> 'devices' -> 0) ?& array['id', 'label', 'hint', 'active'] and not (eva_devices_list()::text like '%' || (select token_hash from eva_devices limit 1) || '%')), 'A4 liste : ni jeton ni empreinte exposés');
select pg_temp.ok((eva_devices_list() ->> 'siri_enabled')::boolean is false, 'A5 accès Siri désactivé par défaut');
select pg_temp.ok(pg_temp.err($$select eva_device_create('x', 30)$$) like 'Nommez%', 'A6 nom d''appareil requis');
select pg_temp.ok(pg_temp.err($$select eva_device_create('iPhone', 900)$$) like 'Durée%', 'A7 validité limitée à 365 jours');
\set TOKEN_HASH '(select token_hash from eva_devices where label = \'iPhone de test\')'

-- =====================================================================
\echo '=== B. Droits'
-- =====================================================================
select pg_temp.as_user(:MARTIN);
select pg_temp.ok(pg_temp.err($$select eva_device_create('iPhone pirate', 30)$$) like '%réservée%', 'B1 un client ne peut pas créer d''appareil');
select pg_temp.ok(pg_temp.err($$select eva_devices_list()$$) like '%réservée%', 'B2 un client ne voit pas les appareils');
select pg_temp.ok(pg_temp.err($$select eva_siri_set(true)$$) like '%réservée%', 'B3 un client ne peut pas activer Siri');
select pg_temp.as_user(:ADMIN);
select pg_temp.ok(not has_function_privilege('authenticated', 'public.eva_siri_run(text, text, jsonb, text)', 'execute')
              and not has_function_privilege('anon', 'public.eva_siri_run(text, text, jsonb, text)', 'execute')
              and has_function_privilege('service_role', 'public.eva_siri_run(text, text, jsonb, text)', 'execute'), 'B4 passerelle réservée à la clé de service (fonction serveur)');
select pg_temp.ok(not has_table_privilege('authenticated', 'public.eva_devices', 'select') and not has_table_privilege('anon', 'public.eva_devices', 'select'), 'B5 table des appareils inaccessible directement');

-- =====================================================================
\echo '=== C. Passerelle : désactivée, lecture seule, jeton'
-- =====================================================================
-- La fonction serveur appelle sans identité utilisateur (clé de service).
select pg_temp.as_user(null);
select pg_temp.ok(pg_temp.err(format('select eva_siri_run(%L, %L, %L, %L)', (select token_hash from eva_devices limit 1), 'agenda', '{"date":"2027-01-12"}', 'mes rendez-vous')) like 'SIRI_DESACTIVE%', 'C1 Siri désactivé : refusé');
select pg_temp.as_user(:ADMIN); select eva_siri_set(true) \g /dev/null
select pg_temp.as_user(null);
create temp table t_r as select eva_siri_run((select token_hash from eva_devices limit 1), 'agenda', '{"date":"2027-01-12"}', 'qu''est-ce que j''ai mardi') r;
select pg_temp.ok((select (r ->> 'ok')::boolean and jsonb_array_length(r -> 'data' -> 'interventions') = 1 and r -> 'data' -> 'interventions' -> 0 ->> 'client' = 'Paul Martin' from t_r), 'C2 lecture du planning réel au nom de l''administrateur');
select pg_temp.ok((select actor_user_id = :ADMIN::uuid and command = 'Siri : qu''est-ce que j''ai mardi' from eva_journal where intent = 'agenda' order by created_at desc limit 1), 'C3 journal : commande Siri tracée au nom de l''administrateur');
select pg_temp.ok(current_setting('request.jwt.claim.sub', true) = '', 'C4 identité limitée à la transaction de la demande');
select pg_temp.ok((select (eva_siri_run((select token_hash from eva_devices limit 1), 'agenda_range', '{"from":"2027-01-11","to":"2027-01-16"}', 'cette semaine') -> 'data' ->> 'count')::int = 1), 'C5 lecture phase 2 (semaine) disponible');
select pg_temp.ok(pg_temp.err(format('select eva_siri_run(%L, %L, %L, %L)', (select token_hash from eva_devices limit 1), 'booking_cancel', '{}', 'annule')) like 'LECTURE_SEULE%', 'C6 action refusée : lecture seule');
select pg_temp.ok(pg_temp.err(format('select eva_siri_run(%L, %L, %L, %L)', (select token_hash from eva_devices limit 1), 'quote_send', '{}', 'envoie')) like 'LECTURE_SEULE%', 'C7 envoi de devis refusé');
select pg_temp.ok(pg_temp.err(format('select eva_siri_run(%L, %L, %L, %L)', encode(extensions.digest('eva_faux', 'sha256'), 'hex'), 'agenda', '{}', 'x')) like 'APPAREIL_NON_AUTORISE%', 'C8 jeton inconnu refusé');
select pg_temp.ok((select use_count = 2 and last_used_at is not null from eva_devices limit 1), 'C9 utilisation comptée');

-- =====================================================================
\echo '=== D. Limites, révocation, expiration, perte du rôle'
-- =====================================================================
update eva_devices set minute_start = now(), minute_count = 20;
select pg_temp.ok(pg_temp.err(format('select eva_siri_run(%L, %L, %L, %L)', (select token_hash from eva_devices limit 1), 'agenda', '{}', 'x')) like 'TROP_DE_DEMANDES%', 'D1 20 demandes par minute et par appareil');
update eva_devices set minute_start = now() - interval '2 minutes', minute_count = 20;
select pg_temp.ok((eva_siri_run((select token_hash from eva_devices limit 1), 'attention', '{}', 'attention') ->> 'ok')::boolean, 'D2 compteur remis à zéro après une minute');
update profiles set global_role = 'customer' where user_id = :ADMIN::uuid;
select pg_temp.ok(pg_temp.err(format('select eva_siri_run(%L, %L, %L, %L)', (select token_hash from eva_devices limit 1), 'agenda', '{}', 'x')) like '%réservée%', 'D3 créateur qui n''est plus administrateur : refusé');
update profiles set global_role = 'admin' where user_id = :ADMIN::uuid;
update eva_devices set expires_at = now() - interval '1 second';
select pg_temp.ok(pg_temp.err(format('select eva_siri_run(%L, %L, %L, %L)', (select token_hash from eva_devices limit 1), 'agenda', '{}', 'x')) like 'APPAREIL_NON_AUTORISE%', 'D4 appareil expiré refusé');
update eva_devices set expires_at = now() + interval '1 day';
select pg_temp.as_user(:ADMIN);
select eva_device_revoke((select id from eva_devices limit 1)) \g /dev/null
select pg_temp.as_user(null);
select pg_temp.ok(pg_temp.err(format('select eva_siri_run(%L, %L, %L, %L)', (select token_hash from eva_devices limit 1), 'agenda', '{}', 'x')) like 'APPAREIL_NON_AUTORISE%', 'D5 appareil révoqué refusé immédiatement');
select pg_temp.as_user(:ADMIN);
select pg_temp.ok((select count(*) = 1 from eva_devices), 'D6 révocation sans suppression (historique conservé)');
select eva_device_create('iPhone ' || g, 30) from generate_series(1, 5) g \g /dev/null
select pg_temp.ok(pg_temp.err($$select eva_device_create('iPhone 6', 30)$$) like 'Cinq appareils%', 'D7 cinq appareils actifs au maximum');
update eva_settings set enabled = false;
select pg_temp.as_user(null);
select pg_temp.ok(pg_temp.err(format('select eva_siri_run(%L, %L, %L, %L)', (select token_hash from eva_devices where label = 'iPhone 1'), 'agenda', '{}', 'x')) like 'EVA_DESACTIVEE%', 'D8 EVA désactivée : Siri refusé aussi');
select pg_temp.as_user(:ADMIN);
update eva_settings set enabled = true;
select pg_temp.ok((select count(*) from eva_journal where intent like 'siri:%') = 7, 'D9 créations et révocations d''appareils journalisées');
\echo 'TOUS LES TESTS EVA SIRI SONT PASSÉS'
