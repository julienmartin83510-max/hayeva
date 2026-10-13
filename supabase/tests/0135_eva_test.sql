-- Scénarios de test de la migration 0135 (EVA).
-- UNIQUEMENT sur une base locale jetable, avec les données fictives créées ici :
--   psql -d <base_locale> -f supabase/migrations/0135_eva_assistant.sql
--   psql -d <base_locale> -f supabase/tests/0135_eva_test.sql
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
-- Renvoie le message d'erreur d'une instruction (null si elle réussit).
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;

-- Ancienne règle d'horaires (codée en dur jusqu'ici), pour comparaison.
create or replace function pg_temp.old_hours(p_date date, p_start time, p_dur int) returns boolean language sql as $$
  select case extract(dow from p_date)::int
    when 0 then false
    when 6 then p_start >= time '08:00' and (p_start + (p_dur * interval '1 minute')) <= time '12:00'
    else ((p_start >= time '08:00' and (p_start + (p_dur * interval '1 minute')) <= time '13:00')
       or (p_start >= time '14:00' and (p_start + (p_dur * interval '1 minute')) <= time '18:00')) end
$$;

insert into vault.secrets (name, secret) values ('webhook_secret', 'local-test-secret') on conflict (name) do nothing;
update booking_settings set opening_date = date '2027-01-02' where id = 1;

-- Comptes fictifs : un administrateur, deux clients.
do $$ declare u record; begin
  for u in select * from (values
    ('00000000-0000-0000-0000-0000000000a1'::uuid, 'admin@test.local', 'admin', 'Ada', 'Admin', '0600000001', '1 rue Admin, 83600 Fréjus'),
    ('00000000-0000-0000-0000-0000000000b1'::uuid, 'dupont@test.local', 'customer', 'Jean', 'Dupont', '0611223344', '5 rue des Pins, 83700 Saint-Raphaël'),
    ('00000000-0000-0000-0000-0000000000b2'::uuid, 'lefevre@test.local', 'customer', 'Élodie', 'Lefèvre', '0655667788', '9 bd Mer, 83600 Fréjus')) v(id, email, role, fn, ln, ph, addr) loop
    insert into auth.users (id, email) values (u.id, u.email) on conflict do nothing;
    insert into profiles (user_id, email, global_role) values (u.id, u.email, u.role) on conflict (user_id) do update set global_role = excluded.global_role;
    insert into customer_profiles (user_id, first_name, last_name, phone) values (u.id, u.fn, u.ln, u.ph) on conflict (user_id) do nothing;
    perform find_or_create_client(u.id, u.email, u.ph, u.fn, u.ln, u.addr);
  end loop;
end $$;
update clients set city = 'Saint-Raphaël' where email = 'dupont@test.local';

\set ADMIN '\'00000000-0000-0000-0000-0000000000a1\''
\set DUPONT '\'00000000-0000-0000-0000-0000000000b1\''

-- =====================================================================
-- A. Sécurité
-- =====================================================================
select pg_temp.as_user(null);
select pg_temp.ok(pg_temp.err($$select eva_run('agenda', '{}', null)$$) is not null, 'A1 visiteur anonyme : EVA refusée');
select pg_temp.as_user(:DUPONT);
select pg_temp.ok(pg_temp.err($$select eva_run('agenda', '{}', null)$$) like '%réservée%', 'A2 client connecté : EVA refusée');
select pg_temp.ok(pg_temp.err($$select eva_propose('quote_draft', '{}', 'cle-client-001')$$) is not null, 'A3 client connecté : aucune proposition possible');
select pg_temp.ok(pg_temp.err($$select eva_overview()$$) is not null, 'A4 client connecté : tableau de bord EVA refusé');
select pg_temp.ok(pg_temp.err($$select admin_set_work_hours('{}', 30)$$) is not null, 'A5 client connecté : horaires non modifiables');
select pg_temp.ok(pg_temp.err($$select admin_confirm_vat_regime('franchise_base', null)$$) is not null, 'A6 client connecté : TVA non modifiable');
set role authenticated;
select pg_temp.ok((select count(*) from eva_journal) = 0 and (select count(*) from eva_proposals) = 0, 'A7 client connecté : journal et propositions invisibles');
select pg_temp.ok(pg_temp.err($$select _eva_agenda(current_date)$$) like '%permission%', 'A8 fonctions internes des agents inaccessibles');
select pg_temp.ok(pg_temp.err($$select _eva_find_client('dupont')$$) like '%permission%', 'A9 recherche de client interne inaccessible');
reset role;
select pg_temp.ok(not has_function_privilege('anon', 'public.eva_run(text, jsonb, text)', 'execute'), 'A10 anon sans droit d''exécution sur eva_run');

