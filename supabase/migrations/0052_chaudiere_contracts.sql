-- ============================================================
-- Contrat annuel "HAYEVA Sérénité" chaudière (gaz + fioul).
-- ============================================================
-- PUREMENT ADDITIF. Aucune donnée existante modifiée/supprimée. L'entretien
-- ponctuel (services existants chauffage-chaudiere-*) n'est pas touché :
-- le contrat est une offre EN PLUS, pas un remplacement.
--
-- LIMITES ASSUMÉES (voir rapport) :
-- - Aucun paiement en ligne n'existe sur ce site (CGV actuelles : "Aucun
--   prélèvement en ligne n'est effectué"). Le contrat est donc "souscrit"
--   (status='pending') puis activé par un admin après encaissement hors
--   ligne (carte/espèces/chèque/virement, comme le reste du site) — jamais
--   un vrai encaissement carte simulé ici.
-- - renewal_type par défaut 'manual' UNIQUEMENT. La reconduction
--   automatique n'est JAMAIS activée par le système lui-même (voir section
--   14 du cahier des charges : droit de la consommation français non
--   improvisé ici) — l'architecture la permet, rien ne l'active seule.

-- ------------------------------------------------------------
-- contract_products : tarifs des 4 offres, ADMINISTRABLES depuis l'admin
-- (jamais codés en dur côté frontend). energy_type/contract_type forment
-- la clé fonctionnelle.
-- ------------------------------------------------------------
create table if not exists contract_products (
  id uuid primary key default gen_random_uuid(),
  contract_type text not null check (contract_type in ('ponctuel', 'serenite')),
  energy_type text not null check (energy_type in ('gaz', 'fioul')),
  price_cents integer not null check (price_cents >= 0),
  payment_frequency text not null default 'annuel' check (payment_frequency in ('annuel', 'mensuel')),
  is_active boolean not null default true,
  updated_at timestamptz not null default now(),
  unique (contract_type, energy_type)
);

alter table contract_products enable row level security;
create policy "contract_products: public read active" on contract_products
  for select using (is_active);
create policy "contract_products: admin full access" on contract_products
  for all using (is_admin()) with check (is_admin());

insert into contract_products (contract_type, energy_type, price_cents) values
  ('ponctuel', 'gaz', 12900),
  ('ponctuel', 'fioul', 15900),
  ('serenite', 'gaz', 15900),
  ('serenite', 'fioul', 18900)
on conflict (contract_type, energy_type) do nothing;

