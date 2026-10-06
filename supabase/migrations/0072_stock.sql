-- HAYEVA Pro — STOCK de pièces.
--
-- stock_items : pièces réellement détenues (nom, référence, marque,
-- fournisseur, prix achat/vente, quantité, seuil d'alerte). Peut être relié à
-- une fiche du catalogue fournisseur existant (supplier_products) pour
-- préparer le branchement futur de catalogues fournisseurs — aucune API
-- fournisseur n'est simulée ici.
-- stock_movements : journal de chaque entrée/sortie (traçabilité).
-- intervention_parts.stock_item_id : quand une pièce utilisée en
-- intervention provient du stock, sa quantité est déduite automatiquement
-- (et ré-créditée si la ligne est supprimée).
-- Accès : administration uniquement (is_admin()).

create table if not exists public.stock_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  reference text,
  brand text,
  supplier text,
  supplier_product_id uuid references public.supplier_products(id) on delete set null,
  category text,
  unit text not null default 'u',
  purchase_price_cents integer,
  sale_price_cents integer,
  quantity numeric(12,2) not null default 0,
  min_quantity numeric(12,2) not null default 0,
  location text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists stock_items_name_idx on public.stock_items (lower(name));
alter table public.stock_items enable row level security;
create policy "stock_items: admin all" on public.stock_items for all using (is_admin()) with check (is_admin());

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  stock_item_id uuid not null references public.stock_items(id) on delete cascade,
  delta numeric(12,2) not null,
  reason text not null check (reason in ('entree', 'sortie_manuelle', 'intervention', 'annulation_intervention', 'inventaire')),
  intervention_id uuid references public.interventions(id) on delete set null,
  intervention_part_id uuid,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists stock_movements_item_idx on public.stock_movements (stock_item_id, created_at desc);
alter table public.stock_movements enable row level security;
create policy "stock_movements: admin read" on public.stock_movements for select using (is_admin());
create policy "stock_movements: admin insert" on public.stock_movements for insert with check (is_admin());

alter table public.intervention_parts add column if not exists stock_item_id uuid references public.stock_items(id) on delete set null;

-- Mouvement de stock appliqué de façon atomique (quantité + journal).
create or replace function public.apply_stock_movement()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update stock_items set quantity = quantity + new.delta, updated_at = now() where id = new.stock_item_id;
  return new;
end;
$$;
create trigger trg_stock_movements_apply
  after insert on public.stock_movements
  for each row execute function public.apply_stock_movement();

-- Pièce utilisée en intervention → sortie de stock automatique.
create or replace function public.stock_on_intervention_part()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.stock_item_id is not null then
    insert into stock_movements (stock_item_id, delta, reason, intervention_id, intervention_part_id)
    values (old.stock_item_id, coalesce(old.quantity, 0), 'annulation_intervention', old.intervention_id, old.id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.stock_item_id is not null then
    insert into stock_movements (stock_item_id, delta, reason, intervention_id, intervention_part_id)
    values (new.stock_item_id, -coalesce(new.quantity, 0), 'intervention', new.intervention_id, new.id);
  end if;
  return coalesce(new, old);
end;
$$;
create trigger trg_intervention_parts_stock
  after insert or delete or update of stock_item_id, quantity on public.intervention_parts
  for each row execute function public.stock_on_intervention_part();
revoke all on function public.apply_stock_movement() from public, anon, authenticated;
revoke all on function public.stock_on_intervention_part() from public, anon, authenticated;
