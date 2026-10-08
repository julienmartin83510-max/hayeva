-- =====================================================================
-- 0130 — Détail des packs et prestations, source unique pour toutes les
-- interfaces (site public, réservation, espace particulier, espace pro).
--
-- Jusqu'ici le contenu des packs (accroche, prestations incluses, avantages)
-- n'existait qu'en dur dans index.html : une modification du catalogue en
-- base ne se répercutait pas. Ces colonnes sont lues par le composant
-- partagé HvPacks et modifiables depuis l'administration (RLS existante :
-- lecture publique des lignes actives, écriture is_admin()).
--
-- CONTENU : repris MOT POUR MOT des textes déjà publiés sur le site
-- (#tarifs, section professionnels, recherche de la réservation). Aucune
-- prestation, garantie, certification ni tarif n'est ajouté.
-- Migration additive : ADD COLUMN + UPDATE ciblés, aucune suppression.
-- =====================================================================

alter table public.service_packs add column if not exists tagline text;
alter table public.service_packs add column if not exists includes text[] not null default '{}';
alter table public.service_packs add column if not exists perks text[] not null default '{}';
alter table public.service_packs add column if not exists excludes text[] not null default '{}';
alter table public.service_packs add column if not exists note text;

alter table public.services add column if not exists excludes text[] not null default '{}';
alter table public.services add column if not exists conditions text;

comment on column public.service_packs.includes is 'Prestations incluses, dans l''ordre d''affichage. « Tout le Pack X » est développé par l''interface pour le comparatif.';
comment on column public.service_packs.perks is 'Avantages mis en avant (affichés en doré).';
comment on column public.service_packs.excludes is 'Ce qui n''est pas compris dans le pack.';
comment on column public.service_packs.note is 'Note de bas de carte (ex. détail du cadeau).';

-- ---------- Climatisation (entretien uniquement) ----------
update public.service_packs set tagline = 'L''entretien indispensable', includes = array[
  'Nettoyage des filtres','Nettoyage unité intérieure','Contrôle de l''évacuation des condensats','Contrôle du fonctionnement',
  'Déplacement offert dans la zone de 25 km'], perks = '{}' where slug = 'clim-essentiel';
update public.service_packs set tagline = 'L''entretien complet', includes = array[
  'Tout le Pack Essentiel','Nettoyage approfondi','Nettoyage échangeur / turbine selon accessibilité','Contrôle unité extérieure','Contrôle chaud / froid',
  'Déplacement offert dans la zone de 25 km'], perks = array['Déplacement offert même en dehors de la zone de 25 km'] where slug = 'clim-confort';
update public.service_packs set tagline = 'L''entretien intégral', includes = array[
  'Tout le Pack Confort','Entretien approfondi de l''unité extérieure','Contrôles électriques','Contrôle approfondi de l''installation','Remplacement des piles de la télécommande','Compte rendu d''intervention',
  'Déplacement offert dans la zone de 25 km'], perks = array['Déplacement offert même en dehors de la zone de 25 km','Un cadeau surprise HAYEVA offert, au choix'],
  note = 'Cadeau au choix : porte-clés multifonction HAYEVA (mini lampe & tournevis), désodorisant parfumé pour filtre de climatisation HAYEVA, ou huile essentielle en roll-on HAYEVA.'
  where slug = 'clim-premium';
update public.service_packs set excludes = array['Installation de climatisation','Dépannage du circuit frigorifique (fuite, recharge de fluide, réparation)']
  where slug in ('clim-essentiel','clim-confort','clim-premium');
update public.services set conditions = 'Tarif selon nombre d''unités : 2ᵉ unité à prix réduit, 4 unités ou plus sur devis.'
  where slug = 'clim-entretien';

-- ---------- Chaudière gaz ----------
update public.service_packs set tagline = 'L''entretien indispensable', includes = array[
  'Nettoyage du corps de chauffe','Nettoyage du brûleur','Contrôle des organes de sécurité','Vérification de l''évacuation des fumées','Contrôle du fonctionnement','Mesure du monoxyde de carbone','Attestation d''entretien',
  'Déplacement offert dans la zone de 25 km'], perks = '{}' where slug = 'chauffage-chaudiere-gaz-essentiel';
update public.service_packs set tagline = 'L''entretien complet', includes = array[
  'Tout le Pack Essentiel','Nettoyage approfondi','Contrôle du vase d''expansion','Contrôle de la pression du circuit','Vérification des raccordements accessibles','Contrôle de la combustion et des réglages','Conseils d''optimisation de l''installation',
  'Déplacement offert dans la zone de 25 km'], perks = array['Déplacement offert même en dehors de la zone de 25 km'] where slug = 'chauffage-chaudiere-gaz-confort';
update public.service_packs set tagline = 'Entretien & tranquillité', includes = array[
  'Tout le Pack Confort','Contrôle approfondi de l''installation','Vérification du circuit chauffage','Purge si nécessaire','Contrôle du thermostat / régulation','Compte rendu d''intervention',
  'Déplacement offert dans la zone de 25 km'], perks = array['Déplacement offert même en dehors de la zone de 25 km','Un cadeau surprise HAYEVA offert, au choix'],
  note = 'Cadeau au choix : porte-clés multifonction HAYEVA (mini lampe & tournevis), désodorisant parfumé pour filtre de climatisation HAYEVA, ou huile essentielle en roll-on HAYEVA.'
  where slug = 'chauffage-chaudiere-gaz-premium';

-- ---------- Chaudière fioul ----------
update public.service_packs set tagline = 'L''entretien indispensable', includes = array[
  'Nettoyage du corps de chauffe','Nettoyage du brûleur fioul','Contrôle du gicleur','Contrôle des organes de sécurité','Vérification de l''évacuation des fumées','Contrôle de la combustion','Attestation d''entretien',
  'Déplacement offert dans la zone de 25 km'], perks = '{}' where slug = 'chauffage-chaudiere-fioul-essentiel';
update public.service_packs set tagline = 'L''entretien complet', includes = array[
  'Tout le Pack Essentiel','Nettoyage approfondi du corps de chauffe','Contrôle et nettoyage approfondi du brûleur','Vérification du gicleur','Contrôle de la pompe fioul','Analyse et réglage de la combustion','Contrôle du vase d''expansion et de la pression',
  'Déplacement offert dans la zone de 25 km'], perks = array['Déplacement offert même en dehors de la zone de 25 km'] where slug = 'chauffage-chaudiere-fioul-confort';
update public.service_packs set tagline = 'Entretien & tranquillité', includes = array[
  'Tout le Pack Confort','Contrôle approfondi de l''installation','Vérification du circuit chauffage','Contrôle thermostat / régulation','Purge si nécessaire','Contrôle visuel des éléments accessibles de l''alimentation fioul','Compte rendu détaillé d''intervention',
  'Déplacement offert dans la zone de 25 km'], perks = array['Déplacement offert même en dehors de la zone de 25 km','Un cadeau surprise HAYEVA offert, au choix'],
  note = 'Cadeau au choix : porte-clés multifonction HAYEVA (mini lampe & tournevis), désodorisant parfumé pour filtre de climatisation HAYEVA, ou huile essentielle en roll-on HAYEVA.'
  where slug = 'chauffage-chaudiere-fioul-premium';

update public.service_packs set excludes = array['Pièces détachées','Réparations']
  where slug like 'chauffage-chaudiere-%';
update public.services set conditions = 'Tarifs TTC pour l''entretien d''une chaudière individuelle standard. Un supplément peut s''appliquer selon l''installation, son état ou les conditions d''accès.'
  where slug in ('chauffage-chaudiere-gaz','chauffage-chaudiere-fioul');

-- ---------- Check technique professionnel ----------
update public.service_packs set tagline = 'Contrôle technique rapide', includes = array[
  'Recherche visuelle de fuites apparentes','Robinets et mitigeurs','WC / chasse d''eau','Douche','Évier / lavabo','Évacuations accessibles','Eau chaude','Test fonctionnel climatisation','Test fonctionnel chauffage','Signalement des anomalies visibles'],
  perks = '{}' where slug = 'pro-check-express';
update public.service_packs set tagline = 'Contrôle technique complet', includes = array[
  'Tout le Check Express','Contrôle plomberie plus complet','Contrôle des sanitaires','Contrôle visuel chauffe-eau / ballon accessible','Contrôle climatisation','Contrôle chauffage','Thermostat / régulation accessible','Vérification visuelle des raccordements accessibles','Recherche d''anomalies apparentes','Photos si nécessaire','Compte-rendu numérique','Recommandations d''intervention'],
  perks = '{}' where slug = 'pro-check-complet';
update public.service_packs set tagline = 'Contrôle technique approfondi', includes = array[
  'Tout le Check Complet','Contrôle technique plus approfondi','Rapport numérique détaillé','Photos des anomalies','Observations par équipement','Liste des interventions recommandées','Priorisation des anomalies'],
  perks = '{}' where slug = 'pro-check-premium';
update public.service_packs set excludes = array[
  'Certification officielle, diagnostic réglementaire ou attestation de conformité',
  'Réparations : jamais ajoutées ni facturées automatiquement (intervention ou devis séparé à votre demande)']
  where slug like 'pro-check-%';
update public.services set conditions = 'Contrôle visuel et fonctionnel réalisé dans le cadre des compétences de HAYEVA (plomberie, chauffage, climatisation).'
  where slug = 'pro-check';

-- ---------- Prestations à l'unité (exclusions déjà publiées) ----------
update public.services set excludes = array['Investigations complexes ou destructives']
  where slug = 'plomberie-fuite';
update public.services set conditions = 'Fourniture : selon modèle choisi.'
  where slug in ('chauffage-radiateur','chauffage-circulateur','chauffage-vase','plomberie-robinet','plomberie-wc-mecanisme','plomberie-chasse-eau',
                 'plomberie-seche-serviette','plomberie-colonne-douche','plomberie-paroi-douche');
update public.services set conditions = 'Intervention sous réserve de faisabilité technique et des activités couvertes par l''assurance professionnelle HAYEVA. Fourniture : selon modèle choisi.'
  where slug in ('plomberie-receveur','plomberie-baignoire');

-- « Le plus choisi » affiché sur le site pour le Pack Confort chaudière :
-- aligné en base pour que le badge provienne du catalogue.
update public.service_packs set is_featured = true
  where slug in ('chauffage-chaudiere-gaz-confort','chauffage-chaudiere-fioul-confort');
