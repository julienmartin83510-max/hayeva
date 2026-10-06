-- Administration : modification du code d'un parrain existant (ex. code
-- généré automatiquement CLEMENT40 → CLEMENT01). Les parrainages déjà
-- rattachés ne changent pas (liés au client, pas au texte du code) ; un
-- code déjà utilisé par un autre parrain ou dans l'historique est refusé.
-- Un code fixé par l'administration n'est plus modifiable par l'utilisateur.
create or replace function public.admin_set_referrer_code(p_client_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if v_code !~ '^[A-Z0-9]{6,12}$' or v_code !~ '[A-Z]' then return jsonb_build_object('ok', false, 'error', 'FORMAT'); end if;
  if not exists (select 1 from referral_codes where client_id = p_client_id) then return jsonb_build_object('ok', false, 'error', 'INTROUVABLE'); end if;
  if exists (select 1 from referral_codes where code = v_code and client_id <> p_client_id)
     or exists (select 1 from referrals where code_used = v_code and referrer_client_id <> p_client_id) then
    return jsonb_build_object('ok', false, 'error', 'CODE_EXISTANT');
  end if;
  begin
    update referral_codes set code = v_code, created_by = coalesce(created_by, auth.uid()), updated_at = now() where client_id = p_client_id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'CODE_EXISTANT');
  end;
  insert into referral_events (event, detail) values ('ADMIN_CODE_CHANGED', jsonb_build_object('client_id', p_client_id, 'code', v_code, 'by', auth.uid()));
  return jsonb_build_object('ok', true, 'code', v_code, 'link', 'https://hayeva.fr/rdv?ref=' || v_code);
end;
$$;
revoke all on function public.admin_set_referrer_code(uuid, text) from public, anon;
grant execute on function public.admin_set_referrer_code(uuid, text) to authenticated;
