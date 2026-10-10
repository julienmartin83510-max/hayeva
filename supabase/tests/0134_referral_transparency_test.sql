-- Scénarios de test de la migration 0134 (parrainage : transparence et justificatifs).
-- À exécuter UNIQUEMENT sur une base locale jetable (données fictives créées ici) :
--   psql -d <base_locale> -f supabase/migrations/0134_referral_transparency_documents.sql
--   psql -d <base_locale> -f supabase/tests/0134_referral_transparency_test.sql
-- Jamais sur la base de production.
-- Tests locaux de 0134 (base jetable, données fictives locales uniquement).
\set ON_ERROR_STOP on
\pset pager off
set client_min_messages = notice;

create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'ÉCHEC : %', msg; end if;
  raise notice 'OK  %', msg;
end $$;
create or replace function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(u::text, ''), false), set_config('request.jwt.claim.role', case when u is null then 'anon' else 'authenticated' end, false);
$$;

-- Identité HAYEVA (fictive, locale) pour permettre l'émission de factures.
update company_settings set trade_name = 'HAYEVA', legal_name = 'HAYEVA TEST', owner_name = 'Test', address_line1 = '1 rue du Test',
  postal_code = '83600', city = 'Fréjus', siret = '12345678900011', vat_regime = 'franchise_base', insurance_company = 'Assureur',
  insurance_contract_number = 'C-1', mediator_name = 'Médiateur', email = 'contact@hayeva.fr', website = 'https://hayeva.fr' where id = 1;
insert into vault.secrets (name, secret) values ('webhook_secret', 'local-test-secret') on conflict (name) do nothing;
update referral_settings set is_enabled = true, booking_code_entry_enabled = true, reward_calculation_enabled = true,
  referrer_reward_cents = 2000, min_eligible_paid_cents = 10000, min_payout_cents = 10000, payouts_enabled = true where id;
insert into referral_reward_rules (mode, label, is_active, fixed_cents, scope_type) select 'fixed', 'Toutes prestations', true, 2000, 'default'
 where not exists (select 1 from referral_reward_rules where scope_type = 'default' and is_active);

-- Comptes fictifs : administrateur, parrain (Camille), 4 personnes recommandées, un autre parrain.
do $$ declare u record; begin
  for u in select * from (values
    ('00000000-0000-0000-0000-0000000000a1'::uuid, 'admin@test.local', 'admin', 'Ada', 'Admin', '0600000001'),
    ('00000000-0000-0000-0000-0000000000c1'::uuid, 'camille@test.local', 'customer', 'Camille', 'Martin', '0600000002'),
    ('00000000-0000-0000-0000-0000000000d1'::uuid, 'lucas@test.local', 'customer', 'Lucas', 'Bernard', '0600000003'),
    ('00000000-0000-0000-0000-0000000000d2'::uuid, 'emma@test.local', 'customer', 'Emma', 'Petit', '0600000004'),
    ('00000000-0000-0000-0000-0000000000d3'::uuid, 'hugo@test.local', 'customer', 'Hugo', 'Robert', '0600000005'),
    ('00000000-0000-0000-0000-0000000000d4'::uuid, 'lea@test.local', 'customer', 'Léa', 'Richard', '0600000006'),
    ('00000000-0000-0000-0000-0000000000e1'::uuid, 'autre@test.local', 'customer', 'Paul', 'Durand', '0600000007')) v(id, email, role, fn, ln, ph) loop
    insert into auth.users (id, email) values (u.id, u.email) on conflict do nothing;
    insert into profiles (user_id, email, global_role) values (u.id, u.email, u.role) on conflict (user_id) do update set global_role = excluded.global_role;
    insert into customer_profiles (user_id, first_name, last_name, phone) values (u.id, u.fn, u.ln, u.ph) on conflict (user_id) do nothing;
    perform find_or_create_client(u.id, u.email, u.ph, u.fn, u.ln, '10 avenue Test, 83600 Fréjus');
  end loop;