-- =====================================================================
-- B. Horaires réglables : défaut identique à l'ancienne règle
-- =====================================================================
select pg_temp.ok(not exists (
  select 1 from generate_series(date '2027-01-11', date '2027-01-17', interval '1 day') d,
                (select time '06:00' + g * interval '15 minutes' t from generate_series(0, 56) g) tt, unnest(array[30, 60, 90, 240]) dur
   where tt.t + dur * interval '1 minute' > tt.t  -- hors passage à minuit (voir B1b)
     and is_slot_within_business_hours(d::date, tt.t, dur) is distinct from pg_temp.old_hours(d::date, tt.t, dur)),
  'B1 horaires par défaut identiques à l''ancienne règle (7 jours × 57 heures × 4 durées)');
select pg_temp.ok(pg_temp.old_hours(date '2027-01-11', time '20:00', 240) and not is_slot_within_business_hours(date '2027-01-11', time '20:00', 240),
  'B1b défaut corrigé : l''ancienne règle acceptait 20 h + 4 h (passage à minuit), la nouvelle le refuse');
select pg_temp.ok((select travel_margin_minutes from booking_settings where id = 1) = 30, 'B2 marge de trajet par défaut : 30 min');
select pg_temp.ok((get_public_booking_settings() -> 'work_hours' -> '7') = '[]'::jsonb, 'B3 le site reçoit les horaires (dimanche fermé)');
select pg_temp.as_user(:ADMIN);
select pg_temp.ok(pg_temp.err($$select admin_set_work_hours('{"1":[["14:00","13:00"]],"2":[],"3":[],"4":[],"5":[],"6":[],"7":[]}', 30)$$) like '%Horaires invalides%', 'B4 plage inversée refusée');
select pg_temp.ok(pg_temp.err($$select admin_set_work_hours('{"1":[["08:00","13:00"],["12:00","18:00"]],"2":[],"3":[],"4":[],"5":[],"6":[],"7":[]}', 30)$$) like '%Horaires invalides%', 'B5 plages qui se chevauchent refusées');
select pg_temp.ok(pg_temp.err($$select admin_set_work_hours('{"1":[]}', 30)$$) like '%Horaires invalides%', 'B6 jour manquant refusé');
select pg_temp.ok(pg_temp.err($$select admin_set_work_hours((select work_hours from booking_settings), 500)$$) like '%Marge%', 'B7 marge hors limites refusée');
select admin_set_work_hours(jsonb_set((select work_hours from booking_settings), '{7}', '[["09:00","12:00"]]'), 45);
select pg_temp.ok(is_slot_within_business_hours(date '2027-01-17', time '09:00', 60), 'B8 dimanche ouvert après réglage : créneau accepté');
select pg_temp.ok((select travel_margin_minutes from booking_settings) = 45, 'B9 marge de trajet modifiée');
select admin_set_work_hours(jsonb_set((select work_hours from booking_settings), '{7}', '[]'), 30);
select pg_temp.ok(not is_slot_within_business_hours(date '2027-01-17', time '09:00', 60), 'B10 réglage remis : dimanche fermé');

-- =====================================================================
-- C. Données fictives de planning (mardi 12 janvier 2027)
-- =====================================================================
select pg_temp.as_user(:ADMIN);
insert into bookings (customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents, one_way_distance_km)
select '00000000-0000-0000-0000-0000000000b1', (select id from clients where email = 'dupont@test.local'), (select id from services where slug = 'plomberie-mitigeur-lavabo'),
       date '2027-01-12', time '08:30', 'CONFIRMED', 60, 9900, 9900, 32;
