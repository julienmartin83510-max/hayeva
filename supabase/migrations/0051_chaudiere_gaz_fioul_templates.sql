-- ============================================================
-- Fiches techniques complètes entretien chaudière GAZ et FIOUL.
-- ============================================================
-- PUREMENT ADDITIF : aucune ligne existante modifiée, anciens statuts et
-- anciennes interventions climatisation/plomberie/chauffage inchangés.

-- ------------------------------------------------------------
-- 5e statut de contrôle : "Non contrôlé / inaccessible" — distinct de
-- "Non applicable" (qui signifie : ce contrôle n'a pas de sens ici) ; celui-
-- ci signifie : le contrôle est pertinent mais n'a pas pu être réalisé
-- (accès impossible, outil manquant...). Jamais transformé en "Conforme".
-- ------------------------------------------------------------
alter table intervention_items drop constraint if exists intervention_items_status_check;
alter table intervention_items add constraint intervention_items_status_check
  check (status in ('OK', 'FUNCTIONAL', 'WATCH', 'INTERVENTION_RECOMMENDED', 'ANOMALY', 'NOT_APPLICABLE', 'NOT_CHECKED'));

-- ------------------------------------------------------------
-- Résultat d'intervention : ajoute "Mise à l'arrêt / sécurité", absent des
-- 6 résultats génériques posés en 0050 (nécessaire pour l'essai final
-- chaudière — une anomalie de sécurité gaz/fioul n'est ni "surveillance"
-- ni "devis complémentaire", c'est un arrêt immédiat de l'appareil).
-- ------------------------------------------------------------
alter table interventions drop constraint if exists interventions_completion_status_check;
alter table interventions add constraint interventions_completion_status_check
  check (completion_status in (
    'CONFORME', 'SURVEILLANCE', 'PROVISOIRE',
    'PIECE_A_COMMANDER', 'DEVIS_COMPLEMENTAIRE', 'NOUVELLE_INTERVENTION',
    'MISE_EN_SECURITE'
  ));

-- Résumé auto-généré à la finalisation, à partir UNIQUEMENT des contrôles
-- réellement renseignés (jamais une opération non cochée) — section 11 du
-- cahier des charges HAYEVA. Conservé séparément des observations libres du
-- technicien, qui restent éditables.
alter table interventions add column if not exists auto_summary text;

-- ------------------------------------------------------------
-- customer_equipment.specs : caractéristiques flexibles par catégorie
-- d'équipement (combustible, type de chaudière, n° de série, année,
-- puissance, mode de production...). JSONB plutôt que des colonnes rigides
-- qui n'auraient de sens que pour une chaudière — conservé d'une
-- intervention à l'autre et proposé automatiquement au technicien suivant.
-- ------------------------------------------------------------
alter table customer_equipment add column if not exists specs jsonb;

comment on column customer_equipment.specs is 'Caractéristiques libres selon equipment_type (ex. chaudière : {combustible, chaudiere_type, serial_number, year_approx, power_kw, production}). Jamais de valeur technique déduite/inventée par le système — uniquement ce que le technicien saisit.';

-- ------------------------------------------------------------
-- intervention_anomalies : liste structurée d'anomalies (section 8),
-- réutilisable pour tout métier, pas seulement chaudière. Même patron que
-- intervention_parts (0050) : rattachée directement à l'intervention,
-- admin/pro uniquement pour l'instant (incluse telle quelle dans le compte
-- rendu client généré côté edge function).
-- ------------------------------------------------------------
create table if not exists intervention_anomalies (
  id uuid primary key default gen_random_uuid(),
  intervention_id uuid not null references interventions(id) on delete cascade,
  equipment_label text,
  description text not null,
  severity text not null check (severity in ('INFO', 'WATCH', 'RECOMMENDED', 'SAFETY')),
  action text check (action in ('FIXED_ON_SITE', 'QUOTE_NEEDED', 'MONITOR', 'SAFETY_SHUTDOWN')),
  created_at timestamptz not null default now()
);

alter table intervention_anomalies enable row level security;

create policy "intervention_anomalies: pro or admin full access" on intervention_anomalies
  for all using (
    is_admin()
    or intervention_id in (
      select i.id from interventions i
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
  ) with check (
    is_admin()
    or intervention_id in (
      select i.id from interventions i
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
  );

create index if not exists idx_intervention_anomalies_intervention on intervention_anomalies(intervention_id);
