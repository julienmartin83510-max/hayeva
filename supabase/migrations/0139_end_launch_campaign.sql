-- 0139 — Fin de l'opération « Grand jeu de lancement HAYEVA ».
--
-- Le site ne présente plus aucune offre de lancement (section d'accueil,
-- badge de réservation, règlement, page d'administration retirés). Côté
-- base, l'opération est CLOSE sans rien effacer :
--   * sauvegarde préalable, dans launch_campaign_closure_0139, de tout ce que
--     la migration change (fin de fenêtre, état des déclencheurs, droits
--     d'exécution) : le retour arrière (supabase/rollback/0139_rollback.sql)
--     restaure exactement l'état d'avant ;
--   * la fenêtre d'éligibilité (launch_campaign_settings, table créée hors
--     dépôt) est fermée à la date d'application : aucune nouvelle
--     réservation ne crée de participation ;
--   * les deux déclencheurs sur bookings sont DÉSACTIVÉS (pas supprimés) :
--     plus aucune écriture dans launch_campaign_entries ;
--   * le tirage et les actions de revue ne sont plus appelables depuis le
--     site (droits retirés à anon/authenticated) ;
--   * l'historique est intégralement conservé : launch_campaign_entries,
--     launch_contest_draws, launch_contest_winners, réglages et fonctions.
-- Aucune réservation, aucun montant, aucun tarif, aucun parrainage, aucune
-- fidélité n'est modifié.

-- 1) Sauvegarde de l'état actuel (une seule fois : rejouer la migration ne
--    remplace jamais la sauvegarde d'origine).
create table if not exists public.launch_campaign_closure_0139 (
  id boolean primary key default true check (id),
  closed_at timestamptz not null default now(),
  previous_ends_at timestamptz,
  previous_triggers jsonb not null,
  previous_grants jsonb not null
);
alter table public.launch_campaign_closure_0139 enable row level security;
revoke all on table public.launch_campaign_closure_0139 from public, anon, authenticated;

insert into public.launch_campaign_closure_0139 (previous_ends_at, previous_triggers, previous_grants)
select
  case when to_regclass('public.launch_campaign_settings') is not null
       then (select ends_at from public.launch_campaign_settings where id) end,
  coalesce((select jsonb_object_agg(tgname, tgenabled::text) from pg_trigger
             where tgrelid = 'public.bookings'::regclass and not tgisinternal
               and tgname in ('trg_launch_campaign_on_booking_insert', 'trg_launch_campaign_on_booking_status_change')), '{}'::jsonb),
  coalesce((select jsonb_object_agg(p.oid::regprocedure::text,
                     jsonb_build_object('public', has_function_privilege('public', p.oid, 'execute'),
                                        'anon', has_function_privilege('anon', p.oid, 'execute'),
                                        'authenticated', has_function_privilege('authenticated', p.oid, 'execute')))
              from pg_proc p where p.pronamespace = 'public'::regnamespace
               and p.proname in ('admin_run_launch_draw', 'admin_launch_draw_readiness', 'admin_resolve_launch_entry',
                                 'admin_flag_launch_entry_for_review', 'get_my_launch_entry_statuses')), '{}'::jsonb)
on conflict (id) do nothing;

-- 2) Fermeture de la fenêtre d'éligibilité.
do $$
begin
  if to_regclass('public.launch_campaign_settings') is not null then
    update public.launch_campaign_settings
       set ends_at = least(ends_at, now()), updated_at = now()
     where id;
  end if;
end $$;

-- 3) Déclencheurs désactivés (conservés).
do $$
declare t text;
begin
  foreach t in array array['trg_launch_campaign_on_booking_insert', 'trg_launch_campaign_on_booking_status_change'] loop
    if exists (select 1 from pg_trigger where tgrelid = 'public.bookings'::regclass and tgname = t and not tgisinternal) then
      execute format('alter table public.bookings disable trigger %I', t);
    end if;
  end loop;
end $$;

-- 4) Fonctions du jeu inaccessibles depuis le site (conservées).
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('admin_run_launch_draw', 'admin_launch_draw_readiness', 'admin_resolve_launch_entry',
                                'admin_flag_launch_entry_for_review', 'get_my_launch_entry_statuses')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;
