-- RETOUR ARRIÈRE de 0139 (fin du « Grand jeu de lancement »).
-- À n'exécuter QUE sur décision explicite, en un seul bloc (transaction).
-- Restaure exactement l'état sauvegardé dans launch_campaign_closure_0139 :
-- fin de fenêtre d'éligibilité, état des 2 déclencheurs, droits d'exécution
-- des 5 fonctions du jeu. Aucune participation n'ayant été supprimée par
-- 0139, il n'y a rien d'autre à restaurer.
begin;

do $$
declare
  c public.launch_campaign_closure_0139%rowtype;
  k text; v text; g jsonb; r text;
begin
  select * into c from public.launch_campaign_closure_0139 where id;
  if not found then
    raise exception 'Sauvegarde 0139 absente : retour arrière impossible (0139 n''a pas été appliquée ?).';
  end if;

  if to_regclass('public.launch_campaign_settings') is not null and c.previous_ends_at is not null then
    update public.launch_campaign_settings set ends_at = c.previous_ends_at, updated_at = now() where id;
  end if;

  for k, v in select * from jsonb_each_text(c.previous_triggers) loop
    execute format('alter table public.bookings %s trigger %I',
                   case when v = 'D' then 'disable' else 'enable' end, k);
  end loop;

  for k, g in select * from jsonb_each(c.previous_grants) loop
    foreach r in array array['public', 'anon', 'authenticated'] loop
      if (g ->> r)::boolean then
        execute format('grant execute on function %s to %s', k, r);
      end if;
    end loop;
  end loop;
end $$;

drop table public.launch_campaign_closure_0139;

commit;
