# HAYEVA — Développement commercial (V3)

## 1. Pages de référencement local (en ligne après déploiement)

| Page | Adresse |
|---|---|
| Fréjus | https://hayeva.fr/plombier-chauffagiste-frejus/ |
| Saint-Raphaël | https://hayeva.fr/plombier-chauffagiste-saint-raphael/ |
| Le Muy | https://hayeva.fr/plombier-chauffagiste-le-muy/ |
| Puget-sur-Argens | https://hayeva.fr/plombier-chauffagiste-puget-sur-argens/ |
| Roquebrune-sur-Argens | https://hayeva.fr/plombier-chauffagiste-roquebrune-sur-argens/ |
| Var (83) | https://hayeva.fr/plombier-chauffagiste-var/ |
| Alpes-Maritimes (06) | https://hayeva.fr/plombier-chauffagiste-alpes-maritimes/ |
| Entretien climatisation | https://hayeva.fr/entretien-climatisation-frejus-saint-raphael/ |
| Entretien chaudière | https://hayeva.fr/entretien-chaudiere-var/ |
| Entretien mobil-home | https://hayeva.fr/entretien-mobil-home-var/ |
| Conciergeries / locations | https://hayeva.fr/professionnels/ |
| Syndics / copropriétés | https://hayeva.fr/syndics-copropriete/ |
| Campings / mobil-homes | https://hayeva.fr/campings-mobil-homes/ |
| Partenaires | https://hayeva.fr/partenaires/ |

Toutes sont listées dans `sitemap.xml` et reliées depuis le pied de page du site.
Contenu limité aux informations déjà publiées (aucune adresse, aucun SIRET,
aucun avis inventé). Pour modifier un texte : `docs/tools/build_local_pages.py`,
puis `python3 docs/tools/build_local_pages.py`.

## 2. QR codes pour les supports imprimés

Fichiers prêts à imprimer dans `docs/qr/` (SVG pour l'imprimeur, PNG 888 px
pour un usage bureautique). Liste et liens : `docs/qr/liens-qr.csv`.
Chaque QR a été vérifié par décodage automatique.

| Support | Fichier | Ouvre |
|---|---|---|
| Flyer particuliers | qr-flyer | prise de rendez-vous |
| Carte de visite | qr-carte-visite | accueil |
| Véhicule | qr-vehicule | prise de rendez-vous |
| Affiche / vitrine | qr-affiche | prise de rendez-vous |
| Autocollant sur équipement | qr-autocollant-equipement | prise de rendez-vous |
| Flyer professionnels | qr-flyer-pro | espace professionnel |
| Plaquette campings | qr-camping | espace professionnel |
| Plaquette syndics | qr-syndic | espace professionnel |
| Parrainage | qr-parrainage | prise de rendez-vous (code saisi à la réservation) |

**Suivi :** Administration → Statistiques → « QR codes et liens de campagne »
affiche, par support, le nombre de visiteurs et de réservations créées sur la
période choisie (mesure interne anonyme, aucun service tiers).

Pour un nouveau support : utiliser `https://hayeva.fr/?src=nom-du-support`
(lettres minuscules, chiffres et tirets).

Conseils d'impression : taille minimale 2 × 2 cm (carte de visite), 3 × 3 cm
(flyer), 15 × 15 cm au moins sur un véhicule ; garder la marge blanche autour
du code ; tester avec un iPhone avant le tirage.

## 3. Google Business Profile — à faire par le propriétaire

Ces réglages se font uniquement dans le compte Google du propriétaire
(business.google.com). Aucune information ne doit y être inventée.

1. **Nom :** HAYEVA (sans mots-clés ajoutés, règle Google).
2. **Catégorie principale :** Plombier. **Secondaires :** Chauffagiste,
   Entreprise de climatisation, Service de réparation de chaudières.
3. **Type :** entreprise de services de proximité, *adresse masquée*
   (pas de local recevant du public), avec une **zone desservie** : Fréjus,
   Saint-Raphaël, Puget-sur-Argens, Roquebrune-sur-Argens, Le Muy, Var,
   Alpes-Maritimes.
4. **Téléphone :** 06 71 26 23 02 — **Site :** https://hayeva.fr/ —
   **Lien de rendez-vous :** https://hayeva.fr/rdv?src=google
5. **Date d'ouverture :** 1er janvier 2027. **Horaires :** à renseigner
   uniquement quand ils sont définitifs.
6. **Services :** reprendre la liste du site (entretien climatisation,
   entretien chaudière gaz / fioul, dépannage chauffage, dépannage plomberie,
   recherche de fuite, débouchage, pose douche / sèche-serviettes, Check
   technique pour locations et mobil-homes).
7. **Description (proposition, faits vérifiés uniquement) :**
   > HAYEVA, basée à Fréjus, intervient en plomberie, chauffage et
   > climatisation dans le Var et les Alpes-Maritimes, pour les particuliers
   > et les professionnels (conciergeries, locations saisonnières, campings).
   > Réservation en ligne, devis gratuit, compte rendu numérique après chaque
   > intervention. Déplacement offert dans un rayon de 25 km par la route.
8. **Photos :** logo, véhicule, photos réelles d'interventions déjà
   présentes sur le site (dossier `images/`).
9. **Avis :** une fois la fiche validée, copier le lien « Demander des avis »
   dans la fiche entreprise de l'Administration, champ « Lien « Laisser un avis » Google ». Les demandes d'avis
   automatiques après intervention terminée s'activent alors (au plus une par
   client et par an).
10. **Lien de suivi :** utiliser `https://hayeva.fr/?src=google` comme site
    web pour mesurer les visites venant de la fiche.

## 4. Google Search Console — à faire par le propriétaire

1. Ajouter la propriété `hayeva.fr` (vérification par enregistrement DNS TXT
   chez OVH — seule manipulation DNS, à faire vous-même).
2. Soumettre `https://hayeva.fr/sitemap.xml`.
3. Demander l'indexation de la page d'accueil et des 14 pages ci-dessus.
