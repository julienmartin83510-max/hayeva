-- ============================================================
-- Outil interne « Chiffrage / Devis » — admin uniquement
-- ============================================================
-- Trois tables entièrement séparées du catalogue public (services,
-- service_packs) et du barème de déplacement public (travel_settings) :
-- aucun risque de modifier un prix affiché sur le site en configurant cet
-- outil. Même pattern RLS que travel_settings/analytics_events (is_admin(),
-- déjà testé en direct cette session — tentative d'élévation de privilège
-- bloquée).

-- ------------------------------------------------------------
-- Réglages du calculateur (taux horaires, déplacement, TVA...)
create table quote_calc_settings (
  id boolean primary key default true,
  constraint quote_calc_settings_singleton check (id = true),
  hourly_rate_particulier_cents integer not null default 6000,
  hourly_rate_professionnel_cents integer not null default 6000,
  travel_rate_particulier_cents integer not null default 70,
  travel_rate_professionnel_cents integer not null default 70,
  minimum_intervention_cents integer not null default 0,
  default_supply_markup_percent numeric(5,2) not null default 20,
  -- Ne jamais supposer un régime : réglage explicite, faux par défaut
  -- (franchise en base courante pour une activité qui démarre).
  vat_applicable boolean not null default false,
  vat_rate_percent numeric(5,2) not null default 20,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into quote_calc_settings (id) values (true);

alter table quote_calc_settings enable row level security;
create policy "quote_calc_settings: admin read" on quote_calc_settings
  for select using (is_admin());
create policy "quote_calc_settings: admin update" on quote_calc_settings
  for update using (is_admin()) with check (is_admin());
revoke all on table quote_calc_settings from anon, authenticated;
grant select, update on table quote_calc_settings to authenticated;

-- ------------------------------------------------------------
-- Bibliothèque « aide au prix » — interventions fréquentes, alimentée par
-- l'admin au fil du temps.
create table quote_calc_catalog (
  id uuid primary key default gen_random_uuid(),
  domain text not null check (domain in ('plomberie','chauffage','climatisation','autre')),
  customer_type text not null check (customer_type in ('particulier','professionnel')),
  name text not null,
  price_low_cents integer,
  price_typical_cents integer,
  price_high_cents integer,
  typical_duration_minutes integer,
  typical_supplies text,
  notes text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index quote_calc_catalog_domain_idx on quote_calc_catalog (domain, customer_type, is_active);

alter table quote_calc_catalog enable row level security;
create policy "quote_calc_catalog: admin all" on quote_calc_catalog
  for all using (is_admin()) with check (is_admin());
revoke all on table quote_calc_catalog from anon, authenticated;
grant select, insert, update, delete on table quote_calc_catalog to authenticated;

-- ------------------------------------------------------------
-- Historique des chiffrages sauvegardés.
create table quote_calc_history (
  id uuid primary key default gen_random_uuid(),
  customer_type text not null check (customer_type in ('particulier','professionnel')),
  domain text,
  intervention_label text not null,
  client_name text,
  labor_minutes integer,
  technician_count integer,
  hourly_rate_cents integer,
  labor_cents integer not null default 0,
  travel_km numeric(6,1),
  travel_cents integer not null default 0,
  supplies_cents integer not null default 0,
  other_fees_cents integer not null default 0,
  discount_cents integer not null default 0,
  vat_applicable boolean not null default false,
  vat_rate_percent numeric(5,2),
  total_ht_cents integer not null default 0,
  total_ttc_cents integer not null default 0,
  price_proposed_cents integer,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index quote_calc_history_created_idx on quote_calc_history (created_at desc);

alter table quote_calc_history enable row level security;
create policy "quote_calc_history: admin all" on quote_calc_history
  for all using (is_admin()) with check (is_admin());
revoke all on table quote_calc_history from anon, authenticated;
grant select, insert, update, delete on table quote_calc_history to authenticated;