end $$;
update clients set address = '5 rue des Lilas', postal_code = '83600', city = 'Fréjus' where email = 'camille@test.local';
insert into referral_codes (client_id, code, created_by) select id, 'CAMILLE24', null from clients where email = 'camille@test.local' on conflict do nothing;
insert into referral_codes (client_id, code, created_by) select id, 'PAUL24', null from clients where email = 'autre@test.local' on conflict do nothing;
insert into services (slug, name, category, customer_type, is_active, base_price_cents, duration_minutes, booking_type, referral_eligible)
select 'test-entretien', 'Entretien test', 'plomberie', 'particulier', true, 15000, 60, 'DIRECT_BOOKING', true
 where not exists (select 1 from services where slug = 'test-entretien');

create or replace function pg_temp.cid(e text) returns uuid language sql as $$ select id from clients where email = e and merged_into is null $$;
create or replace function pg_temp.book(e text, d date) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into bookings (reference, customer_user_id, client_id, service_id, date, start_time, status, service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents, cgv_version, cgv_accepted_at)
  select 'SM-T-' || substr(md5(random()::text), 1, 6), c.user_id, c.id, s.id, d, '10:00', 'PENDING', 60, 15000, 0, 0, 15000, 'v1', now()
    from clients c, services s where c.email = e and c.merged_into is null and s.slug = 'test-entretien'
  returning id into v; return v; end $$;
create or replace function pg_temp.set_status(b uuid, st text) returns void language plpgsql as $$
declare prev text := current_setting('request.jwt.claim.sub', true); begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
  update bookings set status = st where id = b;
  perform pg_temp.ok((select status from bookings where id = b) = st, '   (statut du rendez-vous → ' || st || ')');
  perform pg_temp.as_user(nullif(prev, '')::uuid);
end $$;
create or replace function pg_temp.invoice_paid(b uuid) returns uuid language plpgsql as $$
declare v uuid; begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
  v := admin_create_invoice('booking', b);
  perform admin_issue_invoice(v, null);
  perform admin_record_invoice_payment(v, (select total_cents from invoices where id = v), 'carte', (now() at time zone 'Europe/Paris')::date, null);
  perform pg_temp.ok((select status from invoices where id = v) = 'PAID', '   (facture payée)');
  return v; end $$;

\echo '=== A. Parcours complet ==='
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select pg_temp.ok((attach_referral('CAMILLE24')->>'ok')::boolean, 'A1 code CAMILLE24 utilisé par Lucas');
select pg_temp.ok((select reference ~ '^HAY-PAR-20[0-9]{2}-[0-9]{4}$' from referrals where referee_client_id = pg_temp.cid('lucas@test.local')), 'A2 référence HAY-PAR-AAAA-NNNN attribuée');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.ok((select jsonb_array_length(get_my_referral_tracking()->'referrals') = 1), 'A3 Camille voit 1 recommandation');
select pg_temp.ok((select (get_my_referral_tracking()->'referrals'->0->'tracking'->'steps') @> '[{"key":"ENREGISTREE"}]'
                   and jsonb_array_length(get_my_referral_tracking()->'referrals'->0->'tracking'->'steps') = 1), 'A4 seule l''étape « enregistrée » est affichée');
select pg_temp.ok((select get_my_referral_tracking()->'referrals'->0->>'reward_cents') is null, 'A5 aucune récompense présentée comme acquise');
select pg_temp.ok(position('Lucas' in get_my_referral_tracking()::text) = 0 and position('lucas@' in get_my_referral_tracking()::text) = 0
                  and position('0600000003' in get_my_referral_tracking()::text) = 0 and position('Bernard' in get_my_referral_tracking()::text) = 0, 'A6 aucune donnée personnelle de Lucas dans le suivi');
