-- ============================================================
-- Correctif — BUG RÉEL : "Reprendre la fiche d'intervention" ne s'ouvrait
-- pas / semblait ne rien faire sur mobile.
-- ============================================================
-- CAUSE RACINE (reproduite et confirmée en direct sur la réservation réelle
-- SM-2026-F4935B) : admOpenInterventionSheet() n'avait aucune protection
-- contre un second appel pendant qu'un premier était encore en cours — un
-- utilisateur qui retapait le bouton (précisément PARCE QUE rien ne
-- s'affichait immédiatement, faute de retour visuel) déclenchait plusieurs
-- cycles concurrents. Chacun relisait intervention_items AVANT que l'insert
-- du précédent n'ait été pris en compte, voyait donc la checklist comme
-- "manquante" et la réinsérait en entier — 4 taps ont ainsi créé 4 copies
-- des 9 lignes de checklist (36 lignes au lieu de 9) pour la même
-- intervention, sans qu'aucune contrainte en base ne l'empêche.
--
-- Cette migration : 1) nettoie les doublons déjà présents (sans perdre de
-- données : fusionne les photos vers la ligne conservée, garde la ligne la
-- plus renseignée de chaque groupe) ; 2) ajoute une contrainte d'unicité qui
-- rend ce genre de doublon structurellement impossible désormais, quelle que
-- soit la rapidité ou la simultanéité des appels. Le correctif frontend
-- (garde anti-double-appel + upsert idempotent) est fait séparément dans
-- index.html.

-- ------------------------------------------------------------
-- 1) Fusion des doublons existants (intervention_id, name) : pour chaque
-- groupe, on conserve la ligne "la plus renseignée" (un statut différent de
-- NOT_APPLICABLE, ou une observation/valeur mesurée non nulle l'emporte sur
-- une ligne encore à son état par défaut), à égalité on garde l'id le plus
-- petit (ordre déterministe, arbitraire mais stable).
-- ------------------------------------------------------------
do $$
declare
  grp record;
  keep_id uuid;
begin
  for grp in
    select intervention_id, name
    from intervention_items
    group by intervention_id, name
    having count(*) > 1
  loop
    select id into keep_id
    from intervention_items
    where intervention_id = grp.intervention_id and name = grp.name
    order by
      (status <> 'NOT_APPLICABLE') desc,
      (observation is not null) desc,
      (measured_value is not null) desc,
      id asc
    limit 1;

    -- Ne jamais perdre une photo déjà uploadée : la rattacher à la ligne
    -- conservée avant de supprimer les lignes en trop (sinon le "on delete
    -- cascade" de intervention_photos les supprimerait silencieusement).
    update intervention_photos
    set intervention_item_id = keep_id
    where intervention_item_id in (
      select id from intervention_items
      where intervention_id = grp.intervention_id and name = grp.name and id <> keep_id
    );

    delete from intervention_items
    where intervention_id = grp.intervention_id and name = grp.name and id <> keep_id;
  end loop;
end $$;

-- ------------------------------------------------------------
-- 2) Contrainte d'unicité — rend le doublon impossible au niveau base,
-- indépendamment de tout correctif frontend (défense en profondeur).
-- ------------------------------------------------------------
alter table intervention_items
  add constraint intervention_items_intervention_name_unique unique (intervention_id, name);
