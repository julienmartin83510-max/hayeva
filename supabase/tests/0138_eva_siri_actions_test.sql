-- Scénarios de test de la migration 0138 (Siri prépare, liPhone confirme ; réauthentification).
-- UNIQUEMENT sur une base locale jetable (données fictives créées ici), après 0135 à 0138.
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

insert into bookings (customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select :MARTIN::uuid, (select id from clients where email = 'martin@test.local'), (select id from services where slug = 'plomberie-mitigeur-lavabo'), date '2027-01-12', time '09:00', 'CONFIRMED', 60, 9900, 9900;
insert into clients (first_name, last_name, email, phone) values ('Élodie', 'Lefèvre', 'lefevre@test.local', '0655667788');
insert into bookings (client_id, guest_name, guest_email, guest_phone, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select (select id from clients where email = 'lefevre@test.local'), 'Élodie Lefèvre', 'lefevre@test.local', '0655667788', (select id from services where slug = 'plomberie-robinet-arret'), date '2027-01-12', time '14:30', 'PENDING', 45, 8900, 8900;
create or replace function pg_temp.stale(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated', 'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint - 3600)))::text, false);
$$;

-- =====================================================================
\echo '=== A. Réauthentification des actions sensibles'
-- =====================================================================
select pg_temp.ok(_eva_reauth_ok(), 'A1 connexion de moins de 10 minutes : reconnue');
select pg_temp.stale(:ADMIN);
select pg_temp.ok(not _eva_reauth_ok(), 'A2 connexion d''il y a 1 heure : trop ancienne');
create temp table t_mv as select eva_propose('reschedule', format('{"booking_id":"%s","date":"2027-01-14","start":"10:00"}', (select id from bookings where date = '2027-01-12' and start_time = '09:00'))::jsonb, 'cle-test-deplacement') p;
select pg_temp.ok(pg_temp.err(format('select eva_confirm_proposal(%L, true)', (select p ->> 'proposal_id' from t_mv))) like '%REAUTH_REQUISE%', 'A3 déplacement (sensible) avec une connexion ancienne : refusé');
select pg_temp.ok((select status from eva_proposals where id = (select (p ->> 'proposal_id')::uuid from t_mv)) = 'PENDING' and (select date from bookings where date in ('2027-01-12','2027-01-14') and start_time in ('09:00','10:00') limit 1) = '2027-01-12', 'A4 rien n''est modifié');
select pg_temp.as_user(:ADMIN);
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_mv), true) ->> 'status') = 'EXECUTED', 'A5 après reconnexion : déplacement exécuté');
select pg_temp.stale(:ADMIN);
create temp table t_cl as select eva_propose('client_create', '{"first_name":"Lucie","last_name":"Durand","phone":"0611111111"}', 'cle-test-client-durand') p;
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_cl), true) ->> 'status') = 'EXECUTED', 'A6 fiche client (non sensible) : confirmée sans reconnexion');
select pg_temp.ok(pg_temp.err($$select admin_set_work_hours('{"1":[["08:00","12:00"]],"2":[],"3":[],"4":[],"5":[],"6":[],"7":[]}', 30)$$) like '%REAUTH_REQUISE%', 'A7 changer les horaires avec une connexion ancienne : refusé');
select pg_temp.ok(pg_temp.err($$select admin_confirm_vat_regime('franchise_base', null)$$) like '%REAUTH_REQUISE%', 'A8 confirmer la TVA avec une connexion ancienne : refusé');
select pg_temp.ok(pg_temp.err($$select eva_device_create('iPhone', 30, 'propose')$$) like '%REAUTH_REQUISE%', 'A9 créer un accès Siri avec une connexion ancienne : refusé');
select pg_temp.as_user(:ADMIN);
select pg_temp.ok((admin_set_work_hours((select work_hours from booking_settings where id = 1), 30) ->> 'ok')::boolean is not false, 'A10 après reconnexion : horaires enregistrés');
select pg_temp.ok(not has_function_privilege('authenticated', 'public._eva_confirm_proposal_core(uuid, boolean)', 'execute')
              and not has_function_privilege('authenticated', 'public._admin_set_work_hours_core(jsonb, integer)', 'execute'), 'A11 versions internes inaccessibles (aucun contournement)');

