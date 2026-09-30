-- ============================================================
-- Fiches d'intervention adaptées au métier réel de la prestation.
-- ============================================================
-- CAUSE DU BUG : le frontend seedait TOUJOURS intervention_items avec
-- CLIM_CHECKLIST_TEMPLATE (une constante climatisation en dur), quelle que
-- soit la prestation réservée — "Remplacement mécanisme WC" affichait donc
-- "Filtres air intérieurs". La requête admin ne sélectionnait même pas
-- services.slug/category, donc le frontend n'avait aucun moyen de savoir
-- quel métier était concerné.
--
-- Cette migration prépare le stockage pour un catalogue de templates
-- multi-métiers (plomberie/chauffage/climatisation/sanitaire/multi/pro),
-- avec :
--   - un instantané du template utilisé (jamais réécrit rétroactivement si
--     le catalogue évolue plus tard — voir interventions.diagnostic_snapshot) ;
--   - des contrôles typés (status/text/number/boolean/select/textarea), pas
--     uniquement le triptyque OK/À surveiller/Anomalie qui ne convient pas à
--     un champ "Marque" ou "Pression (bar)" ;
--   - une section libre par contrôle (avant/contrôles/après) pour un
--     affichage organisé, sans surcharger la fiche ;
--   - une liste de pièces utilisées, jusqu'ici absente ;
--   - un résultat de fin d'intervention structuré.
--
-- PUREMENT ADDITIF : toute intervention déjà en base garde un comportement
-- identique (field_type/section ont un défaut qui reproduit exactement
-- l'ancien rendu "statut + valeur + observation").
-- ============================================================

-- ------------------------------------------------------------
-- intervention_items : contrôles typés + section d'affichage.
-- ------------------------------------------------------------
alter table intervention_items
  add column if not exists field_type text not null default 'status',
  add column if not exists field_meta jsonb,
  add column if not exists section text not null default 'controles';

alter table intervention_items drop constraint if exists intervention_items_field_type_check;
alter table intervention_items add constraint intervention_items_field_type_check
  check (field_type in ('status','text','number','boolean','select','textarea'));

alter table intervention_items drop constraint if exists intervention_items_section_check;
alter table intervention_items add constraint intervention_items_section_check
  check (section in ('avant','controles','apres'));

-- Le statut OK/À surveiller/Anomalie/N/A n'a de sens que pour field_type
-- 'status' — un champ "Marque" ou "Pression" ne doit pas être forcé à en
-- avoir un. On assouplit donc la colonne, avec une contrainte qui préserve
-- exactement l'ancien comportement pour les lignes existantes (toutes de
-- type 'status', déjà pourvues d'un statut).
alter table intervention_items alter column status drop not null;
alter table intervention_items drop constraint if exists intervention_items_status_required_check;
alter table intervention_items add constraint intervention_items_status_required_check
  check (field_type <> 'status' or status is not null);

-- ------------------------------------------------------------
-- interventions : quel template a été utilisé (et sa version figée), et
-- résultat de fin d'intervention.
-- ------------------------------------------------------------
alter table interventions
  add column if not exists diagnostic_template_id text,
  add column if not exists diagnostic_template_version integer,
  add column if not exists diagnostic_snapshot jsonb,
  add column if not exists completion_status text
    check (completion_status in (
      'CONFORME', 'SURVEILLANCE', 'PROVISOIRE',
      'PIECE_A_COMMANDER', 'DEVIS_COMPLEMENTAIRE', 'NOUVELLE_INTERVENTION'
    ));

comment on column interventions.diagnostic_template_id is 'Identifiant du template au moment du démarrage de l''intervention (ex. slug de service ou clé de catégorie) — jamais réévalué ensuite, même si le catalogue change plus tard.';
comment on column interventions.diagnostic_snapshot is 'Copie figée (titre + structure des contrôles) du template utilisé, pour qu''une évolution future du catalogue ne modifie jamais un rapport déjà réalisé.';

-- ------------------------------------------------------------
-- intervention_parts : pièces / consommables utilisés (absent jusqu'ici).
-- Même patron que intervention_photos générales (0049) : rattaché
-- directement à l'intervention, visible admin/pro uniquement pour l'instant
-- (le compte rendu client les inclut néanmoins directement dans son texte).
-- ------------------------------------------------------------
create table if not exists intervention_parts (
  id uuid primary key default gen_random_uuid(),
  intervention_id uuid not null references interventions(id) on delete cascade,
  designation text not null,
  brand text,
  reference text,
  quantity integer not null default 1,
  unit_price_cents integer,
  comment text,
  created_at timestamptz not null default now()
);

alter table intervention_parts enable row level security;

create policy "intervention_parts: pro or admin full access" on intervention_parts
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

create index if not exists idx_intervention_parts_intervention on intervention_parts(intervention_id);

-- ------------------------------------------------------------
-- customer_equipment : catégories au-delà de la climatisation/chauffage
-- (jusqu'ici impossible d'enregistrer un WC ou une robinetterie sans les
-- forcer sous 'autre' générique, et le formulaire "+ Ajouter un nouvel
-- équipement" de la fiche d'intervention forçait même 'climatisation' en
-- dur quel que soit le métier réel de l'intervention en cours).
-- ------------------------------------------------------------
alter table customer_equipment drop constraint if exists customer_equipment_equipment_type_check;
alter table customer_equipment add constraint customer_equipment_equipment_type_check
  check (equipment_type in (
    'climatisation','chaudiere_gaz','chaudiere_fioul','chauffe_eau','pac',
    'wc','robinetterie','radiateur','circulateur','sanitaire_autre','autre'
  ));
