-- ============================================================
-- Refonte tarifaire plomberie/chauffage — 3 régimes d'affichage
-- ============================================================
-- Jusqu'ici, chaque service DIRECT_BOOKING affichait un prix unique,
-- présenté implicitement comme définitif. On distingue maintenant trois
-- régimes d'affichage, portés par une seule colonne (source de vérité
-- unique, lue par le site ET par l'assistant IA côté client — jamais deux
-- définitions séparées du même fait) :
--   - FIXED : prix ferme (packs d'entretien, forfaits standardisés).
--   - FROM  : "à partir de" — la prestation reste réservable directement
--             (aucun changement du mécanisme de réservation), seul
--             l'affichage change, jamais présenté comme définitif.
--   - QUOTE : "sur devis" — synonyme d'affichage de booking_type =
--             'QUOTE_REQUEST', déjà existant (voir create_booking() qui
--             refuse toute réservation directe hors DIRECT_BOOKING, et
--             resolveBookingParams() côté frontend qui bascule déjà vers
--             le parcours "devis" pour tout service non DIRECT_BOOKING —
--             ce mécanisme existe et fonctionne depuis 0001_init.sql,
--             réutilisé tel quel, jamais réécrit).
--
-- FIXED et FROM sont tous deux DIRECT_BOOKING : le mécanisme de
-- réservation, le calcul du total, la RPC create_booking() ne changent
-- strictement pas. Seul QUOTE requiert booking_type = 'QUOTE_REQUEST'
-- (contrainte ci-dessous), pour que le parcours "devis" déjà en place
-- prenne le relais automatiquement.
-- La contrainte croisée avec booking_type est ajoutée à la toute fin de ce
-- fichier (services_quote_display_consistency) : elle doit être validée
-- APRÈS les UPDATE ci-dessous, jamais dans le même ALTER TABLE que l'ajout
-- de colonne (le DEFAULT 'FIXED' s'applique d'abord à toutes les lignes
-- existantes, y compris celles déjà QUOTE_REQUEST — la contrainte
-- échouerait immédiatement si elle était vérifiée à ce stade).
alter table services
  add column price_display_mode text not null default 'FIXED'
    check (price_display_mode in ('FIXED', 'FROM', 'QUOTE'));

-- Tout service déjà QUOTE_REQUEST (devis gratuit, installation clim...)
-- passe en affichage QUOTE par cohérence, sans autre changement.
update services set price_display_mode = 'QUOTE' where booking_type = 'QUOTE_REQUEST';

-- ------------------------------------------------------------
-- Grille PLOMBERIE — nouveaux montants "à partir de" (validés avec le
-- client). Les prestations "Pose receveur de douche" et "Pose baignoire"
-- basculent en QUOTE_REQUEST (voir plus bas) : plus de prix fixe
-- automatique pour ces travaux importants.
update services set price_display_mode = 'FROM', base_price_cents = 7500  where slug = 'plomberie-depannage';        -- 50€ -> 75€
update services set price_display_mode = 'FROM', base_price_cents = 9000  where slug = 'plomberie-fuite';            -- 75€ -> 90€ (recherche simple/non destructive, voir description)
update services set price_display_mode = 'FROM', base_price_cents = 12000 where slug = 'plomberie-robinet';          -- 100€ -> 120€
update services set price_display_mode = 'FROM', base_price_cents = 10000 where slug = 'plomberie-wc-mecanisme';     -- 83,33€ -> 100€
update services set price_display_mode = 'FROM', base_price_cents = 15000 where slug = 'plomberie-chasse-eau';       -- 150€ (inchangé, tarif variable)
update services set price_display_mode = 'FROM', base_price_cents = 10000 where slug = 'plomberie-debouchage-evier'; -- 75€ -> 100€
update services set price_display_mode = 'FROM', base_price_cents = 12000 where slug = 'plomberie-debouchage-wc';    -- 100€ -> 120€
update services set price_display_mode = 'FROM', base_price_cents = 25000 where slug = 'plomberie-seche-serviette';  -- 250€ (inchangé, tarif variable)
update services set price_display_mode = 'FROM', base_price_cents = 18000 where slug = 'plomberie-colonne-douche';   -- 160€ -> 180€
update services set price_display_mode = 'FROM', base_price_cents = 20000 where slug = 'plomberie-paroi-douche';     -- 180€ -> 200€

-- Travaux importants : plus de réservation à prix fixe automatique. Reprend
-- exactement le mécanisme déjà en place pour clim-installation/devis
-- (QUOTE_REQUEST, base_price_cents/duration_minutes NULL ensemble — voir
-- contrainte services_price_requires_duration).
update services
  set booking_type = 'QUOTE_REQUEST', price_display_mode = 'QUOTE',
      base_price_cents = null, duration_minutes = null
  where slug in ('plomberie-receveur', 'plomberie-baignoire');

-- ------------------------------------------------------------
-- Grille CHAUFFAGE — les packs d'entretien (Essentiel/Confort/Premium,
-- chaudière gaz/fioul) restent FIXED et ne sont PAS touchés par cette
-- migration : ce sont des forfaits déjà standardisés, hors périmètre de ce
-- changement (demande explicite : ne pas modifier les packs aveuglément).
update services set price_display_mode = 'FROM', base_price_cents = 7500  where slug = 'chauffage-depannage';   -- 75€ (inchangé)
update services set price_display_mode = 'FROM', base_price_cents = 18000 where slug = 'chauffage-radiateur';   -- 150€ -> 180€
update services set price_display_mode = 'FROM', base_price_cents = 25000 where slug = 'chauffage-circulateur'; -- 208,33€ -> 250€
update services set price_display_mode = 'FROM', base_price_cents = 20000 where slug = 'chauffage-vase';        -- 233,33€ -> 200€
update services set price_display_mode = 'FROM', base_price_cents = 7500  where slug = 'chauffage-purge';       -- 75€ (inchangé)
update services set price_display_mode = 'FROM', base_price_cents = 5000  where slug = 'chauffage-pression';    -- 50€ (inchangé)

-- Contrainte croisée : ajoutée maintenant que toutes les lignes QUOTE_REQUEST
-- (déjà existantes + receveur/baignoire basculées plus haut) portent bien
-- price_display_mode = 'QUOTE'.
alter table services
  add constraint services_quote_display_consistency check (
    booking_type <> 'QUOTE_REQUEST' or price_display_mode = 'QUOTE'
  );
