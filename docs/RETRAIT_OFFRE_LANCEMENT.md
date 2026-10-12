# Retrait de l'offre promotionnelle de lancement

Branche : `feature/retrait-offre-lancement`, créée à partir de `main` (3fde261). Rien n'est déployé, ni appliqué en production.

## 1. Audit : ce qui existait

| Élément | Où | État en production (12/10/2026) |
|---|---|---|
| Section d'accueil « Grand jeu de lancement HAYEVA » : 3 lots (Nintendo Switch 2, 200 € de crédit, entretien climatisation offert), frise de dates, bouton | Site public | **Visible** |
| Badge « Offre de lancement » au-dessus du formulaire de réservation | Réservation | **Visible** |
| Notes « Cette réservation est enregistrée pour l'opération de lancement » sur les écrans de confirmation | Réservation | Affichées pendant la période |
| Fenêtre « Règlement du jeu » | Site public | Ouvrable |
| Configuration `HAYEVA_LAUNCH_CAMPAIGN` (dates, lots, valeurs) | Script du site | Active (`active: true`) |
| Réponse de FAQ mentionnant le Grand Jeu et ses dates | Site public, assistant FAQ | Visible |
| Bannière « Offre exclusive Noël — Pack Découverte 99 € » (tirage d'une Switch 2) | Tarifs | Masquée sur `index.html`. **S'affichait automatiquement du 15/10 au 15/11 sur `/sudmaintenance.html`** |
| Badge « Jeu de lancement » sur chaque rendez-vous | Espace client | Affiché si participation |
| Page « Jeu de lancement » : participations, revue, bouton « Lancer le tirage » | Administration (ordinateur et menu mobile) | Accessible |
| Visuels des lots (`images/campaign/`) | Fichiers | Accessibles par URL directe |
| Ancienne copie du site `/sudmaintenance.html` contenant tout ce qui précède | Site public (exclue des moteurs) | **Accessible, reliée à la même base** |

**Côté base de données (lecture seule, aucune modification) :**
- `launch_campaign_settings` : la fenêtre « CAMPAGNE LANCEMENT HAYEVA 2026 » est **ouverte du 6/10 au 6/12/2026**. Chaque nouvelle réservation crée encore une participation.
- `launch_campaign_entries` : 11 participations, **toutes annulées** (doublons, annulations, revues). Aucun tirage effectué, aucun gagnant.
- 2 déclencheurs actifs sur `bookings` ; 5 fonctions appelables (tirage, revue, statut client).
- `promo_codes` : un seul code, `HAYEVA100` (code de test interne), **déjà inactif**. Il ne sert qu'à l'assistant, qui répond qu'il n'est pas utilisable. Il n'est jamais appliqué à une réservation.
- E-mails automatiques : aucun ne mentionne l'opération. Vérifié dans le dépôt et dans la version déployée de `notify-customer-booking`.
- Pas de compte à rebours ni de fenêtre publicitaire, hors la fenêtre du règlement.

**Liens et paramètres d'URL :**
- `?src=` : mesure d'audience des QR codes, sans aucun avantage.
- `?ref=` : programme de parrainage, conservé.
- Aucun paramètre ne donne de réduction.
- L'ancien lien `#campagneLancement` mène désormais simplement en haut de l'accueil.

## 2. Ce qui est retiré (cette branche)

- **Site public :**
  - la section du jeu, le règlement et sa configuration ;
  - le texte de FAQ ;
  - la bannière Noël ;
  - le CSS associé, y compris les surcharges Black Signature ;
  - les 3 visuels des lots.
- **Réservation :** le badge « Offre de lancement » et les notes de participation.
- **Espace client :** le badge « Jeu de lancement » ; l'appel à `get_my_launch_entry_statuses` n'est plus fait.
- **Administration :** la page « Jeu de lancement », ses entrées de menu (ordinateur et mobile) et ses scripts, dont le bouton de tirage.
- **Interface Pro :** rien à retirer, l'offre n'y apparaissait pas.
- **`/sudmaintenance.html` :** les mêmes retraits, y compris la bannière Noël à affichage automatique.

## 3. Ce qui est conservé, sans modification

- Les tarifs et le catalogue.
- La réservation.
- La fidélité.
- Le parrainage, y compris l'avantage filleul et `_referral_set_booking_discount`.
- Le bandeau « Interventions disponibles à partir du 2 janvier 2027 ». C'est une information de fonctionnement, pas une promotion.
- Tout l'historique en base.

## 3 bis. Réduction « -10 % si vous réglez à l'avance » (retirée)

- **Texte retiré** de `index.html` (Tarifs) et de `sudmaintenance.html`.
- **Aucun calcul ne l'appliquait.** Vérifié dans le code et dans la base de production :
  - les fonctions de réservation (`create_booking`, `create_guest_or_quote_booking`, `guard_direct_booking_insert`) enregistrent toujours une remise de 0 ;
  - la seule remise automatique est l'avantage filleul du parrainage, conservé ;
  - production : 0 réservation, 0 devis et 0 ligne de facture portent une remise.
- **Conservé :** le champ « Remise (€) » du calculateur de devis de l'administration. Il est manuel, vaut 0 par défaut et n'est jamais appliqué automatiquement.

## 3 ter. À décider (non modifié, car ce sont des tarifs ou le contenu de vos offres)

- **Remises professionnelles multi-logements** (Tarifs professionnels) : -10 % de 2 à 4 logements, -15 % de 5 à 9, -20 % à partir de 10. C'est une grille permanente affichée et calculée automatiquement pour les professionnels. Elle n'est pas liée au lancement.
- **« Un cadeau surprise HAYEVA offert, au choix »** : il figure dans les packs Premium (climatisation, chaudière gaz, chaudière fioul, dans la base) et dans l'Entretien Multi-Services. C'est un élément permanent des offres, pas lié au lancement.

## 4. Désactivation côté base : migration préparée, NON appliquée

`supabase/migrations/0139_end_launch_campaign.sql` :
- ferme la fenêtre d'éligibilité, avec pour date de fin celle de l'application ;
- **désactive** (sans les supprimer) les 2 déclencheurs ;
- retire l'accès aux 5 fonctions du jeu depuis le site ;
- **ne supprime rien** : participations, tirages et gagnants (vides), réglages et fonctions restent en place ;
- le retour arrière est décrit dans l'en-tête du fichier.

Testée sur une copie locale de la base :
- éligible avant, non éligible après ;
- déclencheurs désactivés, fonctions inaccessibles ;
- la migration peut être rejouée sans effet de bord.

**Vérifications préalables (production, lecture seule, 12/10/2026) :**
- 11 participations, 6 participants distincts, **toutes annulées**. Leurs 11 réservations sont annulées : aucune réservation active depuis l'ouverture de la fenêtre.
- La seule participation « annulée par HAYEVA » est une entrée de test technique, selon sa note admin.
- 0 tirage, 0 gagnant, règlement jamais publié, aucun e-mail envoyé au sujet du jeu (types d'e-mails : réservation reçue, confirmée, annulée, déplacée).
- **Aucun engagement en cours envers un participant.**
- Les migrations des branches déjà poussées (0134 à 0138) ne sont pas appliquées en production : un push n'applique aucune migration.

**Sauvegarde et retour arrière :**
- Avant toute modification, 0139 enregistre dans `launch_campaign_closure_0139` (accès réservé au serveur) l'ancienne date de fin, l'état des déclencheurs et les droits.
- `supabase/rollback/0139_rollback.sql` restaure exactement cet état.
- Testé sur copie locale : application, deuxième application sans effet, puis retour arrière identique à l'état d'origine. Les participations sont intactes.
- Aucune donnée n'étant supprimée, aucun export n'est indispensable. Un export CSV de `launch_campaign_entries` depuis le tableau de bord reste possible par précaution (le plan gratuit n'a pas de sauvegarde téléchargeable).

`HAYEVA100` est déjà inactif : rien à faire. On peut aussi le laisser tel quel, pour que l'assistant continue de répondre qu'il n'est pas valable.

## 5. Décisions qui vous reviennent

1. Appliquer `0139` en production (principe validé le 12/10, exécution en attente de votre feu vert).
2. Remises multi-logements et cadeau des packs Premium (§ 3 ter).
3. Fusion vers `main` et mise en ligne : non effectuées.

**Garde-fou Netlify** (`netlify.toml`, sur cette branche) : seule la production (branche `main`) est construite. Simulé pour chaque contexte :
- production/main → construction ;
- branch-deploy et deploy-preview de toute autre branche → annulés.

## 6. Vérifications effectuées

- Les 44 scripts de `index.html` et les 42 de `sudmaintenance.html` se compilent sans erreur.
- Aucune référence restante aux identifiants supprimés.
- Rendu Chromium avant/après, mobile 390 px et ordinateur 1280 px :
  - aucun texte promotionnel après ;
  - accueil, besoin, tarifs et réservation affichés ;
  - 0 erreur JavaScript ;
  - pas de défilement horizontal.
