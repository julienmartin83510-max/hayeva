-- Test DIFFÉRENTIEL de non-régression (réservations, créneaux, devis, factures, parrainage, fidélité, statistiques).
-- À exécuter sur une base locale jetable AVANT puis APRÈS 0135-0137 et comparer les sorties : seule différence attendue,
-- HOURS_BUGFIX (un créneau de 4 h commençant à 20 h ne déborde plus après minuit).
-- psql -v ADMIN="'<uuid admin>'" -v MARTIN="'<uuid client>'" -f eva_non_regression.sql
-- Test différentiel : mêmes scénarios avant / après 0135-0137. Seule la sortie est comparée.
\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset tuples_only on
set client_min_messages = warning;
create or replace function pg_temp.try(q text) returns text language plpgsql as $$
declare r text; begin execute q into r; return coalesce(r, 'NULL'); exception when others then return 'ERR: ' || sqlerrm; end $$;
create or replace function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(u::text, ''), false), set_config('request.jwt.claim.role', case when u is null then 'anon' else 'authenticated' end, false);
$$;
-- Comptes fictifs
\i eva_non_regression_seed.sql
-- 1. Heures d'ouverture : grille complète sur 2 semaines (créneaux 30 min, 4 durées)
select 'HOURS ' || md5(string_agg(d::date || ' ' || t::time || ' ' || dur || ' ' || is_slot_within_business_hours(d::date, t::time, dur)::text, ',' order by d, t, dur))
  from generate_series(date '2027-01-11', date '2027-01-24', interval '1 day') d, generate_series(timestamp '2000-01-01 06:00', timestamp '2000-01-01 21:30', interval '30 minutes') t, unnest(array[30,60,120,240]) dur
 where not (t::time >= '20:00' and dur = 240);  -- seule différence voulue : 20 h + 4 h ne passe plus minuit (corrigé)
select 'HOURS_BUGFIX ' || string_agg(t::time || '=' || is_slot_within_business_hours(date '2027-01-12', t::time, 240)::text, ',' order by t) from generate_series(timestamp '2000-01-01 20:00', timestamp '2000-01-01 21:30', interval '30 minutes') t;
-- 2. Réglages publics (hors nouvelles clés)
select 'PUBLIC ' || (to_jsonb(get_public_booking_settings()) - 'work_hours' - 'travel_margin_minutes')::text;
-- 3. Réservation client réelle
insert into customer_addresses (customer_user_id, label, address, postal_code, city, is_default) values (:MARTIN::uuid, 'Maison', '2 place Centrale', '83490', 'Le Muy', true);
select pg_temp.as_user(:MARTIN);
select 'BOOK_OK ' || regexp_replace(pg_temp.try($$select (create_booking(p_service_slug := 'plomberie-mitigeur-lavabo', p_date := date '2027-01-12', p_start_time := time '10:00', p_customer_address_id := (select id from customer_addresses limit 1), p_cgv_version := '2026-10'))::text$$), '[0-9a-f-]{36}|SM-[0-9]{4}-[0-9A-F]{6}', 'X', 'g');
select 'BOOK_SUNDAY ' || pg_temp.try($$select (create_booking(p_service_slug := 'plomberie-mitigeur-lavabo', p_date := date '2027-01-17', p_start_time := time '10:00', p_customer_address_id := (select id from customer_addresses limit 1), p_cgv_version := '2026-10'))::text$$);
select 'BOOK_NIGHT ' || pg_temp.try($$select (create_booking(p_service_slug := 'plomberie-mitigeur-lavabo', p_date := date '2027-01-12', p_start_time := time '21:00', p_customer_address_id := (select id from customer_addresses limit 1), p_cgv_version := '2026-10'))::text$$);
select 'BOOK_OVERLAP ' || pg_temp.try($$select (create_booking(p_service_slug := 'plomberie-mitigeur-lavabo', p_date := date '2027-01-12', p_start_time := time '10:00', p_customer_address_id := (select id from customer_addresses limit 1), p_cgv_version := '2026-10'))::text$$);
select 'BOOK_ROW ' || (select status || ' ' || total_cents || ' ' || service_duration_minutes || ' ' || calendar_sync_status from bookings order by created_at desc limit 1);
-- 4. Créneaux libres (déplacement)
select pg_temp.as_user(:ADMIN);
select 'SLOTS ' || regexp_replace(pg_temp.try(format($$select md5(string_agg(x::text, ',')) from booking_free_slots(%L, date '2027-01-13') x$$, (select id from bookings order by created_at desc limit 1))), '[0-9a-f-]{36}|SM-[0-9]{4}-[0-9A-F]{6}', 'X', 'g');
select 'SLOTS_SUN ' || regexp_replace(pg_temp.try(format($$select count(*)::text from booking_free_slots(%L, date '2027-01-17') x$$, (select id from bookings order by created_at desc limit 1))), '[0-9a-f-]{36}|SM-[0-9]{4}-[0-9A-F]{6}', 'X', 'g');
select 'RESCHED ' || regexp_replace(pg_temp.try(format($$select admin_reschedule_booking(%L, date '2027-01-13', time '14:00')::text$$, (select id from bookings order by created_at desc limit 1))), '[0-9a-f-]{36}|SM-[0-9]{4}-[0-9A-F]{6}', 'X', 'g');
-- 5. Devis : envoi et numérotation
insert into quotes (client_id, customer_user_id, reference, status, title, subtotal_cents, total_cents) select id, :MARTIN::uuid, 'BROUILLON-NR', 'DRAFT', 'Devis test', 10000, 10000 from clients where email = 'martin@test.local';
update quotes set status = 'SENT', sent_at = now() where reference = 'BROUILLON-NR';
select 'QUOTE ' || regexp_replace((select status || ' ' || reference from quotes where title = 'Devis test'), '[0-9]+$', 'N');
-- 6. Factures : brouillon, émission bloquée tant que la facturation n'est pas prête
update bookings set status = 'COMPLETED' where id = (select id from bookings order by created_at desc limit 1);
select 'INV_DRAFT ' || regexp_replace(pg_temp.try(format($$select admin_create_invoice('booking', %L)::text$$, (select id from bookings order by created_at desc limit 1))), '[0-9a-f-]{36}', 'X', 'g');
select 'INV_ISSUE ' || pg_temp.try(format($$select admin_issue_invoice(%L, null)::text$$, (select id from invoices order by created_at desc limit 1)));
select 'BILLING_READY_DEFAULT ' || company_billing_ready()::text;
-- 7. Parrainage et fidélité
select 'REF_CODE ' || pg_temp.try($$select generate_referral_code_for((select id from clients where email='martin@test.local'))::text$$) ~ '^[A-Z0-9]+$';
select 'REF_PREVIEW ' || pg_temp.try($$select (get_referral_preview((select code from referral_codes limit 1)) ? 'valid')::text$$);
select 'WALLET ' || pg_temp.try($$select coalesce(admin_adjust_wallet((select id from clients where email='martin@test.local'), 500, 'test')::text, 'ok')$$) || ' ' || (select coalesce(sum(balance_cents),0) from wallet_balances);
select 'STATS ' || pg_temp.try($$select to_jsonb(s)::text from admin_booking_stats(date '2027-01-01', date '2027-01-31') s$$);
