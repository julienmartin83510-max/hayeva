-- ============================================================
-- Correctif — "column reference quote_id is ambiguous"
-- ============================================================
-- Bug trouvé en testant réellement le parcours devis (tâche 13) : dans
-- select_quote_option(), returns table(quote_id uuid, ...) déclare une
-- variable PL/pgSQL nommée quote_id, qui entre en conflit avec la colonne
-- quote_options.quote_id référencée sans préfixe dans la clause WHERE de la
-- fonction (select ... where id = p_option_id and quote_id = p_quote_id).
-- Postgres ne sait plus lequel des deux "quote_id" est visé -> erreur.
--
-- Correctif : renomme les colonnes de sortie (out_quote_id/out_*) pour ne
-- plus jamais entrer en collision avec un nom de colonne réel, et qualifie
-- explicitement quote_options.quote_id dans la requête concernée. Même
-- correctif appliqué par précaution à accept_quote() (pas de bug constaté
-- là, mais même risque structurel à éviter).

-- Le nom des colonnes de sortie change : create or replace ne suffit pas
-- (Postgres refuse de changer la forme du type de retour d'une fonction
-- existante), il faut la supprimer puis la recréer.
drop function if exists select_quote_option(uuid, uuid);
drop function if exists accept_quote(uuid);

create or replace function select_quote_option(p_quote_id uuid, p_option_id uuid)
returns table(out_quote_id uuid, out_total_cents integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_quote quotes%rowtype;
  v_option quote_options%rowtype;
begin
  select * into v_quote from quotes where id = p_quote_id;
  if not found then
    raise exception 'Devis introuvable.';
  end if;
  if v_quote.status <> 'SENT' then
    raise exception 'Ce devis ne peut plus être modifié.';
  end if;
  if not (
    coalesce(v_quote.customer_user_id = v_uid, false)
    or (v_quote.professional_account_id is not null and v_quote.professional_account_id in (select my_professional_account_ids()))
  ) then
    raise exception 'Ce devis ne vous appartient pas.';
  end if;

  select * into v_option from quote_options where id = p_option_id and quote_options.quote_id = p_quote_id;
  if not found then
    raise exception 'Cette option ne fait pas partie de ce devis.';
  end if;

  update quotes
    set selected_option_id = v_option.id,
        subtotal_cents = v_option.total_cents,
        total_cents = v_option.total_cents + coalesce(quotes.travel_fee_cents, 0) - coalesce(quotes.discount_cents, 0)
    where id = p_quote_id;

  return query select p_quote_id, (v_option.total_cents + coalesce(v_quote.travel_fee_cents, 0) - coalesce(v_quote.discount_cents, 0));
end;
$$;
revoke all on function select_quote_option(uuid, uuid) from public;
grant execute on function select_quote_option(uuid, uuid) to authenticated;

create or replace function accept_quote(p_quote_id uuid)
returns table(out_quote_id uuid, out_status text, out_total_cents integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_quote quotes%rowtype;
begin
  select * into v_quote from quotes where id = p_quote_id;
  if not found then
    raise exception 'Devis introuvable.';
  end if;
  if v_quote.status <> 'SENT' then
    raise exception 'Ce devis ne peut plus être accepté.';
  end if;
  if not (
    coalesce(v_quote.customer_user_id = v_uid, false)
    or (v_quote.professional_account_id is not null and v_quote.professional_account_id in (select my_professional_account_ids()))
  ) then
    raise exception 'Ce devis ne vous appartient pas.';
  end if;
  if v_quote.selected_option_id is null then
    raise exception 'Merci de sélectionner une solution avant d''accepter le devis.';
  end if;

  update quotes set status = 'ACCEPTED', accepted_at = now() where id = p_quote_id;

  return query select p_quote_id, 'ACCEPTED'::text, v_quote.total_cents;
end;
$$;
revoke all on function accept_quote(uuid) from public;
grant execute on function accept_quote(uuid) to authenticated;
