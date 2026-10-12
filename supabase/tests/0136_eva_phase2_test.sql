-- Scénarios de test de la migration 0136 (EVA, phase 2).
-- UNIQUEMENT sur une base locale jetable (données fictives créées ici), après 0135 et 0136.
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

-- Historique fictif de Monsieur Martin : intervention terminée + compte rendu brouillon, équipement à entretenir,
-- rendez-vous la semaine du 11 janvier 2027, facture et paiement, code de parrainage, crédit fidélité.
insert into bookings (customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select :MARTIN::uuid, (select id from clients where email = 'martin@test.local'), (select id from services where slug = 'plomberie-mitigeur-lavabo'), date '2027-01-11', time '09:00', 'CONFIRMED', 60, 9900, 9900
union all select :MARTIN::uuid, (select id from clients where email = 'martin@test.local'), (select id from services where slug = 'plomberie-robinet-arret'), date '2027-01-13', time '14:00', 'CONFIRMED', 45, 8900, 8900
union all select '00000000-0000-0000-0000-0000000000c2'::uuid, (select id from clients where email = 'dupont@test.local'), (select id from services where slug = 'plomberie-robinet-arret'), date '2027-01-14', time '10:00', 'PENDING', 45, 8900, 8900;
update bookings set status = 'COMPLETED' where date = '2027-01-11';
insert into interventions (booking_id, report_status, observations) select id, 'DRAFT', 'Mitigeur grippé.' from bookings where date = '2027-01-11';
insert into customer_equipment (customer_user_id, client_id, equipment_type, brand, model, last_service_at, maintenance_reminders_enabled)
select :MARTIN::uuid, (select id from clients where email = 'martin@test.local'), 'chaudiere_gaz', 'Saunier Duval', 'ThemaPlus', current_date - interval '11 months', true;
insert into referral_codes (client_id, code, participant_type, status) select id, 'MARTIN83', 'individual', 'active' from clients where email = 'martin@test.local';

-- =====================================================================
-- A. Sécurité
-- =====================================================================
select pg_temp.as_user(:MARTIN);
select pg_temp.ok(pg_temp.err($$select eva_query('client_detail', '{"client":"Martin"}', null)$$) like '%réservée%', 'A1 client connecté : fiche client via EVA refusée');
select pg_temp.ok(pg_temp.err($$select eva_propose('client_create', '{"first_name":"X","phone":"0600000000"}', 'cle-a2-xxxxxx')$$) like '%réservée%', 'A2 client connecté : création de client refusée');
set role authenticated;
select pg_temp.ok(pg_temp.err($$select _eva_client_detail(gen_random_uuid())$$) like '%permission%', 'A3 fonctions internes inaccessibles');
select pg_temp.ok(pg_temp.err($$select _eva_execute_ext('client_create', '{}', null)$$) like '%permission%', 'A4 exécution directe sans proposition impossible');
reset role;
select pg_temp.as_user(:ADMIN);
select pg_temp.ok(pg_temp.err($$select eva_query('drop_table', '{}', null)$$) like '%INTENTION_INCONNUE%', 'A5 lecture hors liste refusée');
select pg_temp.ok(pg_temp.err($$select eva_propose('delete_everything', '{}', 'cle-a6-xxxxxx')$$) like '%PROPOSITION_INCONNUE%', 'A6 action hors liste refusée');

-- =====================================================================
-- B. Lectures
-- =====================================================================
select pg_temp.ok((eva_query('agenda_range', '{"from":"2027-01-11","to":"2027-01-17"}', 'combien de rendez-vous cette semaine') -> 'data' ->> 'count')::int = 3, 'B1 « combien de rendez-vous cette semaine » : 3');
select pg_temp.ok(jsonb_array_length(eva_query('agenda_range', '{"from":"2027-01-11","to":"2027-01-17"}', null) -> 'data' -> 'days') = 3, 'B2 semaine : 3 jours avec rendez-vous');
select pg_temp.ok((eva_query('stats', '{"from":"2027-01-01","to":"2027-01-31"}', null) -> 'data') ? 'requests_received', 'B3 statistiques : fonction existante admin_booking_stats');
select pg_temp.ok((eva_query('catalog', '{"query":"mitigeur"}', null) -> 'data' -> 'items') @> jsonb_build_array(jsonb_build_object('label', 'Remplacement mitigeur lavabo', 'price_cents', (select base_price_cents from services where slug = 'plomberie-mitigeur-lavabo'))), 'B4 tarifs : prix enregistré du catalogue');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(eva_query('catalog', '{"query":""}', null) -> 'data' -> 'items') x where not (x ->> 'active')::boolean), 'B5 catalogue : prestations masquées exclues par défaut');
select pg_temp.ok((eva_query('client_detail', '{"client":"Monsieur Martin"}', null) -> 'data' -> 'interventions' -> 0 ->> 'observations') = 'Mitigeur grippé.', 'B6 « dernière intervention chez ce client » : historique réel');
select pg_temp.ok((eva_query('client_detail', '{"client":"Martin"}', null) -> 'data' -> 'equipment' -> 0 ->> 'brand') = 'Saunier Duval', 'B7 fiche client : équipements');
select pg_temp.ok((eva_query('client_detail', '{"client":"Martin"}', null) -> 'data' -> 'referral' ->> 'code') = 'MARTIN83', 'B8 fiche client : code de parrainage');
select pg_temp.ok((eva_query('client_detail', '{"client":"Inconnu Personne"}', null) ->> 'empty')::boolean, 'B9 client inconnu : rien d''inventé');
select pg_temp.ok((eva_query('maintenance_due', '{"days":60}', null) -> 'data' -> 'items') @> '[{"client":"Paul Martin","type":"chaudiere_gaz","next_booking":"2027-01-13"}]', 'B10 « entretiens à renouveler » : chaudière de Paul Martin (échéance dans 1 mois), prochain RDV indiqué');
select pg_temp.ok((eva_query('referrals', '{"query":"martin"}', null) -> 'data' -> 'referrers') @> '[{"code":"MARTIN83"}]', 'B11 parrainage : code existant');
select pg_temp.ok((eva_query('loyalty', '{"client":"Martin"}', null) -> 'data' ->> 'balance_cents')::int = 0, 'B12 fidélité : solde réel (0)');
select pg_temp.ok((eva_query('report', format('{"booking_id":"%s"}', (select id from bookings where date = '2027-01-11'))::jsonb, null) -> 'data' -> 'intervention' ->> 'report_status') = 'DRAFT', 'B13 compte rendu : brouillon lu');
select pg_temp.ok((eva_query('invoices_list', '{"client":"Martin"}', null) ->> 'empty')::boolean, 'B14 factures d''un client sans facture : vide');

