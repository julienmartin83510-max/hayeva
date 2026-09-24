-- ============================================================
-- Durcissement des droits EXECUTE sur les fonctions du schéma public
-- ============================================================
-- Constat (reproduit en local avec les privilèges par défaut Supabase) :
-- toute fonction créée dans public reçoit automatiquement EXECUTE pour
-- anon/authenticated (privilèges par défaut du projet + PUBLIC). Les
-- "revoke all ... from public" des migrations précédentes ne retirent PAS
-- ces droits accordés nommément (déjà constaté en 0001_init.sql pour
-- create_booking). Conséquence la plus grave : get_quote_signing_secret()
-- était appelable par n'importe quel visiteur (clé publique du site) via
-- /rest/v1/rpc/get_quote_signing_secret — il pouvait lire le secret HMAC et
-- forger un devis de distance "0 km" (frais de déplacement supprimés).
--
-- Principe appliqué : liste blanche. On retire EXECUTE à PUBLIC, anon et
-- authenticated sur TOUTES les fonctions du schéma public (hors fonctions
-- appartenant à une extension), puis on ré-accorde uniquement ce dont le
-- site a réellement besoin. service_role n'est pas touché (Edge Functions).
--
-- Pourquoi c'est sans risque pour le fonctionnement normal :
--   * les fonctions trigger (protect_*, notify_*) ne sont jamais soumises au
--     droit EXECUTE lors de leur déclenchement (vérifié seulement à la
--     création du trigger) ;
--   * compute_travel_fee_cents() / verify_distance_quote() ne sont appelées
--     que depuis create_booking() / create_guest_or_quote_booking(), qui sont
--     SECURITY DEFINER et s'exécutent donc avec les droits de leur
--     propriétaire, pas ceux du visiteur ;
--   * les fonctions utilisées dans des policies RLS (is_admin(),
--     my_professional_account_ids(), et toute autre éventuellement créée à
--     la main dans le dashboard) sont ré-accordées automatiquement plus bas,
--     car une policy est évaluée avec les droits de l'appelant.
--
-- Rejouable sans risque (idempotent).

-- ---- 1. Retrait général ----
do $$
declare
  r record;
  v_known text[] := array[
    'is_admin', 'my_professional_account_ids',
    'create_booking', 'create_guest_or_quote_booking', 'create_professional_account',
    'get_quote_signing_secret', 'verify_distance_quote', 'compute_travel_fee_cents',
    'protect_verification_fields', 'protect_booking_financial_fields',
    'protect_quote_invoice_fields', 'protect_invoice_amount_fields',
    'notify_admin_new_booking', 'notify_customer_new_booking', 'notify_customer_status_change',
    'protect_booking_direct_writes', 'protect_profile_role'
  ];
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind in ('f', 'p')
      and not exists (
        select 1 from pg_depend d
        where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
      )
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    if not (r.proname = any (v_known)) then
      -- Fonction absente des migrations du dépôt (créée à la main ?) :
      -- signalée pour relecture, elle n'est plus appelable par le navigateur.
      raise notice 'HAYEVA 0013 : EXECUTE retiré à anon/authenticated sur une fonction inconnue des migrations : %', r.sig;
    end if;
  end loop;
end $$;

-- ---- 2. Ré-autorisations strictement nécessaires ----

-- Utilisées dans les policies RLS (évaluées avec les droits de l'appelant,
-- visiteur anonyme compris : ex. lecture du catalogue "is_active or is_admin()").
grant execute on function is_admin() to anon, authenticated;
grant execute on function my_professional_account_ids() to anon, authenticated;

-- Sécurité supplémentaire : toute AUTRE fonction dont dépend une policy RLS
-- (créée hors migrations) retrouve son droit d'exécution, pour ne jamais
-- casser silencieusement une policy existante.
do $$
declare r record;
begin
  for r in
    select distinct p.oid::regprocedure as sig
    from pg_depend d
    join pg_proc p on p.oid = d.refobjid
    join pg_namespace n on n.oid = p.pronamespace
    where d.classid = 'pg_policy'::regclass
      and d.refclassid = 'pg_proc'::regclass
      and n.nspname = 'public'
  loop
    execute format('grant execute on function %s to anon, authenticated', r.sig);
  end loop;
end $$;

-- RPC appelées par le site (index.html) :
--   réservation particulier connecté
grant execute on function create_booking(text, date, time, text, uuid, uuid, text, text) to authenticated;
--   réservation invitée / devis (visiteur non connecté inclus)
grant execute on function create_guest_or_quote_booking(text, date, time, text, text, text, text, text, text, text) to anon, authenticated;
--   inscription professionnelle (première connexion)
grant execute on function create_professional_account(text, text, text, text) to authenticated;

-- Secret de signature : uniquement le contexte serveur (Edge Function
-- calculate-travel-distance, clé service_role). Jamais anon/authenticated.
revoke execute on function get_quote_signing_secret() from public, anon, authenticated;
grant execute on function get_quote_signing_secret() to service_role;

-- ---- 3. Fonctions créées plus tard ----
-- Les futures fonctions créées par "postgres" dans public ne seront plus
-- accordées automatiquement à anon/authenticated par le privilège par défaut
-- du projet. ATTENTION : PostgreSQL accorde aussi EXECUTE à PUBLIC par
-- défaut (non révocable par schéma) : toute nouvelle fonction doit donc
-- continuer d'inclure explicitement
--   revoke execute on function ... from public, anon, authenticated;
-- puis un grant ciblé si elle doit être appelée depuis le navigateur.
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;

-- Recharge le cache de schéma PostgREST (droits pris en compte immédiatement).
notify pgrst, 'reload schema';
