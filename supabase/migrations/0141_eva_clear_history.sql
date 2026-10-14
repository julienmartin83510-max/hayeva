-- 0141 — EVA : effacement, à la demande, du texte des conversations (RGPD).
-- L'administrateur connecté efface le CONTENU de ses échanges (phrase dite ou
-- tapée, paramètres de la question) ; les lignes restent pour les limites de
-- débit et les traces des actions proposées, confirmées ou annulées sont
-- conservées intactes (historique des opérations). Aucune autre donnée touchée.
create or replace function public.eva_clear_history()
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  update eva_journal set command = null, detail = '{}'::jsonb
   where actor_user_id = auth.uid() and outcome in ('ok', 'empty', 'refused', 'error')
     and (command is not null or detail <> '{}'::jsonb);
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'cleared', n);
end $$;
revoke all on function public.eva_clear_history() from public, anon;
grant execute on function public.eva_clear_history() to authenticated;
