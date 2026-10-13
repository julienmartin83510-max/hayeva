# EVA — mise en production (préparée, NON exécutée)

Rien de ce qui suit n'est fait sans votre autorisation explicite.

## Le jeu-concours reste en place

- **NE PAS fusionner `feature/retrait-offre-lancement`** et **NE PAS appliquer `0139_end_launch_campaign.sql`**. Cette branche supprime le jeu-concours :
  - la section et les lots (dont la Nintendo Switch 2) ;
  - les visuels ;
  - les déclencheurs de participation.
- La branche EVA ne touche à aucun élément du jeu-concours : ni section, ni règlement, ni lots, ni visuels, ni tables `launch_campaign_*`, ni déclencheurs. Vérifié par comparaison avec `main`.
- État constaté en production le 13/10/2026 (lecture seule) :
  - campagne active jusqu'au 06/12/2026 ;
  - 11 participations ;
  - 2 déclencheurs actifs ;
  - 54 réservations.

## Fusion vers `main`

EVA part seule, par la PR #3 (`feature/eva-assistant`). `main` est son ancêtre direct, donc la fusion se fait sans conflit (vérifié). Elle ne dépend pas de Parrainage (0134) : les fonctions de parrainage qu'elle lit existent déjà en production. `parrainage/programme-complet` reste une décision séparée.

## Avant (production, lecture seule)

1. **Contrôle préalable** : `supabase/rollback/eva_preflight.sql` doit afficher « OK » seulement. Dernier passage le 13/10/2026 : OK.
2. **Sauvegarde** : le plan gratuit n'offre pas de sauvegarde téléchargeable. Exportez en CSV (Table editor → Export) les tables `company_settings`, `booking_settings`, `bookings`, `clients`, `quotes`, `invoices`, `launch_campaign_entries`.

## Migrations (dans cet ordre)

`0135` → `0136` → `0137` → `0138` → `0140`. Aucune ne modifie ni ne supprime de réservation, de client, de devis, de facture ou de participation.

## Fonctions Supabase

- Déployer `eva-siri` avec l'option `--no-verify-jwt`. Les fichiers sont `index.ts` et `_shared/eva-intents.js`.
- Aucune clé à ajouter : `SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY` sont fournies automatiquement.

## Site (Netlify)

La fusion vers `main` déclenche la publication de production. Il n'y a aucune variable d'environnement : les identifiants publics sont dans `index.html`. Sur hayeva.fr, le mode test ne s'active jamais : il ne se déclenche que sur les adresses `eva-test--…` et `deploy-preview-N--…`.

## Après

1. Vérifier que le jeu-concours s'affiche toujours sur hayeva.fr.
2. Dans EVA → Réglages :
   - confirmer le régime de TVA réel ;
   - vérifier les horaires ;
   - activer Siri ;
   - créer l'accès de l'iPhone.

## Retour arrière

- **Site** : sur Netlify → Deploys, faire « Publish deploy » sur la version précédente, ou annuler le commit de fusion sur `main`.
- **Base** : `supabase/rollback/eva_0135_0137_rollback.sql` couvre 0135 à 0138 et 0140, car il supprime toutes les fonctions `_eva_*`. Aucune donnée client, réservation, devis, facture ou participation n'est touchée.
- **Fonction** : supprimer `eva-siri` (Edge Functions → eva-siri → Delete).
