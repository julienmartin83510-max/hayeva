-- ============================================================
-- Ajout du SIRET (facultatif) à l'inscription professionnelle
-- ============================================================
-- professional_accounts.siret existe déjà depuis 0001_init.sql (colonne
-- nullable, contrainte de format 14 chiffres pour la France, index unique
-- partiel anti-doublon) mais n'était pas encore relié au formulaire
-- d'inscription ni à create_professional_account(). Extension non
-- destructive : aucune table recréée, aucune donnée existante affectée, les
-- comptes professionnels déjà créés (siret = null) continuent de fonctionner
-- à l'identique.
--
-- p_siret est ajouté en dernier paramètre, avec une valeur par défaut null :
-- la signature change néanmoins pour Postgres (nombre de paramètres), donc
-- l'ancienne fonction à 3 paramètres est explicitement supprimée pour éviter
-- toute ambiguïté de surcharge lors des appels RPC.
drop function if exists create_professional_account(text, text, text);

create or replace function create_professional_account(
  p_legal_name text,
  p_activity_type text default null,
  p_phone text default null,
  p_siret text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_account_id uuid;
begin
  if v_uid is null then
    raise exception 'Authentification requise.';
  end if;

  if exists (select 1 from profiles where user_id = v_uid) then
    raise exception 'Ce compte a déjà un profil.';
  end if;

  begin
    insert into professional_accounts (created_by, legal_name, activity_type, phone, siret)
    values (v_uid, p_legal_name, p_activity_type, p_phone, nullif(trim(p_siret), ''))
    returning id into v_account_id;
  exception
    when unique_violation then
      raise exception 'Ce numéro SIRET est déjà associé à un compte professionnel.';
  end;

  insert into professional_members (professional_account_id, user_id, role)
  values (v_account_id, v_uid, 'owner');

  insert into profiles (user_id, email, global_role)
  select v_uid, email, 'professional' from auth.users where id = v_uid;

  return v_account_id;
end;
$$;

revoke all on function create_professional_account(text, text, text, text) from public;
grant execute on function create_professional_account(text, text, text, text) to authenticated;
-- Même correctif de défense en profondeur qu'en 0001_init.sql (EXECUTE
-- accordé à anon par défaut à la création, indépendamment du REVOKE FROM
-- PUBLIC) : nécessaire à nouveau ici car la fonction a été recréée avec une
-- signature différente (paramètre p_siret ajouté).
revoke execute on function create_professional_account(text, text, text, text) from anon;