insert into bookings (customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select '00000000-0000-0000-0000-0000000000b2', (select id from clients where email = 'lefevre@test.local'), (select id from services where slug = 'plomberie-robinet-arret'),
       date '2027-01-12', time '09:45', 'PENDING', 45, 8900, 8900;
insert into bookings (customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select '00000000-0000-0000-0000-0000000000b2', (select id from clients where email = 'lefevre@test.local'), (select id from services where slug = 'plomberie-mitigeur-douche'),
       date '2027-01-12', time '14:00', 'CONFIRMED', 60, 12900, 12900;
-- Indisponibilité Apple (bloquante) de 16 h à 17 h.
insert into calendar_connections (provider, connected) select 'icloud', true where not exists (select 1 from calendar_connections);
insert into calendar_blocking_sources (connection_id, calendar_url, display_name, is_blocking)
select (select id from calendar_connections limit 1), 'https://caldav.test/perso', 'Perso (test)', true;
insert into external_busy_blocks (source_id, external_uid, starts_at, ends_at, is_all_day)
select (select id from calendar_blocking_sources where display_name = 'Perso (test)'), 'uid-test-1',
       (timestamp '2027-01-12 16:00') at time zone 'Europe/Paris', (timestamp '2027-01-12 17:00') at time zone 'Europe/Paris', false;

-- =====================================================================
-- D. Agent Planning
-- =====================================================================
select pg_temp.ok((eva_run('agenda', '{"date":"2027-01-12"}', 'EVA, montre-moi mes interventions du 12 janvier') -> 'data' -> 'interventions') @> '[{"start":"08:30","client":"Jean Dupont"}]', 'D1 agenda : intervention réelle de Jean Dupont à 08:30');
select pg_temp.ok(jsonb_array_length(eva_run('agenda', '{"date":"2027-01-12"}', null) -> 'data' -> 'interventions') = 3, 'D2 agenda : 3 interventions (statuts actifs uniquement)');
select pg_temp.ok((eva_run('agenda', '{"date":"2027-01-12"}', null) -> 'data' -> 'warnings') @> '[{"type":"trajet"}]', 'D3 agenda : 15 min entre deux interventions signalées (marge 30 min)');
select pg_temp.ok((eva_run('agenda', '{"date":"2027-01-12"}', null) -> 'data' -> 'busy_blocks') @> '[{"start":"16:00","end":"17:00"}]', 'D4 agenda : indisponibilité Apple affichée');
select pg_temp.ok((eva_run('agenda', '{"date":"2027-01-13"}', null) ->> 'empty')::boolean, 'D5 journée sans intervention : résultat vide signalé');
select pg_temp.ok(not ((eva_run('free_slots', '{"from":"2027-01-12","to":"2027-01-12","duration":60}', null) -> 'data' -> 'slots') @> '[{"start":"10:30"}]'), 'D6 créneaux : 10:30 exclu (fin à 10:30 + marge de trajet)');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(eva_run('free_slots', '{"from":"2027-01-12","to":"2027-01-12","duration":60}', null) -> 'data' -> 'slots') s
                              where (s ->> 'start') between '15:30' and '16:59'), 'D7 créneaux : aucun créneau sur l''indisponibilité Apple');
select pg_temp.ok((eva_run('free_slots', '{"from":"2027-01-12","to":"2027-01-12","duration":60}', null) -> 'data' -> 'slots') @> '[{"start":"11:00"}]', 'D8 créneaux : 11:00 proposé (marge respectée)');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(eva_run('free_slots', '{"from":"2027-01-17","to":"2027-01-17"}', null) -> 'data' -> 'slots')), 'D9 créneaux : aucun le dimanche');
select pg_temp.ok((eva_run('conflicts', '{"from":"2027-01-11","to":"2027-01-17"}', null) -> 'data' -> 'conflicts') @> '[{"type":"trajet"}]', 'D10 conflits : marge de trajet insuffisante détectée');
select pg_temp.ok(pg_temp.err($$select eva_run('free_slots', '{"from":"2027-01-12","to":"2027-06-12"}', null)$$) like '%PERIODE_INVALIDE%', 'D11 période trop longue refusée');
select pg_temp.ok(pg_temp.err($$select eva_run('agenda', '{"date":"pas une date"}', null)$$) like '%DATE_INVALIDE%', 'D12 date invalide refusée');
select pg_temp.ok(pg_temp.err($$select eva_run('supprimer_tout', '{}', null)$$) like '%INTENTION_INCONNUE%', 'D13 intention hors liste refusée');

-- =====================================================================
-- E. Recherche de client et agent Devis
-- =====================================================================
select pg_temp.ok((eva_run('find_client', '{"query":"Monsieur Dupont"}', null) -> 'data' -> 'clients') @> '[{"name":"Jean Dupont"}]', 'E1 « Monsieur Dupont » → Jean Dupont');
select pg_temp.ok((eva_run('find_client', '{"query":"lefevre"}', null) -> 'data' -> 'clients') @> '[{"name":"Élodie Lefèvre"}]', 'E2 recherche sans accent → Élodie Lefèvre');
select pg_temp.ok((eva_run('find_client', '{"query":"Martinez"}', null) ->> 'empty')::boolean, 'E3 client inexistant : aucun résultat, rien d''inventé');
select pg_temp.ok((eva_run('quote_estimate', '{"client":"Dupont","service":"remplacement du mitigeur lavabo"}', null) -> 'data' -> 'matches' -> 0 ->> 'price_cents')::int
                  = (select base_price_cents from services where slug = 'plomberie-mitigeur-lavabo'), 'E4 devis : prix lu dans le catalogue (mitigeur lavabo)');
select pg_temp.ok((eva_run('quote_estimate', '{"client":"Dupont","service":"mitigeur lavabo"}', null) -> 'data' ->> 'travel_fee_cents')::int = (select fee_cents from compute_travel_fee_cents(32, false)), 'E5 devis : déplacement calculé par la règle existante (32 km)');
select pg_temp.ok((eva_run('quote_estimate', '{"client":"Lefevre","service":"mitigeur lavabo"}', null) -> 'data' -> 'missing') @> '["Distance du chantier inconnue : frais de déplacement non calculés."]', 'E6 devis : distance inconnue signalée, pas de déplacement inventé');
select pg_temp.ok((select bool_and(m ->> 'price_cents' is null) from jsonb_array_elements(eva_run('quote_estimate', '{"service":"recherche de fuite encastree"}', null) -> 'data' -> 'matches') m
                    where m ->> 'mode' <> 'FIXED'), 'E7 devis : prestation « sur devis » sans montant');
