-- ISOLATION D'UN PROJET SUPABASE DE TEST (jamais la production).
-- À exécuter UNE fois dans le projet de test, après les migrations.
-- Les déclencheurs et tâches planifiées des migrations appellent les fonctions
-- serveur de la PRODUCTION par leur adresse : ce script les redirige vers le
-- projet de test lui-même (ou les coupe), pour qu'aucun e-mail, SMS, rappel ou
-- synchronisation Apple ne parte vers de vrais clients.
-- Remplacer ci-dessous TEST_REF par l'identifiant du projet de test.
do $$
declare
  v_prod text := 'hvlzdsuyhrhaflwutwml';
  v_test text := 'TEST_REF';
  f record; n int := 0; j record;
begin
  -- Garde-fou : refuse de s'exécuter sur une base contenant de vrais clients.
  if v_test = 'TEST_REF' or v_test = v_prod then raise exception 'Renseignez l''identifiant du projet de TEST.'; end if;
  if exists (select 1 from clients where coalesce(email, '') !~* '@(test\.local|exemple\.test)$'
             and (user_id is null or user_id not in (select user_id from profiles where global_role = 'admin'))) then
    raise exception 'ARRÊT : cette base contient des clients réels. Ce script ne s''exécute que sur un projet de test vide.';
  end if;
  -- 1) Fonctions SQL contenant l'adresse de production → adresse du projet de test.
  for f in select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
            where s.nspname = 'public' and p.prosrc like '%' || v_prod || '%' loop
    execute replace(pg_get_functiondef(f.oid), v_prod, v_test); n := n + 1;
  end loop;
  -- 2) Tâches planifiées : toutes arrêtées (rappels, SMS) — inutiles en test.
  for j in select jobid from cron.job loop perform cron.unschedule(j.jobid); end loop;
  -- 3) Secret des appels internes : propre au projet de test (la production le refuse).
  update vault.secrets set secret = encode(extensions.gen_random_bytes(32), 'hex') where name = 'webhook_secret';
  -- 4) Contrôle : plus aucune référence à la production.
  if exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.prosrc like '%' || v_prod || '%') then
    raise exception 'Isolation incomplète.';
  end if;
  raise notice 'Projet de test isolé : % fonction(s) redirigée(s), tâches planifiées arrêtées.', n;
end $$;
