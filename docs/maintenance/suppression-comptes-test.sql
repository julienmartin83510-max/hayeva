-- =====================================================================
-- HAYEVA — Suppression des comptes et données de TEST (adresses @example.com)
--
-- À exécuter dans Supabase → SQL Editor, en deux temps :
--   1) ÉTAPE 1 seule : vérifier la liste affichée.
--   2) ÉTAPE 2 : suppression, en une seule transaction (tout ou rien).
--
-- Périmètre : uniquement les adresses se terminant par @example.com
-- (domaine réservé aux tests, qui ne peut appartenir à aucun client réel).
-- Exception conservée : la fiche test.audit.referral@example.com, reliée
-- à un parrainage d'une vraie personne (historique de parrainage préservé).
-- Les protections (comptes rendus signés, factures) ne sont suspendues que
-- pendant la transaction et réactivées à la fin ; en cas d'erreur, rien
-- n'est supprimé et elles restent actives.
-- =====================================================================

-- ---------- ÉTAPE 1 : aperçu (aucune modification) ----------
with keep as (select id from clients where email = 'test.audit.referral@example.com'),
tu as (select id, email from auth.users where email ilike '%@example.com'),
tc as (select id, email from clients where (email ilike '%@example.com' or user_id in (select id from tu)) and id not in (select id from keep)),
tb as (select id, reference, status, date, notes from bookings
        where (customer_user_id in (select id from tu) or client_id in (select id from tc) or guest_email ilike '%@example.com')
          and client_id is distinct from (select id from keep))
select 'compte' as type, email as detail from tu
union all select 'fiche client', email from tc
union all select 'rendez-vous', reference || ' — ' || status || ' — ' || date || ' — ' || coalesce(notes, '') from tb
order by 1, 2;

-- ---------- ÉTAPE 2 : suppression ----------
do $$
declare
  keep_client uuid;
  n_users int; n_clients int; n_bookings int; n_inv int; n_quotes int; n_pro int; n_hist int; n_equip int;
begin
  select id into keep_client from clients where email = 'test.audit.referral@example.com';

  create temp table tu on commit drop as select id from auth.users where email ilike '%@example.com';
  create temp table tc on commit drop as
    select id from clients where (email ilike '%@example.com' or user_id in (select id from tu)) and id is distinct from keep_client;
  create temp table tb on commit drop as
    select id from bookings where (customer_user_id in (select id from tu) or client_id in (select id from tc) or guest_email ilike '%@example.com')
      and client_id is distinct from keep_client;
  create temp table ti on commit drop as
    select id from invoices where customer_user_id in (select id from tu) or client_id in (select id from tc) or booking_id in (select id from tb);
  create temp table tq on commit drop as
    select id from quotes where customer_user_id in (select id from tu) or client_id in (select id from tc) or booking_id in (select id from tb);

  alter table public.interventions disable trigger trg_interventions_freeze_finalized;
  alter table public.intervention_items disable trigger trg_intervention_items_freeze;
  alter table public.intervention_photos disable trigger trg_intervention_photos_freeze;
  alter table public.invoices disable trigger trg_invoices_immutability;
  alter table public.invoice_lines disable trigger trg_invoice_lines_guard;

  delete from invoices where id in (select id from ti); get diagnostics n_inv = row_count;
  delete from quotes where id in (select id from tq); get diagnostics n_quotes = row_count;
  delete from bookings where id in (select id from tb); get diagnostics n_bookings = row_count;
  delete from customer_equipment where client_id in (select id from tc) or customer_user_id in (select id from tu); get diagnostics n_equip = row_count;
  delete from clients where id in (select id from tc); get diagnostics n_clients = row_count;
  delete from professional_accounts where created_by in (select id from tu); get diagnostics n_pro = row_count;
  update booking_status_history set changed_by = null where changed_by in (select id from tu); get diagnostics n_hist = row_count;
  delete from auth.users where id in (select id from tu); get diagnostics n_users = row_count;

  alter table public.interventions enable trigger trg_interventions_freeze_finalized;
  alter table public.intervention_items enable trigger trg_intervention_items_freeze;
  alter table public.intervention_photos enable trigger trg_intervention_photos_freeze;
  alter table public.invoices enable trigger trg_invoices_immutability;
  alter table public.invoice_lines enable trigger trg_invoice_lines_guard;

  raise notice 'Supprimés : comptes=% fiches=% rendez-vous=% factures=% devis=% comptes_pro=% équipements=% (historique anonymisé : %)',
    n_users, n_clients, n_bookings, n_inv, n_quotes, n_pro, n_equip, n_hist;
end $$;