select pg_temp.ok((eva_run('quote_estimate', '{"service":"pose de panneaux solaires"}', null) -> 'data' -> 'missing') @> '["Prestation introuvable dans le catalogue : hors catalogue, à chiffrer par vous."]', 'E8 hors catalogue : votre intervention demandée');

-- Proposition de brouillon de devis.
select pg_temp.ok(pg_temp.err(format($$select eva_propose('quote_draft', '{"client_id":"%s","items":[{"kind":"service","id":"%s"}]}', 'cle-devis-sur-devis')$$,
  (select id from clients where email = 'dupont@test.local'), (select id from services where slug = 'plomberie-fuite-encastree'))) like '%pas de prix fixe%', 'E9 brouillon refusé pour une prestation sans prix fixe');
create temp table t_prop as select eva_propose('quote_draft', format('{"client_id":"%s","items":[{"kind":"service","id":"%s"}],"distance_km":32}',
  (select id from clients where email = 'dupont@test.local'), (select id from services where slug = 'plomberie-mitigeur-lavabo'))::jsonb, 'cle-devis-dupont-001') p;
select pg_temp.ok((select (p ->> 'level')::int = 2 and p -> 'consequences' ->> 2 like 'Rien n''est envoyé%' from t_prop), 'E10 proposition niveau 2 avec conséquences affichées');
select pg_temp.ok((select (p -> 'payload' ->> 'total_cents')::int = 9900 + (select fee_cents from compute_travel_fee_cents(32, false)) from t_prop), 'E11 total calculé par le serveur = catalogue + déplacement');
select pg_temp.ok((select count(*) from quotes where title like 'Remplacement mitigeur lavabo%') = 0, 'E12 aucun devis créé avant confirmation');
select pg_temp.ok(pg_temp.err(format($$select eva_confirm_proposal('%s', false)$$, (select p ->> 'proposal_id' from t_prop))) like '%CONFIRMATION_REQUISE%', 'E13 confirmation non explicite refusée');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_prop), true) ->> 'status') = 'EXECUTED', 'E14 confirmation explicite : brouillon créé');
select pg_temp.ok((select status = 'DRAFT' and total_cents = 9900 + (select fee_cents from compute_travel_fee_cents(32, false)) and sent_at is null from quotes where title like 'Remplacement mitigeur lavabo%'), 'E15 devis en BROUILLON, montant exact, non envoyé');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_prop), true) ->> 'duplicate')::boolean
                  and (select count(*) from quotes where title like 'Remplacement mitigeur lavabo%') = 1, 'E16 double confirmation : aucun doublon');
select pg_temp.ok((eva_propose('quote_draft', '{}', 'cle-devis-dupont-001') ->> 'duplicate')::boolean, 'E17 même demande renvoyée : même proposition rendue');

-- =====================================================================
-- F. Agent Factures + TVA
-- =====================================================================
update bookings set status = 'COMPLETED' where start_time = time '08:30' and date = date '2027-01-12';
select pg_temp.ok((eva_run('invoices_todo', '{}', null) -> 'data' -> 'completed_without_invoice') @> '[{"client":"Jean Dupont"}]', 'F1 intervention terminée sans facture détectée');
select pg_temp.ok((eva_run('invoices_todo', '{}', null) -> 'data' ->> 'vat_confirmed')::boolean is false, 'F2 régime de TVA signalé non confirmé');
create temp table t_inv as select eva_propose('invoice_draft', format('{"source":"booking","id":"%s"}',
  (select id from bookings where date = '2027-01-12' and start_time = '08:30'))::jsonb, 'cle-facture-dupont-1') p;
select pg_temp.ok((select p -> 'consequences' ->> 1 like 'Aucun numéro définitif%' from t_inv), 'F3 conséquences : brouillon, ni émission ni envoi');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('invoice_draft', '{"source":"booking","id":"%s"}', 'cle-facture-dupont-2')$$,
  (select id from bookings where date = '2027-01-12' and start_time = '08:30'))) like '%DOSSIER_OCCUPE%', 'F4 deux propositions sur le même dossier : refusé');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_inv), true) ->> 'status') = 'EXECUTED', 'F5 brouillon de facture créé');