create temp table t_ref as select id from referrals where referee_client_id = pg_temp.cid('lucas@test.local');
grant select on t_ref to authenticated;
select pg_temp.ok((issue_referral_document('ATTESTATION', (select id from t_ref))->>'ok')::boolean, 'A7 attestation émise');
select pg_temp.ok((issue_referral_document('ATTESTATION', (select id from t_ref))->>'reused')::boolean, 'A8 situation inchangée : même attestation (même numéro)');
select pg_temp.ok(issue_referral_document('RELEVE', (select id from t_ref))->>'error' = 'RECOMPENSE_NON_VALIDEE', 'A9 relevé refusé avant validation');
select pg_temp.ok(position('Ce document atteste de l''enregistrement d''une recommandation auprès de HAYEVA. Il ne constitue pas une garantie de rémunération.'
                  in (issue_referral_document('ATTESTATION', (select id from t_ref))->'content'->>'notice')) = 1, 'A10 mention obligatoire de l''attestation');

reset role; select pg_temp.as_user(null);
create temp table t_b as select pg_temp.book('lucas@test.local', '2027-01-04') id;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.ok(get_my_referral_tracking()->'referrals'->0->'tracking'->'steps'->1->>'key' = 'DEMANDE', 'A11 demande d''intervention en cours affichée');
select pg_temp.ok(position('2027-01-04' in get_my_referral_tracking()::text) = 0, 'A12 la date du rendez-vous de Lucas n''est pas exposée');
select pg_temp.set_status((select id from t_b), 'CONFIRMED');
select pg_temp.ok(get_my_referral_tracking()->'referrals'->0->'tracking'->'steps'->1->>'key' = 'RENDEZ_VOUS', 'A13 rendez-vous confirmé');
select pg_temp.set_status((select id from t_b), 'COMPLETED');
select pg_temp.ok((get_my_referral_tracking()->'referrals'->0->'tracking'->'steps') @> '[{"key":"INTERVENTION"}]', 'A14 intervention réalisée');
select pg_temp.ok(not ((get_my_referral_tracking()->'referrals'->0->'tracking'->'steps') @> '[{"key":"PAIEMENT"}]'), 'A15 paiement non confirmé : étape absente');
select pg_temp.ok(get_my_referral_tracking()->'referrals'->0->'tracking'->>'next' = 'Confirmation du paiement de l''intervention', 'A16 prochaine étape : confirmation du paiement');
select pg_temp.ok(issue_referral_document('RELEVE', (select id from t_ref))->>'error' = 'RECOMPENSE_NON_VALIDEE', 'A17 relevé toujours refusé sans paiement');
select pg_temp.ok((issue_referral_document('ATTESTATION', (select id from t_ref))->>'reused')::boolean is false, 'A18 nouvelle attestation car le statut réel a changé');

create temp table t_inv as select pg_temp.invoice_paid((select id from t_b)) id;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.ok((get_my_referral_tracking()->'referrals'->0->'tracking'->'steps') @> '[{"key":"PAIEMENT"},{"key":"VALIDEE"}]', 'A19 paiement confirmé puis récompense validée');
select pg_temp.ok((get_my_referral_tracking()->'referrals'->0->>'reward_cents')::int = 2000, 'A20 montant issu du barème réel (20 €)');
select pg_temp.ok((get_my_referral_tracking()->'amounts'->>'acquired_cents')::int = 2000 and (get_my_referral_tracking()->'amounts'->>'paid_cents')::int = 0, 'A21 acquis 20 €, réglé 0 €');
select pg_temp.ok(position('15000' in get_my_referral_tracking()::text) = 0, 'A22 montant payé par Lucas non exposé');
create temp table t_rel1 as select issue_referral_document('RELEVE', (select id from t_ref)) d;
select pg_temp.ok((select (d->>'ok')::boolean and d->'content'->>'settlement' = 'A_REGLER' and (d->'content'->>'amount_cents')::int = 2000 from t_rel1), 'A23 relevé émis : 20 €, à régler');
select pg_temp.ok((select position('15000' in d::text) = 0 from t_rel1), 'A24 relevé sans le montant payé par le client');
select pg_temp.ok((select count(*) from net.calls where url like '%notify-referral' and body->>'notification_id' in (select id::text from referral_notifications where kind in ('new_referral','reward_validated'))) = 2, 'A25 e-mails déclenchés : enregistrée + validée');