-- ------------------------------------------------------------
-- service_contracts : le contrat lui-même, rattaché à UNE chaudière.
-- ------------------------------------------------------------
create table if not exists service_contracts (
  id uuid primary key default gen_random_uuid(),
  customer_user_id uuid not null references auth.users(id) on delete cascade,
  equipment_id uuid not null references customer_equipment(id) on delete restrict,
  contract_type text not null default 'serenite' check (contract_type in ('serenite')),
  energy_type text not null check (energy_type in ('gaz', 'fioul')),
  status text not null default 'pending' check (status in (
    'pending', 'active', 'payment_failed', 'expiring', 'cancelled', 'expired'
  )),
  start_date date,
  end_date date,
  annual_price_cents integer not null,
  payment_frequency text not null default 'annuel' check (payment_frequency in ('annuel', 'mensuel')),
  renewal_type text not null default 'manual' check (renewal_type in ('manual', 'automatic')),
  cancellation_date date,
  cancellation_reason text,
  terms_version text not null,
  terms_accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column service_contracts.renewal_type is 'Défaut et seule valeur jamais activée automatiquement par le système : ''manual''. ''automatic'' existe pour permettre une future reconduction tacite UNE FOIS le parcours/CGV validés juridiquement (droit de la consommation français) — ne jamais l''activer par défaut ni en masse depuis le code.';

create index if not exists idx_service_contracts_customer on service_contracts(customer_user_id);
create index if not exists idx_service_contracts_equipment on service_contracts(equipment_id);
create index if not exists idx_service_contracts_status on service_contracts(status);
create index if not exists idx_service_contracts_end_date on service_contracts(end_date);

alter table service_contracts enable row level security;
create policy "service_contracts: customer sees own" on service_contracts
  for select using (customer_user_id = auth.uid());
create policy "service_contracts: admin full access" on service_contracts
  for all using (is_admin()) with check (is_admin());
-- Le client peut créer sa propre demande de contrat (status='pending'
-- uniquement — jamais s'auto-activer) et accepter le renouvellement.
create policy "service_contracts: customer creates own pending" on service_contracts
  for insert with check (customer_user_id = auth.uid() and status = 'pending');

-- ------------------------------------------------------------
-- contract_events : historique (section 5). Jamais de ligne modifiée après
-- coup — un événement est un fait, pas un état à corriger.
-- ------------------------------------------------------------
create table if not exists contract_events (
  id uuid primary key default gen_random_uuid(),
  contract_id uuid not null references service_contracts(id) on delete cascade,
  event_type text not null check (event_type in (
    'CREATED', 'PAYMENT_RECORDED', 'ACTIVATED', 'REMINDER_SENT',
    'RENEWED', 'CANCELLED', 'EXPIRED', 'PAYMENT_FAILED'
  )),
  detail text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table contract_events enable row level security;
create policy "contract_events: customer sees own contract events" on contract_events
  for select using (
    contract_id in (select id from service_contracts where customer_user_id = auth.uid())
  );
create policy "contract_events: admin full access" on contract_events
  for all using (is_admin()) with check (is_admin());

create index if not exists idx_contract_events_contract on contract_events(contract_id);

-- ------------------------------------------------------------
-- contract_reminder_config : délais de rappel configurables depuis l'admin
-- (section 10) — jamais "365 jours" codé en dur.
-- ------------------------------------------------------------
create table if not exists contract_reminder_config (
  id uuid primary key default gen_random_uuid(),
  reminder_1_days integer not null default 30,
  reminder_2_days integer not null default 14,
  reminder_final_days integer not null default 3,
  updated_at timestamptz not null default now()
);

alter table contract_reminder_config enable row level security;
create policy "contract_reminder_config: admin full access" on contract_reminder_config
  for all using (is_admin()) with check (is_admin());

insert into contract_reminder_config (reminder_1_days, reminder_2_days, reminder_final_days)
select 30, 14, 3
where not exists (select 1 from contract_reminder_config);

-- ------------------------------------------------------------
-- Rattache une intervention à un contrat (nullable — un entretien ponctuel
-- n'a pas de contrat). Permet "dernier/prochain entretien" sur la carte
-- contrat et la comparaison N/N-1 sur le même équipement.
-- ------------------------------------------------------------
alter table interventions add column if not exists contract_id uuid references service_contracts(id) on delete set null;
create index if not exists idx_interventions_contract on interventions(contract_id);

-- Rattache une réservation de dépannage à un contrat actif (section 8) —
-- permet à l'admin de voir "demande liée à un contrat" et d'honorer le
-- déplacement offert / la priorité, sans dupliquer le système de réservation
-- existant.
alter table bookings add column if not exists contract_id uuid references service_contracts(id) on delete set null;
create index if not exists idx_bookings_contract on bookings(contract_id);

-- ------------------------------------------------------------
-- Attestation réglementaire, DISTINCTE du compte rendu commercial déjà
-- existant (section 13) — jamais confondue avec une facture/un devis.
-- ------------------------------------------------------------
create table if not exists intervention_attestations (
  id uuid primary key default gen_random_uuid(),
  intervention_id uuid not null references interventions(id) on delete cascade,
  attestation_number text not null unique,
  generated_at timestamptz not null default now(),
  pdf_url text
);

alter table intervention_attestations enable row level security;
create policy "intervention_attestations: customer sees own" on intervention_attestations
  for select using (
    intervention_id in (
      select i.id from interventions i join bookings b on b.id = i.booking_id
      where b.customer_user_id = auth.uid()
    )
  );
create policy "intervention_attestations: admin full access" on intervention_attestations
  for all using (is_admin()) with check (is_admin());

create index if not exists idx_intervention_attestations_intervention on intervention_attestations(intervention_id);