select pg_temp.ok((select count(*) = 1 and bool_and(status = 'DRAFT' and issued_at is null) from invoices where booking_id = (select id from bookings where date = '2027-01-12' and start_time = '08:30')), 'F6 facture en BROUILLON, non émise');
create temp table t_inv2 as select eva_propose('invoice_draft', format('{"source":"booking","id":"%s"}',
  (select id from bookings where date = '2027-01-12' and start_time = '08:30'))::jsonb, 'cle-facture-dupont-3') p;
select eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_inv2), true);
select pg_temp.ok((select count(*) from invoices where booking_id = (select id from bookings where date = '2027-01-12' and start_time = '08:30')) = 1, 'F7 nouvelle tentative : pas de seconde facture');
select pg_temp.ok((select count(*) from invoice_payments) = 0 and (select paid_at is null from invoices where booking_id = (select id from bookings where date = '2027-01-12' and start_time = '08:30')), 'F8 aucun paiement inventé');
-- Identité légale complète mais TVA non confirmée : facturation définitive bloquée.
update company_settings set trade_name = 'HAYEVA', legal_name = 'HAYEVA TEST', owner_name = 'Test', address_line1 = '1 rue du Test', postal_code = '83600', city = 'Fréjus',
  siret = '12345678900011', vat_regime = 'franchise_base', insurance_company = 'Assureur', insurance_contract_number = 'C-1', mediator_name = 'Médiateur' where id = 1;
select pg_temp.ok(not company_billing_ready(), 'F9 identité complète mais TVA non confirmée : facturation définitive bloquée');
select pg_temp.ok(pg_temp.err(format($$select admin_issue_invoice('%s', null)$$, (select id from invoices where status = 'DRAFT' and booking_id is not null limit 1))) like '%informations légales%', 'F10 émission de facture refusée tant que la TVA n''est pas confirmée');
select pg_temp.ok(pg_temp.err($$select admin_confirm_vat_regime('assujetti', null)$$) like '%Taux%', 'F11 assujetti sans taux : refusé');
select admin_confirm_vat_regime('franchise_base', null);
select pg_temp.ok(company_billing_ready(), 'F12 franchise en base confirmée : facturation possible');
update company_settings set vat_regime = 'assujetti', default_vat_rate = 20, vat_number = 'FR00123456789' where id = 1;
select pg_temp.ok(not company_billing_ready() and (select vat_regime_confirmed_at is null from company_settings), 'F13 changement de régime : confirmation annulée automatiquement');
select admin_confirm_vat_regime('franchise_base', null);

-- =====================================================================
-- G. Planning : déplacement (niveau 3), annulation, échec d'agent
-- =====================================================================
select pg_temp.ok(pg_temp.err(format($$select eva_propose('reschedule', '{"booking_id":"%s","date":"2027-01-12","start":"16:00"}', 'cle-move-busy')$$,
  (select id from bookings where date = '2027-01-12' and start_time = '14:00'))) like '%indisponible%', 'G1 déplacement vers une indisponibilité Apple : refusé');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('reschedule', '{"booking_id":"%s","date":"2027-01-12","start":"10:15"}', 'cle-move-tight')$$,
  (select id from bookings where date = '2027-01-12' and start_time = '14:00'))) like '%indisponible%', 'G2 déplacement sans marge de trajet : refusé');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('reschedule', '{"booking_id":"%s","date":"2027-01-17","start":"10:00"}', 'cle-move-sunday')$$,
  (select id from bookings where date = '2027-01-12' and start_time = '14:00'))) like '%indisponible%', 'G3 déplacement un dimanche (hors horaires) : refusé');
create temp table t_mv as select eva_propose('reschedule', format('{"booking_id":"%s","date":"2027-01-14","start":"10:00"}',
  (select id from bookings where date = '2027-01-12' and start_time = '14:00'))::jsonb, 'cle-move-ok') p;
select pg_temp.ok((select (p ->> 'level')::int = 3 and p -> 'consequences' ->> 1 like '%client est prévenu%' from t_mv), 'G4 déplacement = niveau 3, conséquences affichées (client prévenu)');
select pg_temp.ok((select date = '2027-01-12' from bookings where id = (select (p -> 'payload' ->> 'booking_id')::uuid from t_mv)), 'G5 rien n''est déplacé avant confirmation');
select pg_temp.ok((eva_cancel_proposal((select (p ->> 'proposal_id')::uuid from t_mv)) ->> 'status') = 'CANCELLED', 'G6 annulation de la proposition');
select pg_temp.ok(pg_temp.err(format($$select eva_confirm_proposal('%s', true)$$, (select p ->> 'proposal_id' from t_mv))) like '%déjà traitée%', 'G7 proposition annulée : confirmation impossible');
select pg_temp.ok((select date = '2027-01-12' from bookings where id = (select (p -> 'payload' ->> 'booking_id')::uuid from t_mv)), 'G8 rendez-vous inchangé après annulation');
create temp table t_mv2 as select eva_propose('reschedule', format('{"booking_id":"%s","date":"2027-01-14","start":"10:00"}',
  (select id from bookings where date = '2027-01-12' and start_time = '14:00'))::jsonb, 'cle-move-ok-2') p;
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_mv2), true) ->> 'status') = 'EXECUTED', 'G9 déplacement confirmé : exécuté par admin_reschedule_booking');
select pg_temp.ok((select date = '2027-01-14' and start_time = '10:00' from bookings where id = (select (p -> 'payload' ->> 'booking_id')::uuid from t_mv2)), 'G10 rendez-vous réellement déplacé');
-- Échec contrôlé : la situation change entre la proposition et la confirmation.
create temp table t_fail as select eva_propose('reschedule', format('{"booking_id":"%s","date":"2027-01-15","start":"09:00"}',
  (select id from bookings where date = '2027-01-12' and start_time = '09:45'))::jsonb, 'cle-move-fail') p;