\echo '=== B. Règlement ==='
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.ok(issue_referral_document('JUSTIFICATIF', gen_random_uuid())->>'error' = 'INTROUVABLE', 'B1 aucun justificatif sans règlement');
select pg_temp.ok((request_referral_payout()->>'error') = 'SEUIL_NON_ATTEINT', 'B2 demande de versement sous le seuil refusée');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
do $$ begin
  perform admin_mark_rewards_paid(array[(select id from referral_rewards where referral_id = (select id from t_ref))], 'VIR-1', null);
  raise exception 'devait échouer';
exception when others then perform pg_temp.ok(sqlerrm like '%Moyen de règlement requis%', 'B3 règlement refusé sans moyen ni date'); end $$;
select pg_temp.ok((admin_mark_rewards_paid(array[(select id from referral_rewards where referral_id = (select id from t_ref))], 'VIR-1', null, 'virement', (now() at time zone 'Europe/Paris')::date)->>'reference') ~ '^HAY-REG-', 'B4 règlement enregistré : HAY-REG-…');
select pg_temp.ok((select count(*) from net.calls where url like '%notify-referral' and body->>'notification_id' in (select id::text from referral_notifications where kind = 'payout_paid')) = 1, 'B5 e-mail « règlement effectué » déclenché');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
create temp table t_pay as select id from referral_payout_requests where referrer_client_id = pg_temp.cid('camille@test.local');
grant select on t_pay to authenticated;
select pg_temp.ok((get_my_referral_tracking()->'referrals'->0->'tracking'->'steps') @> '[{"key":"REGLEE"}]', 'B6 étape « récompense réglée »');
select pg_temp.ok((get_my_referral_tracking()->'amounts'->>'paid_cents')::int = 2000, 'B7 réglé 20 €');
create temp table t_jus as select issue_referral_document('JUSTIFICATIF', (select id from t_pay)) d;
select pg_temp.ok((select (d->>'ok')::boolean and d->'content'->>'method' = 'Virement bancaire' and (d->'content'->'rewards'->0->>'reference') ~ '^HAY-PAR-' from t_jus), 'B8 justificatif : moyen, date, références');
create temp table t_rel2 as select issue_referral_document('RELEVE', (select id from t_ref)) d;
select pg_temp.ok((select d->'content'->>'settlement' = 'REGLE' and d->>'number' <> (select d->>'number' from t_rel1) from t_rel2), 'B9 nouveau relevé « réglé » (nouveau numéro)');
reset role; select pg_temp.as_user(null);
select pg_temp.ok((verify_referral_document((select d->>'verification_code' from t_rel1))->>'superseded')::boolean, 'B10 l''ancien relevé est signalé comme remplacé');
select pg_temp.ok(verify_referral_document((select d->>'verification_code' from t_jus))->>'beneficiary_initials' = 'C. M.', 'B11 vérification publique : initiales seulement');
select pg_temp.ok(position('Martin' in verify_referral_document((select d->>'verification_code' from t_jus))::text) = 0, 'B12 vérification sans nom complet');
select pg_temp.ok((verify_referral_document('XXXX-XXXX-XXXX')->>'found')::boolean is false, 'B13 code inconnu : introuvable');
select pg_temp.ok(not (verify_referral_document((select d->>'verification_code' from t_jus)) ? 'amount_cents'), 'B14 vérification publique sans montant');

\echo '=== C. Annulation ==='
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select pg_temp.ok((attach_referral('CAMILLE24')->>'ok')::boolean, 'C1 Emma utilise le code');
reset role; select pg_temp.as_user(null);
create temp table t_b2 as select pg_temp.book('emma@test.local', '2027-01-05') id;
select pg_temp.set_status((select id from t_b2), 'CONFIRMED');
select pg_temp.set_status((select id from t_b2), 'CANCELLED');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
create temp table t_c as select x from jsonb_array_elements(get_my_referral_tracking()->'referrals') x
  where x->>'id' = (select id::text from referrals where referee_client_id = pg_temp.cid('emma@test.local'));
