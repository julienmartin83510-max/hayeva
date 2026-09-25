-- ============================================================
-- Catalogue fournisseurs — table produit + règles de marge (tâche 14)
-- ============================================================
-- Portée volontairement limitée à ce qui est demandé maintenant : la table
-- produit et le calcul du prix de vente. PAS de connecteur CEDEO/Leroy
-- Merlin ici (aucune API inventée), pas de synchronisation automatique,
-- pas d'UI — ces briques viendront séparément une fois cette base validée.
--
-- SÉCURITÉ COMMERCIALE : purchase_price_cents, purchase_price_vat_rate,
-- supplier_url, margin_rule_id, last_sync_error et toute la table
-- margin_rules ne doivent JAMAIS être lisibles par un client. Contrairement
-- à ai_settings (qui a une vue publique ai_settings_public pour UNE colonne
-- sûre), le client n'a ici aucun besoin de lire supplier_products
-- directement : il ne voit jamais que quote_options, déjà entièrement
-- construite et testée (0026_quote_options_attachments.sql), qui capture
-- un SNAPSHOT (nom, référence, prix de vente, description) au moment où
-- l'admin ajoute le produit au devis — jamais une référence live vers ce
-- catalogue. Donc : accès table entièrement réservé à is_admin(), aucune
-- vue publique nécessaire, RLS la plus simple et la plus sûre possible.

