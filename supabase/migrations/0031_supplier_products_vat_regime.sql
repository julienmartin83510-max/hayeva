-- ============================================================
-- Catalogue fournisseurs — régime de TVA configurable (correction avant
-- de poursuivre la tâche 14, demandée avant tout autre développement)
-- ============================================================
-- Ne duplique pas un nouveau réglage "régime TVA" : quote_calc_settings
-- (0021_admin_quote_calculator.sql) porte déjà exactement ce fait pour
-- HAYEVA — vat_applicable=false est déjà documenté comme "franchise en
-- base courante pour une activité qui démarre", vat_applicable=true comme
-- assujetti, vat_rate_percent son propre taux de facturation. Réutilisé
-- ici tel quel comme source unique de vérité du régime fiscal de HAYEVA,
-- jamais un second réglage qui pourrait diverger.
--
-- LOGIQUE ADAPTÉE AU RÉGIME (jamais "HT + marge + TVA" supposé par défaut) :
--   - Franchise en base (vat_applicable=false) : la TVA payée au
--     fournisseur n'est PAS récupérable -> le coût économique réel est le
--     TTC réellement payé. La marge s'applique sur ce TTC. HAYEVA elle-même
--     ne facture pas de TVA dans ce régime : le résultat EST le prix final
--     client, aucune TVA supplémentaire n'est ajoutée par-dessus.
--   - Assujetti (vat_applicable=true) : la TVA fournisseur est récupérable
--     -> le coût réel est le HT. La marge s'applique sur ce HT, puis la
--     TVA propre de HAYEVA (vat_rate_percent, potentiellement différente
--     du taux fournisseur) est ajoutée pour obtenir le TTC facturé.
--
-- Aucun effet rétroactif possible : quote_options (0026) est déjà un
-- SNAPSHOT figé au moment de l'envoi du devis, totalement indépendant de
-- supplier_products/margin_rules/quote_calc_settings après coup — changer
-- le régime ne peut recalculer que les FUTURS calculs (déclenchés par le
-- trigger sur supplier_products ou par recompute_all_supplier_sale_prices()),
-- jamais un devis déjà envoyé/accepté.

-- purchase_price_cents était déjà implicitement le montant HT ; renommé
-- pour lever toute ambiguïté maintenant que le TTC entre aussi en jeu.
alter table supplier_products rename column purchase_price_cents to purchase_price_ht_cents;

-- Conservé en plus du HT (jamais recalculé "à la volée" seulement) pour
-- que l'admin voie toujours HT/TVA/TTC fournisseur tels que fournis,
-- conformément à la demande explicite de tout conserver quand disponible.
alter table supplier_products
  add column purchase_price_ttc_cents integer generated always as (
    case when purchase_price_ht_cents is null then null
    else round(purchase_price_ht_cents * (1 + purchase_price_vat_rate / 100))::integer end
  ) stored;

-- Le nom du 1er paramètre reste p_purchase_price_cents (create or replace
-- ne permet pas de renommer un paramètre d'entrée, seulement d'en changer
-- le corps) — il désigne bien le montant HT, comme documenté ci-dessous.
create or replace function compute_sale_price_cents(p_purchase_price_cents integer, p_vat_rate numeric, p_category text)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  v_rule margin_rules%rowtype;
  v_settings quote_calc_settings%rowtype;
  v_cost_base numeric;
  p_purchase_price_ht_cents integer := p_purchase_price_cents; -- alias lisible, montant HT
begin
  if p_purchase_price_ht_cents is null then
    return null;
  end if;

  -- Jamais de régime supposé par défaut : si le réglage n'existe pas
  -- (ne devrait pas arriver, ligne singleton insérée par 0021), on
  -- n'invente rien et on renvoie NULL plutôt qu'un calcul HT+TVA par défaut.
  select * into v_settings from quote_calc_settings where id = true;
  if not found then
    return null;
  end if;

  select * into v_rule from find_margin_rule(p_category);
  if not found then
    return null;
  end if;

  if v_settings.vat_applicable then
    v_cost_base := p_purchase_price_ht_cents::numeric;
  else
    v_cost_base := p_purchase_price_ht_cents::numeric * (1 + coalesce(p_vat_rate, 0) / 100);
  end if;

  if v_rule.rule_type = 'multiplier' then
    v_cost_base := v_cost_base * v_rule.rule_value;
  elsif v_rule.rule_type = 'percentage' then
    v_cost_base := v_cost_base * (1 + v_rule.rule_value / 100);
  elsif v_rule.rule_type = 'fixed_amount' then
    v_cost_base := v_cost_base + v_rule.rule_value;
  end if;

  if v_settings.vat_applicable then
    return round(v_cost_base * (1 + coalesce(v_settings.vat_rate_percent, 0) / 100))::integer;
  else
    return round(v_cost_base)::integer;
  end if;
end;
$$;

-- Le trigger défini dans 0030 référence l'ancien nom de colonne
-- (purchase_price_cents) : redéfini ici avec le nouveau nom, sinon tout
-- INSERT/UPDATE sur supplier_products échouerait (colonne inexistante).
create or replace function supplier_product_recompute_sale_price()
returns trigger
language plpgsql
as $$
begin
  if new.manual_sale_price_cents is not null then
    new.sale_price_cents := new.manual_sale_price_cents;
  else
    new.sale_price_cents := compute_sale_price_cents(new.purchase_price_ht_cents, new.purchase_price_vat_rate, new.category);
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- Aucune ligne n'existe encore dans supplier_products à ce stade (table
-- créée dans 0030, catalogue pas encore alimenté) : rien à recalculer,
-- mais gardé par cohérence/idempotence si cette migration est relue plus tard.
update supplier_products set updated_at = updated_at;
