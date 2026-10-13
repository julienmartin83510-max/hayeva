-- DONNÉES FICTIVES du projet de TEST d'EVA (jamais la production).
-- À exécuter après les migrations et isolate_test_project.sql.
-- Tous les clients sont fictifs (adresses @exemple.test, téléphones 06 00 00 00 xx).
do $$ begin
  if exists (select 1 from clients where coalesce(email, '') !~* '@(test\.local|exemple\.test)$'
             and (user_id is null or user_id not in (select user_id from profiles where global_role = 'admin'))) then
    raise exception 'ARRÊT : base contenant des clients réels.';
  end if;
end $$;
-- Projet de test uniquement : ouverture avancée pour pouvoir tester EVA aujourd'hui.
update booking_settings set opening_date = current_date - 30 where id = 1;
insert into clients (first_name, last_name, email, phone, address, postal_code, city, client_type) values
  ('Paul', 'Martin', 'paul.martin@exemple.test', '0600000001', '2 place Centrale', '83490', 'Le Muy', 'particulier'),
  ('Jean', 'Dupont', 'jean.dupont@exemple.test', '0600000002', '5 rue des Pins', '83700', 'Saint-Raphaël', 'particulier'),
  ('Élodie', 'Lefèvre', 'elodie.lefevre@exemple.test', '0600000003', '9 bd de la Mer', '83600', 'Fréjus', 'particulier'),
  ('Sophie', 'Bernard', 'sophie.bernard@exemple.test', '0600000004', '14 av. de Verdun', '83600', 'Fréjus', 'particulier');
-- Rendez-vous : demain (2 confirmés + 1 à confirmer), dernier jour ouvré (terminé), la semaine prochaine.
with d as (select ((now() at time zone 'Europe/Paris')::date) t),
s as (select id, slug, coalesce(base_price_cents, 0) p, coalesce(duration_minutes, 60) dur from services where is_active order by sort_order nulls last, name limit 3)
insert into bookings (client_id, guest_name, guest_email, guest_phone, guest_address, service_id, date, start_time, status, service_duration_minutes, service_price_cents, total_cents)
select c.id, c.first_name || ' ' || c.last_name, c.email, c.phone, c.address || ' ' || c.postal_code || ' ' || c.city, sv.id,
       d.t + x.dd - (case when x.dd < 0 and extract(isodow from d.t + x.dd) = 7 then 1 else 0 end), x.tm::time, x.st, sv.dur, sv.p, sv.p
  from d, (values ('paul.martin@exemple.test', 1, '09:00', 'CONFIRMED', 1), ('jean.dupont@exemple.test', 1, '11:00', 'CONFIRMED', 2),
               ('elodie.lefevre@exemple.test', 1, '14:30', 'PENDING', 3), ('paul.martin@exemple.test', -1, '10:00', 'CONFIRMED', 1),
               ('sophie.bernard@exemple.test', 8, '09:30', 'CONFIRMED', 2)) x(em, dd, tm, st, rk)
  join clients c on c.email = x.em
  join (select *, row_number() over () rk from s) sv on sv.rk = x.rk
 where x.dd < 0 or extract(isodow from d.t + x.dd) < 7;
select set_config('app.allow_status_change', 'on', true);
update bookings set status = 'COMPLETED' where date < (now() at time zone 'Europe/Paris')::date and guest_email = 'paul.martin@exemple.test';
select set_config('app.allow_status_change', '', true);
insert into interventions (booking_id, report_status, observations)
select id, 'DRAFT', 'Robinet de machine à laver grippé (donnée fictive).' from bookings where status = 'COMPLETED' and guest_email = 'paul.martin@exemple.test';
-- Équipement (la table exige un compte : rattaché au compte administrateur de TEST).
insert into customer_equipment (customer_user_id, client_id, equipment_type, brand, model, last_service_at, maintenance_reminders_enabled)
select (select user_id from profiles where global_role = 'admin' limit 1), id, 'chaudiere_gaz', 'Saunier Duval', 'ThemaPlus', current_date - interval '11 months', false
  from clients where email = 'paul.martin@exemple.test' and exists (select 1 from profiles where global_role = 'admin');
insert into quotes (client_id, reference, status, title, subtotal_cents, total_cents, created_at)
select id, 'BROUILLON-TEST-1', 'DRAFT', 'Remplacement mitigeur douche (fictif)', 12900, 12900, now() - interval '1 day' from clients where email = 'paul.martin@exemple.test';
insert into quote_options (quote_id, label, supply_cents, labor_cents, sort_order)
select id, 'Mitigeur thermostatique + pose', 4500, 8400, 0 from quotes where reference = 'BROUILLON-TEST-1';
update quotes q set selected_option_id = (select id from quote_options where quote_id = q.id limit 1) where reference = 'BROUILLON-TEST-1';
insert into referral_codes (client_id, code, participant_type, status) select id, 'MARTINTEST', 'individual', 'active' from clients where email = 'paul.martin@exemple.test';
select 'Données fictives prêtes : ' || (select count(*) from clients) || ' clients, ' || (select count(*) from bookings) || ' rendez-vous.';