create table margin_rules (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  category text check (category in ('plomberie', 'chauffage', 'climatisation', 'sanitaire', 'accessoire', 'autre')),
  rule_type text not null check (rule_type in ('multiplier', 'percentage', 'fixed_amount')),
  -- multiplier : ex 1.40 (prix HT x1,40) ; percentage : ex 40 (+40%) ;
  -- fixed_amount : montant ajouté en centimes (ex 1500 = +15,00€ HT).
  rule_value numeric(12, 4) not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

-- Trouve la règle la plus spécifique : une règle de catégorie l'emporte
-- toujours sur la règle générale (category is null), jamais l'inverse.
create or replace function find_margin_rule(p_category text)
returns margin_rules
language sql
stable
set search_path = public
as $$
  select * from margin_rules
  where is_active and (category = p_category or category is null)
  order by (category is not null) desc, sort_order asc
  limit 1;
$$;
revoke all on function find_margin_rule(text) from public;
grant execute on function find_margin_rule(text) to authenticated;

-- Calcule le prix de vente TTC à partir d'un prix d'achat HT + sa TVA +
-- la règle de marge applicable à la catégorie. Ne calcule JAMAIS une marge
-- sur un montant TTC par erreur (la TVA est toujours ajoutée en dernier,
-- après application de la marge sur le HT). Renvoie NULL si le prix
-- d'achat est inconnu OU si aucune règle de marge n'est configurée —
-- jamais un taux de marge deviné/inventé par défaut.
create or replace function compute_sale_price_cents(p_purchase_price_cents integer, p_vat_rate numeric, p_category text)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  v_rule margin_rules%rowtype;
  v_ht numeric;
begin
  if p_purchase_price_cents is null then
    return null;
  end if;
  select * into v_rule from find_margin_rule(p_category);
  if not found then
    return null;
  end if;

  v_ht := p_purchase_price_cents::numeric;
  if v_rule.rule_type = 'multiplier' then
    v_ht := v_ht * v_rule.rule_value;
  elsif v_rule.rule_type = 'percentage' then
    v_ht := v_ht * (1 + v_rule.rule_value / 100);
  elsif v_rule.rule_type = 'fixed_amount' then
    v_ht := v_ht + v_rule.rule_value;
  end if;

  return round(v_ht * (1 + coalesce(p_vat_rate, 0) / 100))::integer;
end;
$$;
revoke all on function compute_sale_price_cents(integer, numeric, text) from public;
grant execute on function compute_sale_price_cents(integer, numeric, text) to authenticated;

create table supplier_products (
  id uuid primary key default gen_random_uuid(),
  supplier text not null check (supplier in ('cedeo', 'leroy_merlin')),
  supplier_ref text not null,
  ean text,
  brand text,
  model text,
  category text not null check (category in ('plomberie', 'chauffage', 'climatisation', 'sanitaire', 'accessoire', 'autre')),
  name text not null,
  description text,
  photo_url text,
  -- Admin uniquement, jamais exposé au client (voir RLS plus bas).
  supplier_url text,
  purchase_price_cents integer,
  purchase_price_vat_rate numeric(5, 2) not null default 20,
  margin_rule_id uuid references margin_rules(id) on delete set null,
  -- Si renseigné, prend le pas sur le calcul automatique — un admin peut
  -- toujours fixer manuellement le prix d'un produit précis.
  manual_sale_price_cents integer,
  -- Calculé automatiquement (trigger ci-dessous), jamais désynchronisé
  -- manuellement — c'est la seule valeur que l'admin verra passer au
  -- client une fois le produit ajouté à un devis (par snapshot).
  sale_price_cents integer,
  availability text not null default 'unknown'
    check (availability in ('available', 'limited', 'unavailable', 'unknown')),
  -- Un produit indisponible ne doit plus être proposé dans un NOUVEAU
  -- devis (voir admin "Ajouter un produit", à construire séparément) —
  -- porté ici par is_active, jamais une suppression (l'historique des
  -- anciens devis ne dépend de toute façon jamais de cette table, voir
  -- snapshot quote_options).
  is_active boolean not null default true,
  last_synced_at timestamptz,
  last_sync_status text not null default 'never' check (last_sync_status in ('ok', 'error', 'never')),
  last_sync_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (supplier, supplier_ref)
);
create index supplier_products_category_idx on supplier_products (category, is_active);
create index supplier_products_supplier_idx on supplier_products (supplier, supplier_ref);

create or replace function supplier_product_recompute_sale_price()
returns trigger
language plpgsql
as $$
begin
  if new.manual_sale_price_cents is not null then
    new.sale_price_cents := new.manual_sale_price_cents;
  else
    new.sale_price_cents := compute_sale_price_cents(new.purchase_price_cents, new.purchase_price_vat_rate, new.category);
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger trg_supplier_product_recompute_sale_price
  before insert or update on supplier_products
  for each row execute function supplier_product_recompute_sale_price();

-- Recalcule tous les produits après un changement de règle de marge —
-- appelée explicitement par l'admin (bouton "Recalculer les prix" à
-- prévoir côté UI) plutôt qu'un trigger en cascade sur margin_rules : plus
-- prévisible, et une seule action claire plutôt qu'un recalcul silencieux
-- déclenché par la moindre modification de règle.
create or replace function recompute_all_supplier_sale_prices()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if not is_admin() then
    raise exception 'Réservé aux administrateurs.';
  end if;
  -- UPDATE apparemment "sans effet" : c'est délibéré. Il ne sert qu'à
  -- déclencher, sur chaque ligne, le trigger BEFORE UPDATE qui recalcule
  -- réellement sale_price_cents à partir des margin_rules actuelles.
  update supplier_products set updated_at = updated_at;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function recompute_all_supplier_sale_prices() from public;
grant execute on function recompute_all_supplier_sale_prices() to authenticated;

alter table margin_rules enable row level security;
create policy "margin_rules: admin only" on margin_rules
  for all using (is_admin()) with check (is_admin());
revoke all on table margin_rules from anon, authenticated;
grant select, insert, update, delete on table margin_rules to authenticated;

alter table supplier_products enable row level security;
create policy "supplier_products: admin only" on supplier_products
  for all using (is_admin()) with check (is_admin());
revoke all on table supplier_products from anon, authenticated;
grant select, insert, update, delete on table supplier_products to authenticated;