select pg_temp.ok((select x->'tracking'->'steps' @> '[{"key":"ARRET","label":"Rendez-vous annulé"}]' from t_c), 'C2 étape « rendez-vous annulé »');
select pg_temp.ok((select x->'status'->>'key' = 'NON_RETENUE' and x->>'reward_cents' is null and x->>'possible_cents' is null from t_c), 'C3 aucune récompense affichée');
select pg_temp.ok((select x->'tracking'->>'next' is null from t_c), 'C4 aucune prochaine étape promise');

\echo '=== D. Paiement non confirmé ==='
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d3');
select pg_temp.ok((attach_referral('CAMILLE24')->>'ok')::boolean, 'D1 Hugo utilise le code');
reset role; select pg_temp.as_user(null);
create temp table t_b3 as select pg_temp.book('hugo@test.local', '2027-01-06') id;
select pg_temp.set_status((select id from t_b3), 'CONFIRMED'); select pg_temp.set_status((select id from t_b3), 'COMPLETED');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select admin_issue_invoice(admin_create_invoice('booking', (select id from t_b3)), null) is not null;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
create temp table t_d as select x from jsonb_array_elements(get_my_referral_tracking()->'referrals') x
  where x->>'id' = (select id::text from referrals where referee_client_id = pg_temp.cid('hugo@test.local'));
select pg_temp.ok((select not (x->'tracking'->'steps' @> '[{"key":"PAIEMENT"}]') and x->'status'->>'key' in ('EN_COURS', 'VERIFICATION') and x->>'reward_cents' is null from t_d), 'D2 facture émise non payée : ni paiement ni récompense');
select pg_temp.ok(issue_referral_document('RELEVE', (select id from referrals where referee_client_id = pg_temp.cid('hugo@test.local')))->>'error' = 'RECOMPENSE_NON_VALIDEE', 'D3 relevé refusé');

\echo '=== E. Remboursement après validation ==='
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.ok((attach_referral('CAMILLE24')->>'ok')::boolean, 'E1 Léa utilise le code');
reset role; select pg_temp.as_user(null);
create temp table t_b4 as select pg_temp.book('lea@test.local', '2027-01-07') id;
select pg_temp.set_status((select id from t_b4), 'CONFIRMED'); select pg_temp.set_status((select id from t_b4), 'COMPLETED');
create temp table t_inv4 as select pg_temp.invoice_paid((select id from t_b4)) id;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
create temp table t_rel4 as select issue_referral_document('RELEVE', (select id from referrals where referee_client_id = pg_temp.cid('lea@test.local'))) d;
select pg_temp.ok((select (d->>'ok')::boolean from t_rel4), 'E2 relevé émis après validation');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select admin_mark_invoice_refunded((select id from t_inv4), (select total_cents from invoices where id = (select id from t_inv4)));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
create temp table t_e as select x from jsonb_array_elements(get_my_referral_tracking()->'referrals') x
  where x->>'id' = (select id::text from referrals where referee_client_id = pg_temp.cid('lea@test.local'));
select pg_temp.ok((select x->'status'->>'key' = 'ANNULEE' and x->>'reward_cents' is null and x->'tracking'->'steps' @> '[{"key":"ARRET","label":"Récompense annulée"}]' from t_e), 'E3 récompense annulée après remboursement');
reset role; select pg_temp.as_user(null);
select pg_temp.ok((verify_referral_document((select d->>'verification_code' from t_rel4))->>'revoked')::boolean, 'E4 le relevé est annulé dans le registre');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.ok(issue_referral_document('RELEVE', (select id from referrals where referee_client_id = pg_temp.cid('lea@test.local')))->>'error' = 'RECOMPENSE_NON_VALIDEE', 'E5 plus aucun relevé émissible');