insert into bookings (customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select '00000000-0000-0000-0000-0000000000b1', (select id from clients where email = 'dupont@test.local'), (select id from services where slug = 'plomberie-robinet-arret'),
       date '2027-01-15', time '09:00', 'CONFIRMED', 45, 8900, 8900;
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_fail), true) ->> 'status') = 'FAILED', 'G11 créneau pris entre-temps : échec contrôlé, rien n''est forcé');
select pg_temp.ok((select status = 'FAILED' and error like '%plus disponible%' from eva_proposals where idem_key = 'cle-move-fail'), 'G12 échec enregistré avec son motif');
select pg_temp.ok((select date = '2027-01-12' from bookings where id = (select (p -> 'payload' ->> 'booking_id')::uuid from t_fail)), 'G13 rendez-vous inchangé après l''échec');

-- =====================================================================
-- H. Réglages, attention, journal, limites
-- =====================================================================
select eva_set_settings(null, '{"factures": false}');
select pg_temp.ok(pg_temp.err($$select eva_run('invoices_todo', '{}', null)$$) like '%AGENT_DESACTIVE%', 'H1 agent Factures désactivé : refusé');
select pg_temp.ok((eva_run('brief', '{"date":"2027-01-12"}', null) -> 'data' -> 'invoices') = 'null'::jsonb, 'H2 synthèse sans l''agent désactivé');
select eva_set_settings(null, '{"factures": true}');
select pg_temp.ok(pg_temp.err($$select eva_set_settings(null, '{"pirate": true}')$$) like '%invalide%', 'H3 agent inconnu refusé');
select pg_temp.ok(jsonb_array_length(eva_run('attention', '{}', null) -> 'data' -> 'items') >= 1, 'H4 points d''attention calculés');
select pg_temp.ok((eva_run('brief', '{"date":"2027-01-12"}', null) -> 'data' -> 'agenda' -> 'interventions') is not null, 'H5 « prépare ma journée » : synthèse planning + devis + factures + attention');
select pg_temp.ok((select count(*) from eva_journal where command like 'EVA, montre-moi%') = 1, 'H6 commande enregistrée dans le journal');
select pg_temp.ok((eva_overview() -> 'proposals') @> '[{"status":"EXECUTED"}]' and (eva_overview() -> 'journal') is not null, 'H7 tableau de bord : propositions et historique');
insert into eva_journal (actor_user_id, intent, outcome) select '00000000-0000-0000-0000-0000000000a1', 'test', 'ok' from generate_series(1, 60);
select pg_temp.ok(pg_temp.err($$select eva_run('agenda', '{}', null)$$) like '%TROP_DE_DEMANDES%', 'H8 limite de débit appliquée');
delete from eva_journal where intent = 'test';
select eva_set_settings(false, '{}');
select pg_temp.ok(pg_temp.err($$select eva_run('agenda', '{}', null)$$) like '%EVA_DESACTIVEE%', 'H9 interrupteur général : EVA coupée');
select eva_set_settings(true, '{}');

-- =====================================================================
-- I. Nouvelles capacités : registre, finances, devis d'un client, demandes
--    en attente, confirmation de RDV, émission, paiement, évolutions
-- =====================================================================
select eva_set_settings(true, '{"planning": true, "devis": true, "factures": true}');
select pg_temp.ok((select count(*) from jsonb_array_elements(eva_run('capabilities', '{}', null) -> 'data' -> 'tools') t where t ->> 'status' = 'disponible') >= 15
  and (eva_run('capabilities', '{}', null) -> 'data' -> 'tools') @> '[{"status":"a_developper"},{"status":"non_realisable"}]', 'I1 registre des capacités : disponibles / à développer / non réalisables');
