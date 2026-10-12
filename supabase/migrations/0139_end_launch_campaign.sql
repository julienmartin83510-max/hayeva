-- 0139 — Fin de l'opération « Grand jeu de lancement HAYEVA ».
--
-- Le site ne présente plus aucune offre de lancement (section d'accueil,
-- badge de réservation, règlement, page d'administration retirés). Côté
-- base, l'opération est CLOSE sans rien effacer :
--   * la fenêtre d'éligibilité (launch_campaign_settings, table créée hors
--     dépôt) est fermée à la date d'application : aucune nouvelle
--     réservation ne crée de participation ;
--   * les deux déclencheurs sur bookings sont DÉSACTIVÉS (pas supprimés) :
--     plus aucune écriture dans launch_campaign_entries ;
--   * le tirage (admin_run_launch_draw) et les actions de revue ne sont plus
--     appelables depuis le site ;
--   * l'historique est intégralement conservé : launch_campaign_entries,
--     launch_contest_draws, launch_contest_winners, fonctions et réglages
--     restent en place (consultables en SQL, réversible).
-- Aucune réservation, aucun tarif, aucun parrainage, aucune fidélité n'est
-- modifié.
--
-- Retour arrière (si un jour souhaité) :
--   alter table public.bookings enable trigger trg_launch_campaign_on_booking_insert;
--   alter table public.bookings enable trigger trg_launch_campaign_on_booking_status_change;
--   update public.launch_campaign_settings set ends_at = '<ancienne date>' where id;
--   grant execute on function public.<fonction>(...) to authenticated;

do $$
begin
  if to_regclass('public.launch_campaign_settings') is not null then
    update public.launch_campaign_settings
       set ends_at = least(ends_at, now()), updated_at = now()
     where id;
  end if;
end $$;

do $$
declare t text;
begin
  foreach t in array array['trg_launch_campaign_on_booking_insert', 'trg_launch_campaign_on_booking_status_change'] loop
    if exists (select 1 from pg_trigger where tgrelid = 'public.bookings'::regclass and tgname = t and not tgisinternal) then
      execute format('alter table public.bookings disable trigger %I', t);
    end if;
  end loop;
end $$;

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
