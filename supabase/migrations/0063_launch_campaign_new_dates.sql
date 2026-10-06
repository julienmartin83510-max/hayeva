-- ============================================================
-- Correction urgente — nouvelles dates du Grand Jeu de lancement HAYEVA.
-- ============================================================
-- La fenêtre d'éligibilité réelle (utilisée par le trigger
-- launch_campaign_on_booking_insert, voir 0041) passe de
-- 01/11/2026→01/12/2026 à 06/10/2026→06/12/2026 (heure de Paris) — la
-- date de début des interventions (02/01/2027) et la date du tirage
-- (31/01/2027) NE CHANGENT PAS, conformément à la demande explicite.
--
-- CREATE OR REPLACE : purement remplace le corps de la fonction, aucune
-- donnée touchée. Les participations déjà enregistrées (launch_campaign_
-- entries) ne sont jamais recalculées rétroactivement par cette migration
-- — seules les nouvelles réservations évaluées APRÈS son application
-- utilisent la nouvelle fenêtre. Voir le commentaire original dans 0041 :
-- "Si les dates de la campagne changent, mettre à jour cette fonction ET
-- window.HAYEVA_LAUNCH_CAMPAIGN côté frontend" — les deux sont mis à jour
-- dans le même correctif.
create or replace function launch_campaign_is_eligible_created_at(ts timestamptz)
returns boolean
language sql
stable
as $$
  select ts >= (timestamp '2026-10-06 00:00:00' at time zone 'Europe/Paris')
     and ts <= (timestamp '2026-12-06 23:59:59.999999' at time zone 'Europe/Paris');
$$;