-- =====================================================================
\echo '=== B. Siri prépare (jamais ne confirme)'
-- =====================================================================
create temp table t_dev as select eva_device_create('iPhone de test', 30, 'propose') r;
create temp table t_ro as select eva_device_create('iPad lecture', 30, 'read') r;
select eva_siri_set(true) \g /dev/null
\set H '(select encode(extensions.digest((select r ->> \'token\' from t_dev), \'sha256\'), \'hex\'))'
\set HRO '(select encode(extensions.digest((select r ->> \'token\' from t_ro), \'sha256\'), \'hex\'))'
select pg_temp.as_user(null);
select pg_temp.ok(pg_temp.err(format('select eva_siri_propose(%s, %L, %L, %L)', :'HRO', 'booking_confirm', '{"client":"Madame Lefèvre"}', 'confirme')) like '%LECTURE_SEULE%', 'B1 appareil « questions seulement » : préparation refusée');
create temp table t_s1 as select eva_siri_propose(:H, 'booking_confirm', '{"client":"Madame Lefèvre"}', 'confirme la demande de Madame Lefèvre') r;
select pg_temp.ok((select (r ->> 'ok')::boolean and r ->> 'proposal_id' is not null from t_s1), 'B2 « confirme la demande de Madame Lefèvre » : proposition préparée');
select pg_temp.ok((select status from bookings where client_id = (select id from clients where email = 'lefevre@test.local')) = 'PENDING', 'B3 rendez-vous toujours « à confirmer » : rien d''exécuté par Siri');
select pg_temp.ok(pg_temp.err(format('select eva_confirm_proposal(%L, true)', (select r ->> 'proposal_id' from t_s1))) is not null, 'B4 la passerelle Siri ne peut pas confirmer (pas de session)');
create temp table t_s2 as select eva_siri_propose(:H, 'move_booking', '{"client":"Monsieur Martin","to_date":"2027-01-15","to_time":"11:00"}', 'déplace le rendez-vous de Monsieur Martin à vendredi 11 h') r;
select pg_temp.ok((select (r ->> 'ok')::boolean and (r ->> 'sensitive')::boolean from t_s2), 'B5 déplacement préparé et signalé « sensible »');
create temp table t_s3 as select eva_siri_propose(:H, 'client_create', '{"first_name":"Marc","last_name":"Petit","phone":"0698765432"}', 'crée un client Marc Petit') r;
select pg_temp.ok((select (r ->> 'ok')::boolean from t_s3) and not exists (select 1 from clients where last_name = 'Petit'), 'B6 fiche client préparée, pas encore créée');
select pg_temp.ok((select r ->> 'need' from (select eva_siri_propose(:H, 'client_create', '{"first_name":"Marc","last_name":"Dupuis"}', 'crée un client Marc Dupuis') r) x) like '%téléphone ou un e-mail%', 'B7 informations manquantes : EVA les demande');
select pg_temp.ok((select r ->> 'need' from (select eva_siri_propose(:H, 'booking_confirm', '{"client":"Monsieur Inconnu"}', 'x') r) x) like '%ne trouve pas%', 'B8 client inconnu : signalé, rien de préparé');
select pg_temp.ok((select r ->> 'need' from (select eva_siri_propose(:H, 'move_booking', '{"client":"Monsieur Martin"}', 'x') r) x) like '%quel jour%', 'B9 date manquante : demandée');
select pg_temp.as_user(:ADMIN);
select pg_temp.ok((eva_confirm_proposal((select (r ->> 'proposal_id')::uuid from t_s1), true) ->> 'status') = 'EXECUTED', 'B10 confirmation dans EVA (session récente) : exécutée');
select pg_temp.ok((select status from bookings where client_id = (select id from clients where email = 'lefevre@test.local')) = 'CONFIRMED', 'B10b demande de Madame Lefèvre confirmée en base');
select pg_temp.ok((select count(*) from eva_journal where intent like 'siri:propose:%') = 3, 'B11 préparations Siri journalisées');
select pg_temp.ok((eva_proposal_get((select (r ->> 'proposal_id')::uuid from t_s2)) ->> 'sensitive')::boolean, 'B12 lien Siri : la proposition est lisible dans EVA');
select pg_temp.as_user(:MARTIN);
select pg_temp.ok(pg_temp.err(format('select eva_proposal_get(%L)', (select r ->> 'proposal_id' from t_s2))) like '%réservée%', 'B13 un client ne peut pas lire les propositions');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.eva_siri_propose(text, text, jsonb, text)', 'execute'), 'B14 préparation Siri réservée à la fonction serveur');
\echo 'TOUS LES TESTS EVA 0138 SONT PASSÉS'