-- =====================================================================
-- C. Clients
-- =====================================================================
select pg_temp.ok(pg_temp.err($$select eva_propose('client_create', '{"first_name":"Luc"}', 'cle-c1-xxxxxx')$$) like '%téléphone ou un e-mail%', 'C1 création sans contact : refusée');
select pg_temp.ok(pg_temp.err($$select eva_propose('client_create', '{"first_name":"Paul","last_name":"Martin2","phone":"06 99 88 77 66"}', 'cle-c2-xxxxxx')$$) like '%DOUBLON%Paul Martin%', 'C2 doublon de téléphone détecté');
select pg_temp.ok(pg_temp.err($$select eva_propose('client_create', '{"first_name":"Luc","email":"pas-un-email"}', 'cle-c3-xxxxxx')$$) like '%E-mail invalide%', 'C3 e-mail invalide refusé');
create temp table t1 as select eva_propose('client_create', '{"first_name":"Luc","last_name":"Bernard","phone":"07 12 34 56 78","city":"Fréjus"}', 'cle-c4-xxxxxx') p;
select pg_temp.ok((select (p ->> 'level')::int = 2 from t1) and not exists (select 1 from clients where last_name = 'Bernard'), 'C4 proposition de création ; rien en base avant confirmation');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t1), true) -> 'result' ->> 'client_created')::boolean, 'C5 confirmation : fiche créée');
select pg_temp.ok((select phone = '0712345678' and city = 'Fréjus' from clients where last_name = 'Bernard'), 'C6 fiche créée avec les données saisies (téléphone normalisé)');
create temp table t2 as select eva_propose('client_update', format('{"client_id":"%s","changes":{"phone":"0711111111","city":"Saint-Raphaël"}}', (select id from clients where last_name = 'Bernard'))::jsonb, 'cle-c7-xxxxxx') p;
select pg_temp.ok((select (p ->> 'level')::int = 3 and p -> 'consequences' ? 'Téléphone : « 0712345678 » → « 0711111111 »' and p -> 'consequences' ? 'Ville : « Fréjus » → « Saint-Raphaël »' from t2), 'C7 modification : avant / après affichés, niveau 3');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t2), true) ->> 'status') = 'EXECUTED', 'C8 modification confirmée');
select pg_temp.ok((select phone = '0711111111' and city = 'Saint-Raphaël' from clients where last_name = 'Bernard'), 'C9 fiche réellement modifiée');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('client_update', '{"client_id":"%s","changes":{"user_id":"00000000-0000-0000-0000-000000000000"}}', 'cle-c10-xxxxx')$$, (select id from clients where last_name = 'Bernard'))) like '%non modifiable%', 'C10 champ protégé (compte) non modifiable');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('client_update', '{"client_id":"%s","changes":{"city":"Saint-Raphaël"}}', 'cle-c11-xxxxx')$$, (select id from clients where last_name = 'Bernard'))) like '%Aucune modification%', 'C11 aucune différence : rien à enregistrer');

