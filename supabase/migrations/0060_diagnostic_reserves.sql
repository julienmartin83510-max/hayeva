-- ============================================================
-- Système de diagnostic, réserves et traçabilité des dépannages
-- (cahier des charges HAYEVA du 04/10/2026) : jusqu'ici, une fiche de
-- dépannage ne distinguait pas explicitement "ce qui a été constaté et
-- traité lors de cette intervention" de "ce qui reste à surveiller ou à
-- traiter séparément" — un point central pour la traçabilité légale d'un
-- dépannage (panne traitée vs anomalie non liée simplement signalée).
-- PUREMENT ADDITIF : aucune ligne, aucune contrainte existante supprimée ;
-- toute fiche déjà FINALIZED reste inchangée (reserves_status restera
-- simplement NULL pour elle, affiché comme "non renseigné").
-- ============================================================

-- ------------------------------------------------------------
-- 1) "État de l'installation après intervention" (section 2 du cahier des
-- charges) : la fiche a déjà un completion_status (0050/0051) couvrant
-- CONFORME/SURVEILLANCE/PROVISOIRE/PIECE_A_COMMANDER/DEVIS_COMPLEMENTAIRE/
-- NOUVELLE_INTERVENTION/MISE_EN_SECURITE — il ne manquait qu'un seul des 5
-- cas demandés : "Impossible de réaliser les essais" (accès empêché,
-- occupant absent, condition dangereuse non liée au CO, etc. — distinct de
-- MISE_EN_SECURITE qui suppose un essai réalisé ayant révélé un danger).
-- ------------------------------------------------------------
alter table interventions drop constraint if exists interventions_completion_status_check;
alter table interventions add constraint interventions_completion_status_check
  check (completion_status in (
    'CONFORME', 'SURVEILLANCE', 'PROVISOIRE',
    'PIECE_A_COMMANDER', 'DEVIS_COMPLEMENTAIRE', 'NOUVELLE_INTERVENTION',
    'MISE_EN_SECURITE', 'ESSAIS_IMPOSSIBLES'
  ));

-- ------------------------------------------------------------
-- 2) "RÉSERVES / AUTRES ANOMALIES CONSTATÉES" (section 3) : volontairement
-- DISTINCT de intervention_anomalies (qui reste la liste libre, déjà
-- existante, d'anomalies détaillées avec sévérité) — ce nouveau champ est
-- la case à cocher UNIQUE et obligatoire avant clôture qui résume la
-- situation ("rien d'autre à signaler" / "autre anomalie" / "risque" /
-- "diagnostic partiel"), présente sur CHAQUE fiche quel que soit le métier,
-- jamais seulement sur celles qui ont des anomalies dans la liste détaillée.
-- ------------------------------------------------------------
alter table interventions
  add column if not exists reserves_status text
    check (reserves_status in (
      'AUCUNE', 'AUTRE_ANOMALIE', 'RISQUE_OU_ANOMALIE', 'DIAGNOSTIC_PARTIEL'
    )),
  add column if not exists reserves_detail text;

comment on column interventions.reserves_status is 'Réponse obligatoire avant clôture d''un dépannage : AUCUNE (rien d''autre constaté), AUTRE_ANOMALIE, RISQUE_OU_ANOMALIE (nécessite une intervention complémentaire), DIAGNOSTIC_PARTIEL (contrôle limité). Distinct de intervention_anomalies (liste libre détaillée).';
comment on column interventions.reserves_detail is 'Description libre de la réserve, obligatoire dès que reserves_status <> ''AUCUNE'' (contrôle fait côté frontend, pas de contrainte SQL bloquante pour ne jamais empêcher la synchronisation d''une fiche déjà saisie hors-ligne).';