\echo '=== F. Sécurité ==='
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select pg_temp.ok(issue_referral_document('ATTESTATION', (select id from t_ref))->>'error' = 'INTROUVABLE', 'F1 la personne recommandée n''obtient pas le document du parrain');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select pg_temp.ok(issue_referral_document('JUSTIFICATIF', (select id from t_pay))->>'error' = 'INTROUVABLE', 'F2 un autre parrain n''obtient rien');
select pg_temp.ok(jsonb_array_length(get_my_referral_tracking()->'referrals') = 0, 'F3 un autre parrain ne voit aucune recommandation de Camille');
select pg_temp.ok((select count(*) from referral_documents) = 0, 'F4 un autre parrain ne lit aucun document de Camille (RLS)');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.ok((select count(*) from referral_documents) > 0, 'F5 Camille lit ses propres documents');
do $$ begin insert into referral_documents (kind, number, referrer_client_id, referral_id, content, content_sha256, verification_code)
  values ('ATTESTATION', 'FAUX-1', (select my_client_id()), (select id from t_ref), '{}', 'x', 'FAUX'); raise exception 'devait échouer';
exception when insufficient_privilege then perform pg_temp.ok(true, 'F6 création directe d''un document refusée'); end $$;
do $$ begin update referral_documents set content = '{"amount_cents": 99999}'; raise exception 'devait échouer';
exception when insufficient_privilege then perform pg_temp.ok(true, 'F7 modification directe d''un document refusée'); end $$;
do $$ begin perform referral_document_attach_file(gen_random_uuid(), 'x', 'y'); raise exception 'devait échouer';
exception when insufficient_privilege then perform pg_temp.ok(true, 'F8 rattachement de fichier réservé au serveur'); end $$;
do $$ begin perform admin_record_referral_payout(gen_random_uuid(), 'virement', current_date, null, null); raise exception 'devait échouer';
exception when others then perform pg_temp.ok(sqlerrm like '%réservé%', 'F9 règlement réservé à l''administration'); end $$;
reset role;
set role anon; select pg_temp.as_user(null);
do $$ begin perform issue_referral_document('ATTESTATION', gen_random_uuid()); raise exception 'devait échouer';
exception when insufficient_privilege then perform pg_temp.ok(true, 'F10 visiteur non connecté : émission refusée'); end $$;
do $$ begin perform get_my_referral_tracking(); raise exception 'devait échouer';
exception when insufficient_privilege then perform pg_temp.ok(true, 'F11 visiteur non connecté : suivi refusé'); end $$;
select pg_temp.ok((verify_referral_document('XXXX')->>'found')::boolean is false, 'F12 vérification publique accessible');
reset role;
do $$ begin update referral_documents set content = '{}' where true; raise exception 'devait échouer';
exception when others then perform pg_temp.ok(sqlerrm like '%ne peut pas être modifié%', 'F13 même le propriétaire de la base ne peut pas réécrire un document'); end $$;
do $$ begin delete from referral_documents; raise exception 'devait échouer';
exception when others then perform pg_temp.ok(sqlerrm like '%ajout seul%', 'F14 suppression impossible'); end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
do $$ begin perform admin_set_referral_payout_status((select id from referral_payout_requests limit 1), 'REQUESTED', null, null); exception when others then null; end $$;
\echo '=== H. Demande de versement : passage à « Payé » ==='
reset role;
insert into referral_payout_requests (referrer_client_id, amount_cents, status, approved_at) values (pg_temp.cid('autre@test.local'), 2000, 'APPROVED', now());
create temp table t_h as select id, reference from referral_payout_requests where referrer_client_id = pg_temp.cid('autre@test.local');
select pg_temp.ok((select reference ~ '^HAY-REG-' from t_h), 'H1 demande référencée HAY-REG-…');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
do $$ begin perform admin_set_referral_payout_status((select id from t_h), 'PAID', null, 'X'); raise exception 'devait échouer';
exception when others then perform pg_temp.ok(sqlerrm like '%moyen et la date réels%', 'H2 ancienne voie : « Payé » refusé sans moyen ni date'); end $$;
do $$ begin perform admin_record_referral_payout((select id from t_h), 'virement', (now() at time zone 'Europe/Paris')::date + 1, null, null); raise exception 'devait échouer';
exception when others then perform pg_temp.ok(sqlerrm like '%Date de règlement invalide%', 'H3 date future refusée'); end $$;
select pg_temp.ok(admin_record_referral_payout((select id from t_h), 'cheque', (now() at time zone 'Europe/Paris')::date, 'CHQ-0001', null) = 'PAID', 'H4 règlement enregistré avec moyen et date');
select pg_temp.ok((select payment_method = 'cheque' and payment_date is not null and paid_at is not null from referral_payout_requests where id = (select id from t_h)), 'H5 moyen et date réels conservés');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select pg_temp.ok(issue_referral_document('JUSTIFICATIF', (select id from t_h))->'content'->>'method' = 'Chèque', 'H6 justificatif : chèque');
reset role;
\echo '=== J. Administration ==='
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.ok((select bool_and(x->>'reference' ~ '^HAY-PAR-') from jsonb_array_elements(admin_ambassador_detail(pg_temp.cid('camille@test.local'))->'rewards') x), 'J1 fiche admin : références HAY-PAR');
select pg_temp.ok((select bool_and(x->>'reference' ~ '^HAY-REG-' and x->>'payment_method' = 'virement' and x->>'payment_date' is not null) from jsonb_array_elements(admin_ambassador_detail(pg_temp.cid('camille@test.local'))->'payouts') x), 'J2 fiche admin : règlement avec moyen et date réels');
select pg_temp.ok(jsonb_array_length(admin_list_referral_documents(pg_temp.cid('camille@test.local'))) >= 4, 'J3 liste des documents du parrain');
do $$ declare d uuid := (select id from referral_documents where kind = 'ATTESTATION' and revoked_at is null limit 1); begin
  perform admin_revoke_referral_document(d, 'Test');
  perform pg_temp.ok((select revoked_at is not null and revoked_reason = 'Test' from referral_documents where id = d), 'J4 annulation motivée d''un document');
  begin perform admin_revoke_referral_document(d, 'Encore'); raise exception 'devait échouer';
  exception when others then perform pg_temp.ok(sqlerrm like '%déjà annulé%', 'J5 un document annulé ne peut pas l''être deux fois'); end;
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
do $$ begin perform admin_ambassador_detail(pg_temp.cid('camille@test.local')); raise exception 'devait échouer';
exception when others then perform pg_temp.ok(sqlerrm like '%réservé%', 'J6 fiche admin inaccessible à un parrain'); end $$;
reset role;
\echo '=== G. Données existantes ==='
select pg_temp.ok((select count(*) from referral_codes) = 2 and (select count(*) from referrals where reference is null) = 0, 'G1 codes conservés, toutes les recommandations référencées');

\echo '=== I. Contexte des e-mails ==='
reset role;
create temp table t_ctx as select referral_email_context(n.id) c, n.kind from referral_notifications n where n.client_id = pg_temp.cid('camille@test.local') and n.kind in ('new_referral','reward_validated','payout_paid');
select pg_temp.ok((select count(*) from t_ctx where c is not null) >= 3, 'I1 contexte disponible pour les 3 types d''e-mail');
select pg_temp.ok((select bool_and(position('Lucas' in c::text) = 0 and position('lucas@' in c::text) = 0 and position('Emma' in c::text) = 0 and position('0600000003' in c::text) = 0) from t_ctx), 'I2 aucun e-mail ne contient de donnée du client recommandé');
select pg_temp.ok((select bool_and(c->>'recipient_email' = 'camille@test.local') from t_ctx), 'I3 destinataire : le parrain');
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
do $$ begin perform referral_email_context(gen_random_uuid()); raise exception 'devait échouer';
exception when insufficient_privilege then perform pg_temp.ok(true, 'I4 contexte d''e-mail inaccessible depuis le navigateur'); end $$;
reset role;
\echo 'TOUS LES TESTS SONT PASSÉS'