insert into quotes (client_id, customer_user_id, reference, status, title, subtotal_cents, total_cents, sent_at, created_at)
select (select id from clients where email = 'dupont@test.local'), '00000000-0000-0000-0000-0000000000b1', 'DEV-2027-0007', 'SENT', 'Remplacement chauffe-eau', 89000, 89000, now() - interval '3 days', now() - interval '4 days';
select pg_temp.ok((eva_run('client_quotes', '{"client":"Monsieur Dupont"}', null) -> 'data' -> 'quotes') @> '[{"reference":"DEV-2027-0007"}]'
  and (eva_run('client_quotes', '{"client":"Monsieur Dupont"}', null) -> 'data' -> 'quotes' -> 0 ->> 'quote_id')
      = (select id::text from quotes where client_id = (select id from clients where email = 'dupont@test.local') order by created_at desc limit 1),
  'I2 « dernier devis de Monsieur Dupont » : tous ses devis, le plus récent en premier');
select pg_temp.ok((eva_run('client_quotes', '{"client":"Inconnu Personne"}', null) ->> 'empty')::boolean, 'I3 devis d''un client inexistant : rien d''inventé');
insert into bookings (customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select '00000000-0000-0000-0000-0000000000b2', (select id from clients where email = 'lefevre@test.local'), (select id from services where slug = 'plomberie-robinet-arret'),
       date '2027-01-19', time '09:00', 'PENDING', 45, 8900, 8900;
select pg_temp.ok((eva_run('awaiting', '{}', null) -> 'data' -> 'booking_requests') @> '[{"client":"Élodie Lefèvre","start":"09:00"}]', 'I4 « quels clients attendent une réponse » : demandes de RDV en attente');
create temp table t_conf as select eva_propose('booking_confirm', format('{"booking_id":"%s"}', (select id from bookings where date = '2027-01-19' and start_time = '09:00'))::jsonb, 'cle-confirm-1') p;
select pg_temp.ok((select (p ->> 'level')::int = 3 and p -> 'consequences' ->> 1 like '%e-mail%' from t_conf), 'I5 confirmation de RDV = action engageante, e-mail client annoncé');
select pg_temp.ok((select status = 'PENDING' from bookings where date = '2027-01-19' and start_time = '09:00'), 'I6 statut inchangé avant confirmation');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_conf), true) ->> 'status') = 'EXECUTED', 'I7 confirmation exécutée');
select pg_temp.ok((select status = 'CONFIRMED' from bookings where date = '2027-01-19' and start_time = '09:00'), 'I7b RDV réellement confirmé en base');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('booking_confirm', '{"booking_id":"%s"}', 'cle-confirm-2')$$, (select id from bookings where date = '2027-01-19' and start_time = '09:00'))) like '%déjà été traitée%', 'I8 demande déjà confirmée : refus');
select pg_temp.ok((eva_run('last_intervention', '{}', null) -> 'data' ->> 'client') = 'Jean Dupont'
  and (eva_run('last_intervention', '{}', null) -> 'data' -> 'invoice' ->> 'status') = 'DRAFT', 'I9 dernière intervention terminée + son brouillon de facture');
-- Émission (identité complète et TVA confirmée plus haut : franchise en base).
create temp table t_iss as select eva_propose('invoice_issue', format('{"invoice_id":"%s"}', (select id from invoices where status = 'DRAFT' and booking_id is not null limit 1))::jsonb, 'cle-issue-1') p;
select pg_temp.ok((select p -> 'consequences' ->> 1 like '%ne pourra plus être modifiée%' from t_iss), 'I10 émission : conséquences (définitive, correction par avoir)');
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_iss), true) -> 'result' ->> 'reference') ~ '^FAC-[0-9]{4}-[0-9]{4}$', 'I11 facture émise : numéro FAC attribué par le serveur');
select pg_temp.ok((select status = 'ISSUED' and issued_at is not null from invoices where id = (select (p -> 'payload' ->> 'invoice_id')::uuid from t_iss)), 'I12 facture réellement émise en base');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('invoice_payment', '{"invoice_id":"%s","amount_cents":0,"method":"virement","paid_on":"2026-01-01"}', 'cle-pay-0')$$, (select p -> 'payload' ->> 'invoice_id' from t_iss))) like '%Montant%', 'I13 paiement sans montant : refusé');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('invoice_payment', '{"invoice_id":"%s","amount_cents":1000,"method":"bitcoin","paid_on":"2026-01-01"}', 'cle-pay-1')$$, (select p -> 'payload' ->> 'invoice_id' from t_iss))) like '%Moyen%', 'I14 moyen de paiement inconnu : refusé');
select pg_temp.ok(pg_temp.err(format($$select eva_propose('invoice_payment', '{"invoice_id":"%s","amount_cents":1000,"method":"virement","paid_on":"2099-01-01"}', 'cle-pay-2')$$, (select p -> 'payload' ->> 'invoice_id' from t_iss))) like '%Date%', 'I15 paiement daté dans le futur : refusé');
create temp table t_pay as select eva_propose('invoice_payment', format('{"invoice_id":"%s","amount_cents":%s,"method":"virement","paid_on":"%s"}',
  (select p -> 'payload' ->> 'invoice_id' from t_iss), (select total_cents from invoices where id = (select (p -> 'payload' ->> 'invoice_id')::uuid from t_iss)), current_date)::jsonb, 'cle-pay-ok') p;
