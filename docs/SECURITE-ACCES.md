# HAYEVA — Contrôle des accès (07/10/2026)

Tests réels sur la base de production, en transaction annulée (aucune donnée modifiée).

## Notes internes (migration 0109)
- Table `admin_internal_notes` : lecture/écriture **admin uniquement** (RLS `is_admin()`).
- Anciennes notes `clients.notes` déplacées ; toute écriture future dans `clients.notes` est redirigée et la colonne vidée.
- `launch_campaign_entries.admin_note` et `referral_payout_requests.admin_note` : lecture directe réservée à l'admin.

| Rôle | Notes internes (lire) | Notes internes (écrire) |
|---|---|---|
| Anonyme | refusé | refusé |
| Client A | 0 ligne | refusé |
| Client B | 0 ligne | refusé |
| Pro | 0 ligne | refusé |
| Admin | oui | oui |

## Isolation clients
- Client A / client B : sur chaque table, les lignes visibles = exactement leurs propres données (réservations, adresses, interventions, contrôles, historique, devis non brouillons, factures non brouillons, comptes rendus, PDF).
- B ne peut ni lire, ni annuler, ni déplacer un rendez-vous de A ; un client ne peut pas confirmer lui-même un rendez-vous.
- Anonyme : aucune donnée client lisible ; création de réservation sans captcha refusée.

## Facturation (0112)
- Facture émise : ni modification (lignes, montants, client, numéro), ni suppression, ni annulation directe ; correction par avoir uniquement.
- Numérotation sans trou par année : DEV-AAAA-NNNN (envoi du devis), FAC-AAAA-NNNN (émission), AV-AAAA-NNNN (avoir).

## Secrets
- Aucun secret serveur dans le dépôt ni dans l'historique Git ; seule la clé *publishable* Supabase est dans le site (publique par conception).
