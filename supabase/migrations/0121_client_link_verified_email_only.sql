-- 0121 — Sécurité : un COMPTE n'est jamais rattaché à une fiche client
-- existante sur la seule base d'un numéro de téléphone (ou d'un e-mail qui
-- n'est pas celui du compte). Avant ce correctif, s'inscrire avec le
-- téléphone de quelqu'un d'autre rattachait le nouveau compte à sa fiche
-- (et donc potentiellement à ses documents).
-- Règle : avec p_user_id, rattachement uniquement à une fiche portant
-- EXACTEMENT l'e-mail du compte Supabase Auth ; sinon nouvelle fiche.
-- Sans compte (fiches créées par l'admin), comportement inchangé
-- (dédoublonnage e-mail puis téléphone, sans aucun accès ouvert).

create or replace function public.find_or_create_client(p_user_id uuid, p_email text, p_phone text, p_first_name text, p_last_name text, p_address text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client_id uuid;
  v_email text := nullif(trim(lower(p_email)), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
  v_account_email text;
begin
  if p_user_id is not null then
    select id into v_client_id from clients where user_id = p_user_id and merged_into is null limit 1;
    if v_client_id is not null then return v_client_id; end if;

    select lower(email) into v_account_email from auth.users where id = p_user_id;
    if v_account_email is not null then
      select id into v_client_id from clients
       where lower(email) = v_account_email and merged_into is null and user_id is null
       order by created_at limit 1;
      if v_client_id is not null then
        update clients set user_id = p_user_id where id = v_client_id and user_id is null;
        return v_client_id;
      end if;
    end if;

    insert into clients (user_id, first_name, last_name, email, phone, address)
    values (p_user_id, p_first_name, p_last_name, coalesce(v_account_email, p_email), p_phone, p_address)
    returning id into v_client_id;
    return v_client_id;
  end if;

  if v_email is not null then
    select id into v_client_id from clients where lower(email) = v_email and merged_into is null order by created_at limit 1;
    if v_client_id is not null then return v_client_id; end if;
  end if;

  if v_phone is not null then
    select id into v_client_id from clients
      where regexp_replace(coalesce(phone, ''), '[^0-9+]', '', 'g') = v_phone and merged_into is null
      order by created_at limit 1;
    if v_client_id is not null then return v_client_id; end if;
  end if;

  insert into clients (user_id, first_name, last_name, email, phone, address)
  values (null, p_first_name, p_last_name, p_email, p_phone, p_address)
  returning id into v_client_id;
  return v_client_id;
end;
$$;