-- =====================================================================
-- D. Rendez-vous : créer, annuler
-- =====================================================================
select pg_temp.ok(pg_temp.err(format($$select eva_propose('booking_create', '{"client_id":"%s","service_id":"%s","date":"2027-01-13","start":"14:15"}', 'cle-d1-xxxxxx')$$,
  (select id from clients where last_name = 'Bernard'), (select id from services where slug = 'plomberie-mitigeur-lavabo'))) like '%indisponible%', 'D1 créneau occupé (marge de trajet) : refusé');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('booking_create', '{"client_id":"%s","service_id":"%s","date":"2027-01-17","start":"10:00"}', 'cle-d2-xxxxxx')$$,
  (select id from clients where last_name = 'Bernard'), (select id from services where slug = 'plomberie-mitigeur-lavabo'))) like '%indisponible%', 'D2 dimanche (hors horaires) : refusé');
create temp table t3 as select eva_propose('booking_create', format('{"client_id":"%s","service_id":"%s","date":"2027-01-15","start":"10:00","notes":"Accès par le garage"}',
  (select id from clients where last_name = 'Bernard'), (select id from services where slug = 'plomberie-mitigeur-lavabo'))::jsonb, 'cle-d3-xxxxxx') p;
select pg_temp.ok((select p -> 'consequences' ->> 0 like '%Prix : 99,00 €%' and p -> 'consequences' ->> 1 like '%CONFIRMÉ%' from t3), 'D3 proposition : prix du catalogue et conséquences (e-mail, Apple)');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t3), true) -> 'result' ->> 'booking_created')::boolean, 'D4 rendez-vous créé après confirmation');
select pg_temp.ok((select status = 'CONFIRMED' and total_cents = 9900 and guest_phone = '0711111111' and notes = 'Accès par le garage'
                   from bookings where client_id = (select id from clients where last_name = 'Bernard')), 'D5 rendez-vous en base : confirmé, prix catalogue, contact du client sans compte');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('booking_cancel', '{"booking_id":"%s"}', 'cle-d6-xxxxxx')$$, (select id from bookings where date = '2027-01-15'))) like '%Motif%', 'D6 annulation sans motif : refusée');
