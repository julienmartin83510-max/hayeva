# EVA — mise en production (préparée, NON exécutée)

Rien de ce qui suit n'est fait sans votre autorisation explicite.

## Ordre de fusion vers `main`

| Ordre | Branche | Migrations | Conflit attendu |
|---|---|---|---|
| 1 | `parrainage/programme-complet` | 0134 | aucun |
| 2 | `feature/retrait-offre-lancement` | 0139 | `netlify.toml` (lignes du garde-fou) |
| 3 | `feature/eva-assistant` | 0135 → 0138, 0140 | `netlify.toml` |

- **Résolution de `netlify.toml`** : garder la version EVA, la plus complète (production, `eva-test` et prévisualisations en mode test).
- `index.html` fusionne sans conflit. Vérifié par fusion simulée.

## Avant (production, lecture seule)

1. **Contrôle préalable** : `supabase/rollback/eva_preflight.sql`. Il doit afficher « OK » seulement.
2. **Sauvegarde** : le plan gratuit n'offre pas de sauvegarde téléchargeable. Exportez en CSV (Table editor → Export) les tables `company_settings`, `booking_settings`, `bookings`, `clients`, `quotes`, `invoices`.

## Migrations (dans cet ordre)

`0134` (si Parrainage n'est pas encore en production) → `0135` → `0136` → `0137` → `0138` → `0139` (après les vérifications de `docs/RETRAIT_OFFRE_LANCEMENT.md`) → `0140`.

## Fonctions Supabase

- Déployer `eva-siri` avec l'option `--no-verify-jwt`. Les fichiers sont `index.ts` et `_shared/eva-intents.js`.
- Aucune clé à ajouter : `SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY` sont fournies automatiquement.

## Site (Netlify)

La fusion vers `main` déclenche la publication de production. Il n'y a aucune variable d'environnement : les identifiants publics sont dans `index.html`. Sur hayeva.fr, le mode test ne s'active jamais : il ne se déclenche que sur les adresses `eva-test--…` et `deploy-preview-N--…`.

## Après

Dans EVA → Réglages :
- confirmer le régime de TVA réel ;
- vérifier les horaires ;
- activer Siri ;
- créer l'accès de l'iPhone.

## Retour arrière

- **Site** : sur Netlify → Deploys, faire « Publish deploy » sur la version précédente, ou annuler le commit de fusion sur `main`.
- **Base** :
  - `supabase/rollback/eva_0135_0137_rollback.sql` couvre 0135 à 0138 et 0140, car il supprime toutes les fonctions `_eva_*` ;
  - `supabase/rollback/0139_rollback.sql` couvre 0139 ;
  - aucune donnée client, réservation, devis ou facture n'est touchée.
- **Fonction** : supprimer `eva-siri` (Edge Functions → eva-siri → Delete).
