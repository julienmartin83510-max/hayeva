-- V2 phase 2 — CRM : étiquettes client, réservées à l'admin.
-- Table séparée (et non une colonne de clients) : la règle « clients: self
-- read » laisse un client lire sa propre ligne clients ; des étiquettes
-- internes (« mauvais payeur »…) ne doivent jamais lui être visibles.
--
-- NB : une colonne clients.tags a été créée puis abandonnée (vide, inutilisée) ;
-- sa suppression demande une approbation manuelle.

alter table public.clients add column if not exists tags text[] not null default '{}'::text[];
comment on column public.clients.tags is 'Inutilisée (remplacée par client_crm.tags, réservée à l''admin) — à supprimer.';

create table if not exists public.client_crm (
  client_id uuid primary key references public.clients(id) on delete cascade,
  tags text[] not null default '{}'::text[] check (cardinality(tags) <= 12),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.client_crm enable row level security;
create policy "client_crm: admin full access" on public.client_crm for all to authenticated using (public.is_admin()) with check (public.is_admin());