create temp table t4 as select eva_propose('booking_cancel', format('{"booking_id":"%s","reason_code":"client_injoignable"}', (select id from bookings where date = '2027-01-15'))::jsonb, 'cle-d7-xxxxxx') p;
select pg_temp.ok((select (p ->> 'level')::int = 3 and p -> 'consequences' ->> 0 like '%rien n''est supprimé%' from t4), 'D7 annulation = action engageante, rien supprimé');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t4), true) -> 'result' ->> 'booking_cancelled')::boolean, 'D8 annulation confirmée');
select pg_temp.ok((select status = 'CANCELLED' and cancelled_by = 'admin' and cancellation_type = 'cancelled_admin' and cancellation_reason_code = 'client_injoignable'
                   from bookings where date = '2027-01-15'), 'D9 rendez-vous annulé comme depuis l''administration (motif, auteur)');
create temp table t5 as select pg_temp.do_it('booking_cancel', format('{"booking_id":"%s","reason_code":"autre","detail":"Client a trouvé un autre artisan"}', (select id from bookings where date = '2027-01-14'))::jsonb, 'cle-d10-xxxxx') r;
select pg_temp.ok((select cancellation_type = 'refused' and cancellation_reason_detail = 'Client a trouvé un autre artisan' from bookings where date = '2027-01-14'), 'D10 demande en attente : refus avec motif détaillé');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('booking_cancel', '{"booking_id":"%s","reason_code":"doublon"}', 'cle-d11-xxxxx')$$, (select id from bookings where date = '2027-01-14'))) like '%ne peut pas être annulé%', 'D11 rendez-vous déjà annulé : refus');

-- =====================================================================
-- E. Catalogue : ajouter, publier
-- =====================================================================
select pg_temp.ok(pg_temp.err($$select eva_propose('service_create', '{"name":"Remplacement de siphon","category":"plomberie","mode":"FIXED"}', 'cle-e1-xxxxxx')$$) like '%Prix requis%', 'E1 prestation sans prix : refusée (aucun tarif inventé)');
create temp table t6 as select pg_temp.do_it('service_create', '{"name":"Remplacement de siphon","category":"plomberie","mode":"FIXED","price_cents":6900,"duration_minutes":45}', 'cle-e2-xxxxxx') r;
select pg_temp.ok((select not is_active and base_price_cents = 6900 and duration_minutes = 45 and price_display_mode = 'FIXED' from services where name = 'Remplacement de siphon'), 'E2 prestation créée MASQUÉE au prix saisi');
select pg_temp.ok(not ((eva_query('catalog', '{"query":"siphon"}', null) -> 'data' -> 'items') @> '[{"label":"Remplacement de siphon"}]'), 'E3 prestation masquée : invisible du catalogue client');
select pg_temp.ok(pg_temp.err($$select eva_propose('service_create', '{"name":"Remplacement de siphon","category":"plomberie","mode":"FIXED","price_cents":6900,"duration_minutes":45}', 'cle-e4-xxxxxx')$$) like '%déjà ce nom%', 'E4 doublon de nom refusé');
create temp table t7 as select pg_temp.do_it('service_publish', format('{"service_id":"%s"}', (select id from services where name = 'Remplacement de siphon'))::jsonb, 'cle-e5-xxxxxx') r;
select pg_temp.ok((select is_active from services where name = 'Remplacement de siphon'), 'E5 publication confirmée : prestation visible');
create temp table t8 as select pg_temp.do_it('service_create', '{"name":"Recherche de fuite sur toiture terrasse","category":"plomberie","mode":"QUOTE"}', 'cle-e6-xxxxxx') r;
select pg_temp.ok((select base_price_cents is null and booking_type = 'QUOTE_REQUEST' from services where name = 'Recherche de fuite sur toiture terrasse'), 'E6 prestation « sur devis » : aucun prix');