select pg_temp.ok((eva_confirm_proposal((select (p ->> 'proposal_id')::uuid from t_pay), true) -> 'result' ->> 'invoice_status') = 'PAID', 'I16 paiement enregistré : facture « Payée »');
select pg_temp.ok((eva_run('finance', format('{"from":"%s","to":"%s"}', current_date - 6, current_date)::jsonb, null) -> 'data' ->> 'collected_cents')::int
  = (select total_cents from invoices where id = (select (p -> 'payload' ->> 'invoice_id')::uuid from t_iss)), 'I17 « combien j''ai encaissé cette semaine » : montant exact des paiements enregistrés');
select pg_temp.ok((eva_run('finance', format('{"from":"%s","to":"%s"}', current_date - 6, current_date)::jsonb, null) -> 'data' ->> 'invoiced_count')::int = 1, 'I18 facturé cette semaine : 1 facture émise');
select pg_temp.ok((eva_add_dev_request('Ajouter un export Excel des interventions du mois') ->> 'ok')::boolean, 'I19 demande d''évolution enregistrée');
select pg_temp.ok((eva_add_dev_request('Ajouter un export Excel des interventions du mois') ->> 'request_id') = (select id::text from eva_dev_requests limit 1)
  and (select count(*) from eva_dev_requests) = 1, 'I20 même demande répétée : pas de doublon');
select pg_temp.ok((eva_overview() -> 'dev_requests') @> '[{"status":"NOUVELLE"}]', 'I21 demandes d''évolution visibles dans EVA');
select pg_temp.as_user(:DUPONT);
select pg_temp.ok(pg_temp.err($$select eva_add_dev_request('pirater le site')$$) like '%réservée%', 'I22 client connecté : aucune demande d''évolution possible');
select pg_temp.ok(pg_temp.err($$select eva_run('finance', '{}', null)$$) like '%réservée%', 'I23 client connecté : finances refusées');

-- =====================================================================
-- J. TVA : un brouillon préparé avant confirmation n'utilise jamais un taux non confirmé
-- =====================================================================
select pg_temp.as_user(:ADMIN);
update company_settings set vat_regime = 'assujetti', default_vat_rate = 20 where id = 1;
select pg_temp.ok((select vat_regime_confirmed_at is null from company_settings) and not company_billing_ready(), 'J1 régime « assujetti 20 % » saisi mais non confirmé : facturation bloquée');
insert into bookings (customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select :DUPONT::uuid, (select id from clients where email = 'dupont@test.local'), (select id from services where slug = 'plomberie-mitigeur-lavabo'), date '2027-01-20', time '15:00', 'CONFIRMED', 60, 12000, 12000;
update bookings set status = 'COMPLETED' where date = '2027-01-20' and start_time = '15:00';
create temp table t_vat as select admin_create_invoice('booking', (select id from bookings where date = '2027-01-20' and start_time = '15:00')) r;
create temp table t_vat_inv as select id from invoices where booking_id = (select id from bookings where date = '2027-01-20' and start_time = '15:00');
insert into invoice_lines (invoice_id, position, kind, label, unit_ttc_cents, vat_rate) select id, 9, 'fourniture', 'Ligne saisie à 5,5 %', 1000, 5.5 from t_vat_inv;
select pg_temp.ok((select bool_or(vat_rate = 20) from invoice_lines where invoice_id = (select id from t_vat_inv)), 'J2 brouillon préparé au taux par défaut non confirmé (20 %)');
create temp table t_vatconf as select admin_confirm_vat_regime('assujetti', 10) r;
select pg_temp.ok((select (r ->> 'drafts_realigned')::int >= 1 from t_vatconf), 'J3 confirmation « assujetti 10 % » : brouillons réalignés');
select pg_temp.ok(not exists (select 1 from invoice_lines where invoice_id = (select id from t_vat_inv) and vat_rate = 20), 'J4 plus aucune ligne au taux non confirmé (20 %)');
select pg_temp.ok(exists (select 1 from invoice_lines where invoice_id = (select id from t_vat_inv) and vat_rate = 5.5), 'J5 taux saisi à la main sur une ligne : conservé');
select pg_temp.ok((select count(*) = 0 from invoices i join invoice_lines l on l.invoice_id = i.id where i.status <> 'DRAFT' and l.vat_rate = 10), 'J6 factures émises : jamais modifiées');
select admin_confirm_vat_regime('franchise_base', null);

select pg_temp.as_user(null);
do $$ begin raise notice 'TOUS LES TESTS EVA SONT PASSÉS'; end $$;
