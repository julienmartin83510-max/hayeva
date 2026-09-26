-- ============================================================
-- Correctif — sélection d'option devis silencieusement ignorée
-- ============================================================
-- Bug trouvé en testant réellement le parcours devis (tâche 13) : après
-- select_quote_option(), selected_option_id était bien enregistré mais
-- subtotal_cents/total_cents restaient à 0. Cause : le trigger existant
-- trg_protect_quote_fields (0001_init.sql, protect_quote_invoice_fields())
-- réécrit ces colonnes avec leur ancienne valeur sur TOUT UPDATE, sauf si
-- is_admin() ou auth.role() = 'service_role' — or auth.role()/is_admin()
-- lisent l'IDENTITÉ DE L'APPELANT INITIAL (le client), jamais changée par
-- SECURITY DEFINER (qui ne change que les droits d'exécution, pas les
-- claims JWT) : un client authentifié appelant select_quote_option()/
-- accept_quote() ne satisfait ni l'un ni l'autre, donc le trigger annule
-- silencieusement la mise à jour du montant — la protection fonctionne
-- comme prévu contre une écriture directe, mais bloque aussi ce chemin
-- légitime et déjà entièrement validé côté serveur (ownership, statut du
-- devis, montant relu depuis quote_options — jamais depuis le client).
--
-- Correctif : un drapeau de transaction (set_config, local=true → jamais
-- persistant, jamais visible en dehors de cette transaction) que ces deux
-- RPC activent juste avant leur UPDATE, et que le trigger accepte comme
-- 3ᵉ cas de confiance — en plus de is_admin()/service_role, jamais à la
-- place. Un client ne peut pas positionner ce drapeau lui-même (aucun
-- accès direct à set_config exposé), donc pas de nouvelle faille : seules
-- ces deux fonctions, déjà elles-mêmes protégées (vérifications
-- d'appartenance et de statut avant tout UPDATE), peuvent l'activer.

create or replace function protect_quote_invoice_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (
    is_admin()
    or auth.role() = 'service_role'
    or coalesce(current_setting('app.bypass_quote_protect', true), '') = 'on'
  ) then
    new.status := old.status;
    new.subtotal_cents := old.subtotal_cents;
    new.travel_fee_cents := old.travel_fee_cents;
    new.discount_cents := old.discount_cents;
    new.total_cents := old.total_cents;
  end if;
  return new;
end;
$$;
revoke all on function protect_quote_invoice_fields() from public;

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

  perform set_config('app.bypass_quote_protect', 'on', true);
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

  perform set_config('app.bypass_quote_protect', 'on', true);
  update quotes set status = 'ACCEPTED', accepted_at = now() where id = p_quote_id;

  return query select p_quote_id, 'ACCEPTED'::text, v_quote.total_cents;
end;
$$;
revoke all on function accept_quote(uuid) from public;
grant execute on function accept_quote(uuid) to authenticated;

-- Corrige les devis déjà "sélectionnés" pendant la fenêtre de ce bug (le
-- test réel de cette tâche) : recalcule subtotal_cents/total_cents pour
-- tout devis SENT dont selected_option_id est renseigné mais dont le total
-- n'a pas suivi.
update quotes q
set subtotal_cents = o.total_cents,
    total_cents = o.total_cents + coalesce(q.travel_fee_cents, 0) - coalesce(q.discount_cents, 0)
from quote_options o
where q.selected_option_id = o.id
  and q.status = 'SENT'
  and q.total_cents = 0;