-- =====================================================================
-- F. Devis : brouillon, modification, envoi
-- =====================================================================
create temp table t9 as select pg_temp.do_it('quote_draft', format('{"client_id":"%s","items":[{"kind":"service","id":"%s"}]}',
  (select id from clients where email = 'martin@test.local'), (select id from services where slug = 'plomberie-mitigeur-lavabo'))::jsonb, 'cle-f1-xxxxxx') r;
select pg_temp.ok((select status = 'DRAFT' and total_cents = 9900 from quotes where client_id = (select id from clients where email = 'martin@test.local')), 'F1 « prépare un devis pour Monsieur Martin » : brouillon au prix catalogue');
create temp table t10 as select eva_propose('quote_update', format('{"quote_id":"%s","supply_cents":4500,"labor_cents":9900,"travel_fee_cents":980,"label":"Mitigeur Grohe + pose"}',
  (select id from quotes where client_id = (select id from clients where email = 'martin@test.local')))::jsonb, 'cle-f2-xxxxxx') p;
select pg_temp.ok((select p -> 'consequences' ->> 0 like '%= 153,80 €%' from t10), 'F2 modification : total recalculé par le serveur (45 + 99 + 9,80 = 153,80 €)');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t10), true) -> 'result' ->> 'total_cents')::int = 15380, 'F3 devis modifié : 153,80 €');
select pg_temp.ok((select o.supply_cents = 4500 and o.labor_cents = 9900 and o.label = 'Mitigeur Grohe + pose' from quotes q join quote_options o on o.id = q.selected_option_id
                   where q.client_id = (select id from clients where email = 'martin@test.local')), 'F4 option du devis mise à jour');
create temp table t11 as select eva_propose('quote_send', format('{"quote_id":"%s"}', (select id from quotes where client_id = (select id from clients where email = 'martin@test.local')))::jsonb, 'cle-f5-xxxxxx') p;
select pg_temp.ok((select (p ->> 'level')::int = 3 and p -> 'consequences' ->> 1 like '%martin@test.local%' from t11), 'F5 envoi = action engageante, destinataire affiché');
select pg_temp.ok((select status = 'DRAFT' from quotes where client_id = (select id from clients where email = 'martin@test.local')), 'F6 rien n''est envoyé avant confirmation');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t11), true) -> 'result' ->> 'reference') ~ '^DEV-[0-9]{4}-[0-9]{4}$', 'F7 devis envoyé : numéro DEV attribué par le serveur');
select pg_temp.ok((select status = 'SENT' and sent_at is not null from quotes where client_id = (select id from clients where email = 'martin@test.local')), 'F8 devis réellement « envoyé » (e-mail par le déclencheur existant)');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('quote_update', '{"quote_id":"%s","labor_cents":1}', 'cle-f9-xxxxxx')$$, (select id from quotes where client_id = (select id from clients where email = 'martin@test.local')))) like '%brouillon%', 'F9 devis envoyé : plus modifiable');
insert into quotes (client_id, reference, status, subtotal_cents, total_cents) select id, 'DV-VIDE', 'DRAFT', 0, 0 from clients where last_name = 'Bernard';
select pg_temp.ok(pg_temp.err(format($$select eva_propose('quote_send', '{"quote_id":"%s"}', 'cle-f10-xxxxx')$$, (select id from quotes where reference = 'DV-VIDE'))) like '%0 €%', 'F10 devis à 0 € : envoi refusé');

-- =====================================================================
-- G. Compte rendu
-- =====================================================================
create temp table t12 as select pg_temp.do_it('report_notes', format('{"booking_id":"%s","observations":"Mitigeur remplacé, essais d''étanchéité conformes.","recommendations":"Prévoir le détartrage du ballon."}',
  (select id from bookings where date = '2027-01-11'))::jsonb, 'cle-g1-xxxxxx') r;
select pg_temp.ok((select observations like 'Mitigeur remplacé%' and recommendations like 'Prévoir%' and report_status = 'DRAFT' from interventions), 'G1 compte rendu préparé (brouillon, non signé)');
update interventions set report_status = 'FINALIZED';
select pg_temp.ok(pg_temp.err(format($$select eva_propose('report_notes', '{"booking_id":"%s","observations":"modif"}', 'cle-g2-xxxxxx')$$, (select id from bookings where date = '2027-01-11'))) like '%validé%', 'G2 compte rendu validé : plus modifiable');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('report_notes', '{"booking_id":"%s","observations":"x"}', 'cle-g3-xxxxxx')$$, (select id from bookings where date = '2027-01-13'))) like '%Aucune fiche%', 'G3 sans fiche d''intervention : refus clair');

-- =====================================================================
-- H. Parrainage et fidélité
-- =====================================================================
create temp table t13 as select pg_temp.do_it('referrer_status', format('{"client_id":"%s","status":"suspended"}', (select id from clients where email = 'martin@test.local'))::jsonb, 'cle-h1-xxxxxx') r;
select pg_temp.ok((select status = 'suspended' from referral_codes where code = 'MARTIN83'), 'H1 parrain suspendu (fonction existante)');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('referrer_code', '{"client_id":"%s","code":"ab"}', 'cle-h2-xxxxxx')$$, (select id from clients where email = 'martin@test.local'))) like '%6 à 12%', 'H2 code invalide refusé');
create temp table t14 as select pg_temp.do_it('referrer_code', format('{"client_id":"%s","code":"paulm83"}', (select id from clients where email = 'martin@test.local'))::jsonb, 'cle-h3-xxxxxx') r;
select pg_temp.ok(exists (select 1 from referral_codes where code = 'PAULM83'), 'H3 code de parrainage changé (fonction existante)');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('wallet_adjust', '{"client_id":"%s","amount_cents":2000}', 'cle-h4-xxxxxx')$$, (select id from clients where email = 'martin@test.local'))) like '%motif%', 'H4 crédit sans motif : refusé');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('wallet_adjust', '{"client_id":"%s","amount_cents":-500,"reason":"test"}', 'cle-h5-xxxxxx')$$, (select id from clients where email = 'martin@test.local'))) like '%insuffisant%', 'H5 débit au-delà du solde : refusé');
create temp table t15 as select pg_temp.do_it('wallet_adjust', format('{"client_id":"%s","amount_cents":2000,"reason":"Geste commercial suite au retard"}', (select id from clients where email = 'martin@test.local'))::jsonb, 'cle-h6-xxxxxx') r;
select pg_temp.ok((select (r -> 'result' ->> 'balance_cents')::int = 2000 from t15), 'H6 crédit fidélité ajouté : solde 20,00 €');
select pg_temp.ok((eva_query('loyalty', '{"client":"Martin"}', null) -> 'data' -> 'transactions' -> 0 ->> 'reason') = 'Geste commercial suite au retard', 'H7 historique fidélité avec motif');

-- =====================================================================
-- I. Agents de phase 2 activables
-- =====================================================================
select eva_set_settings(null, '{"clients": false}');
select pg_temp.ok(pg_temp.err($$select eva_propose('client_create', '{"first_name":"Zoé","phone":"0688776655"}', 'cle-i1-xxxxxx')$$) like '%AGENT_DESACTIVE:clients%', 'I1 agent Clients désactivé : création refusée');
select eva_set_settings(null, '{"clients": true}');
select pg_temp.ok((select count(*) from eva_journal where intent like 'confirm:%' and outcome = 'confirmed') >= 15, 'I2 chaque action confirmée est inscrite au journal');

select pg_temp.as_user(null);
do $$ begin raise notice 'TOUS LES TESTS EVA PHASE 2 SONT PASSÉS'; end $$;
