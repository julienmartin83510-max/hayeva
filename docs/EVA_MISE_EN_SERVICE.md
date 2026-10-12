# EVA — audit, version de test, mise en production

État au 11/10/2026. **Rien n'a été appliqué ni déployé** : ni migration, ni
fonction Supabase, ni fusion vers `main`, ni publication Netlify.

## 1. Audit des migrations 0135, 0136, 0137 et 0138 (contre la production réelle)

Les vérifications ont été faites **en lecture seule** sur la production.

**Production actuelle :**
- PostgreSQL 17 ;
- dernière migration : 0133 ;
- extension pgcrypto présente ;
- aucune table en « FORCE RLS » ;
- toutes les tables et fonctions appartiennent à `postgres` ;
- plan Supabase **gratuit**, donc **pas de sauvegarde automatique téléchargeable**.

**Collisions :** aucun nom créé par EVA n'existe déjà en production (tables `eva_*`, fonctions, colonnes).

**Écart dépôt / production :** 27 fonctions de la production diffèrent du dépôt, ainsi qu'une colonne de `bookings` (`admin_cancel_reason`, absente de la production et inutilisée par EVA). Une base locale **identique à la production** pour toutes ces fonctions (`hv_prodlike`) a donc été reconstruite, et **tous les tests ont été rejoués dessus** :

| Suite | Résultat |
|---|---|
| SQL — V1 (0135) | 116 contrôles |
| SQL — phase 2 (0136) | 70 contrôles |
| SQL — Siri (0137) | 25 contrôles |
| Fonction eva-siri | 26 contrôles |
| Interface (V1, phase 2, Siri, mains libres) | 148 contrôles |

**Objets existants modifiés par 0135** (tout le reste est nouveau) :

| Objet | Modification |
|---|---|
| `booking_settings` | 2 colonnes (`work_hours`, `travel_margin_minutes`) et 2 contraintes. Valeurs par défaut identiques aux horaires actuels. |
| `company_settings` | 2 colonnes (`vat_regime_confirmed_at/by`) et 1 déclencheur, qui annule la confirmation si le régime change. |
| 4 fonctions redéfinies | `is_slot_within_business_hours`, `booking_free_slots`, `get_public_booking_settings`, `company_billing_ready`. |

**RLS :** les nouvelles tables ont la RLS activée, avec lecture réservée à l'administrateur. Les écritures passent uniquement par des fonctions qui vérifient le rôle. La table `eva_devices` n'a aucune politique : elle n'est accessible que par les fonctions. Les droits d'exécution sont restreints à `authenticated`, et à `service_role` pour la passerelle Siri.

**Non-régression du site :** le test différentiel `supabase/tests/eva_non_regression.sql` est exécuté sur la base identique à la production, **avant puis après** 0135-0137, et les sorties sont comparées. Il couvre :
- grille complète des horaires sur 2 semaines ;
- réglages publics ;
- réservation client réelle : créneau valide, dimanche, nuit, chevauchement ;
- créneaux libres et déplacement ;
- devis et numérotation ;
- brouillon et émission de facture ;
- parrainage, fidélité et statistiques.

**Seule différence :** un créneau de 4 h commençant à 20 h n'est plus accepté. Il débordait après minuit, c'était un défaut.

**Contrôle préalable :** `supabase/rollback/eva_preflight.sql` (lecture seule) vérifie les empreintes de 21 fonctions dont EVA dépend. Résultat sur la production le 11/10/2026 : **OK**.

**Retour arrière :** `supabase/rollback/eva_0135_0137_rollback.sql` s'exécute en une seule transaction.
- **Ce qu'il fait :** il rend aux 4 fonctions leur définition **et leurs droits de production**, retire les colonnes, contraintes et déclencheur ajoutés, et supprime les objets d'EVA.
- **Testé :** appliquer EVA, l'utiliser, puis revenir en arrière redonne un schéma **identique** à l'état d'origine (comparaison de 2 270 éléments : fonctions, droits, colonnes, contraintes, déclencheurs, politiques).
- **Données :** aucune donnée clients, réservations, devis, factures ou parrainage n'est touchée.

## 2. Fonction eva-siri

**Sécurité :**
- jeton de 192 bits, affiché une seule fois ; seule son empreinte SHA-256 est conservée ;
- un jeton mal formé est rejeté sans aucun accès à la base ;
- jeton révocable, valable 365 jours au plus, 5 appareils au maximum ;
- 20 demandes par minute et par appareil ;
- **lecture** côté serveur : la passerelle `eva_siri_run` est réservée à la clé de service ;
- **actions préparées (0138)** : si l'appareil a été créé avec la case « Autoriser Siri à préparer des actions », Siri peut **préparer**, jamais exécuter : fiche client, devis et facture en brouillon, confirmation ou déplacement d'un rendez-vous (`eva_siri_propose`). L'action attend ensuite votre confirmation dans EVA ;
- **confirmation sécurisée** : les actions sensibles (envoi de devis, émission ou paiement de facture, déplacement, création ou annulation de rendez-vous, crédit fidélité, parrainage, fiche client, horaires, TVA, activation de Siri, création d'un accès Siri) exigent une **connexion de moins de 10 minutes**, vérifiée **par le serveur** (date de connexion dans le jeton de session). Sinon, EVA affiche « Confirmer mon identité » : vous saisissez le mot de passe, puis l'action est relancée une fois ;
- les demandes s'exécutent au nom de l'administrateur créateur, avec les garde-fous d'EVA ;
- aucune IA, donc aucune injection de consignes possible.

**Compatibilité iPhone :**
- l'app Raccourcis envoie la demande en POST JSON avec l'en-tête `x-eva-token` ;
- en mode texte, la réponse est **toujours en code 200**, pour que les messages d'erreur soient **lus** par Siri au lieu d'échouer en silence ; le code réel est dans l'en-tête `X-Eva-Status` ;
- le mode JSON garde les vrais codes HTTP.

**Coûts :**
- aucun service payant ;
- Edge Functions : 500 000 appels par mois sur le plan gratuit, EVA en utilise quelques dizaines par jour ;
- la dictée et la voix d'Apple sont gratuites.

**Face ID, ce qui est réellement intégré :** HAYEVA est un site web, il n'appelle pas Face ID directement. La fenêtre « Confirmer mon identité » est un vrai champ de mot de passe (`autocomplete=current-password`). Si le mot de passe du compte est enregistré dans le trousseau iCloud, l'iPhone propose de le remplir **avec Face ID** : c'est une fonction d'iOS, que nous ne contrôlons pas. Sans mot de passe enregistré, il faut le taper. Aucun code n'est jamais dicté à voix haute.

**Point d'attention :** si Siri est autorisé écran verrouillé, une personne ayant l'iPhone en main peut entendre le planning. Réglage iPhone : *Réglages > Face ID et code > Autoriser l'accès en mode verrouillé > Siri*.

## 3. TVA : jamais de taux non confirmé

- **Facture définitive :** impossible tant que le régime de TVA n'est pas confirmé dans EVA. Même si le reste est complet, `company_billing_ready()` reste à faux.
- **Brouillons de facture :** ceux préparés avant la confirmation sont **réalignés automatiquement** sur le taux confirmé. Les taux saisis à la main sur une ligne sont conservés, et une facture émise n'est jamais touchée (tests J1 à J6).
- **PDF de devis :** tant que le régime n'est pas confirmé, ni « TTC » ni « nets de taxe », seulement « Montants en euros. ».
- **PDF de brouillon de facture :** il porte la mention « Régime de TVA non confirmé : taux indicatifs ».
- **Mention « TVA non applicable, art. 293 B » :** elle n'est imprimée qu'une fois le régime confirmé.
- **Production actuelle :** régime « assujetti 20 % » **non confirmé**, SIRET vide. Aucune facture émise ; 1 brouillon à 0 %.

## 4. Version de test isolée (sans toucher aux données réelles)

Les déclencheurs de la base appellent les fonctions de **production** par leur adresse. Un projet de test doit donc être isolé ; c'est la double protection ci-dessous.

| Pièce | Rôle |
|---|---|
| `supabase/test-env/isolate_test_project.sql` | Redirige les 14 fonctions vers le projet de test, arrête les tâches planifiées et change le secret interne (la production refuse donc tout appel venant du test). **Refuse de s'exécuter** si la base contient un seul client réel. |
| `supabase/test-env/seed_test_data.sql` | Données fictives : 4 clients en `@exemple.test`, 5 rendez-vous, une intervention, un équipement, un devis brouillon, un code parrain. |
| `index.html` | Sur l'adresse `eva-test--…netlify.app` **uniquement** : bandeau rouge « VERSION DE TEST » et redirection de **toutes** les requêtes vers le projet de test. Si le projet de test n'est pas renseigné, **aucun** appel n'est fait. Sur hayeva.fr, rien ne change (vérifié). |
| `netlify.toml` | Seule la branche `eva-test`, en « branch deploy », est construite en plus de `main`. Ses prévisualisations restent bloquées, car elles parleraient à la production. |

**Projet de test créé :** `hayeva-eva-test` (`hqsszehccqgalkhkdbis`, plan gratuit, même organisation). Vérifié : 0 référence à la production, secrets internes neufs, 0135 → 0138 appliquées, `eva-siri` déployée, données fictives chargées. Une fonction temporaire `eva-test-loader` (protégée par secret, **projet de test uniquement**) a servi au chargement ; elle est neutralisée à la fin et peut être supprimée dans le tableau de bord.

**Quotas gratuits :**
- Supabase (plan Free) : 2 projets actifs par organisation (2 utilisés : production + test), 500 Mo de base par projet, 500 000 appels de fonctions par mois, 50 000 utilisateurs actifs par mois. Un projet gratuit inactif une semaine est **mis en pause** (réactivable gratuitement).
- Netlify (offre gratuite) : le site n'a pas de commande de construction, une publication de branche consomme quelques secondes de construction. Seules `main` et `eva-test` sont construites (`netlify.toml`).

### Étapes, chacune sur votre feu vert

| Étape | Qui | Action |
|---|---|---|
| T1 ✅ | Vous | Autoriser la création d'un **2ᵉ projet Supabase gratuit** « hayeva-eva-test » (0 €, plan gratuit : 2 projets actifs autorisés). |
| T2 ✅ | Claude | Appliquer les migrations, aligner les fonctions sur la production, isoler le projet, déployer `eva-siri` **dans le projet de test uniquement**. |
| T3 | Vous | Dans le projet de test : *Authentication > Users > Add user > Create new user*, avec votre e-mail, un mot de passe de test et « Auto Confirm User ». Ce premier compte confirmé devient **automatiquement** administrateur de test, et les rendez-vous fictifs sont recalés sur ce jour : « demain » contient toujours 3 rendez-vous. Script : `supabase/test-env/auto_admin_first_user.sql`, installé et testé. |
| T4 ✅ | Claude | Renseigner `HV_TEST_URL` et `HV_TEST_KEY` (clé publique du projet de test), puis pousser la branche `eva-test`. |
| T4 | Vous | Dans Netlify : *Site configuration > Build & deploy > Branches and deploy contexts > Branch deploys > Let me add individual branches* → `eva-test`. |
| T5 | Vous | Tests sur l'iPhone (§ 5). |

## 5. Tester EVA sur l'iPhone (version de test)

### A. Ouvrir EVA

1. Dans Safari, ouvrir `https://eva-test--<nom-du-site>.netlify.app` : le bandeau rouge « VERSION DE TEST » doit apparaître.
2. Se connecter avec le compte de test (étape T3).
3. Facultatif : Partager → « Sur l'écran d'accueil ».
4. Ouvrir l'espace Pro → **Plus** → **EVA — Mon assistante**.

### B. Bouton micro

1. Toucher le micro et autoriser **Micro** et **Reconnaissance vocale** à la première demande.
2. Dire « Montre-moi mes interventions de demain ». Réponse attendue : 3 interventions fictives, dites à voix haute.
3. Essayer aussi :
   - « Affiche les clients ayant un entretien à renouveler » ;
   - « Trouve la fiche de Monsieur Martin » ;
   - « Recherche la dernière intervention chez ce client ».

### C. Actions concrètes

Chaque action se vérifie puis se confirme avant d'être exécutée.

| Ce que vous dites | Ce qu'EVA propose |
|---|---|
| « Annule le rendez-vous de Madame Lefèvre » | Motif → **Préparer** → case à cocher → **Confirmer** |
| « Prends un rendez-vous pour Monsieur Dupont jeudi à 15 h » | Choisir la prestation → **Vérifier le créneau** → confirmer |
| « Modifie le devis de Monsieur Martin », puis « Envoie le devis de Monsieur Martin » | Saisie du montant, puis envoi au client fictif |
| « Crée un nouveau client Lucie Durand 06 00 00 00 09 » | Fiche à créer |
| « Crédite 10 € de fidélité à Monsieur Martin » | Motif obligatoire |
| « Prépare le compte rendu de l'intervention de Monsieur Martin » | Compte rendu à compléter |

À vérifier dans l'administration de test : chaque action apparaît, et rien ne se fait sans confirmation.

### D. « Dis Siri, EVA »

1. **Créer l'accès :**
   - EVA → **Réglages** → « Dis Siri, EVA » → activer « Autoriser les questions par Siri » ;
   - nommer l'appareil (ex. « iPhone de Julien »), cocher « J'ai compris », laisser cochée « Autoriser Siri à **préparer** des actions », puis **Créer l'accès Siri** (EVA peut d'abord demander « Confirmer mon identité ») ;
   - **Copier** le jeton (affiché une seule fois).
2. **Créer le raccourci :**
   1. App **Raccourcis** → **+** → renommer en **EVA**.
   2. Ajouter **Demander une entrée** (type Texte), question « Que souhaitez-vous faire ? » : Siri la pose à voix haute et écoute la réponse.
   3. Ajouter **Obtenir le contenu de l'URL** :
      - URL : celle affichée dans EVA → Réglages (`https://<projet-de-test>.supabase.co/functions/v1/eva-siri`) ;
      - **Méthode** : POST ;
      - **En-têtes** : `x-eva-token` = le jeton copié ;
      - **Corps de la requête** : JSON, clé `text` = variable **Entrée fournie**.
   4. Ajouter **Énoncer le texte**, avec **Contenu de l'URL**.
3. **Essayer :**
   - Dire « **Dis Siri, EVA** », puis « Qu'est-ce que j'ai demain ? » : Siri lit la réponse.
   - Dire « Dis Siri, EVA », puis « Confirme la demande de Madame Lefèvre » : Siri répond « J'ai préparé : … Ouvrez EVA pour vérifier et confirmer ». Dans EVA, l'action attend dans « À confirmer » ; **Confirmer** l'exécute.
   - Dire « Dis Siri, EVA », puis « Déplace le rendez-vous de Monsieur Martin à jeudi 15 h » : action sensible, la confirmation dans EVA demande une connexion récente (mot de passe, ou Face ID via le trousseau).
   - Dire « Dis Siri, EVA », puis « Annule le rendez-vous de Monsieur Dupont » : Siri répond qu'il faut ouvrir EVA. Une annulation ou un envoi n'est **jamais** préparé ni exécuté par la voix seule.
4. **À la fin :** EVA → Réglages → **Révoquer** l'appareil, ou le garder pour la production.

**Limite d'iOS :** aucune application ne peut écouter en permanence. C'est Siri qui lance EVA. Le mode « Dis EVA » dans l'application est expérimental et ne fonctionne que si EVA est ouverte, écran allumé.

## 6. Mise en production (plus tard, feu vert séparé)

1. Rejouer `supabase/rollback/eva_preflight.sql` sur la production : il doit renvoyer seulement « OK ».
2. Sauvegarder : exporter les lignes `company_settings` et `booking_settings` (le plan gratuit n'a pas de sauvegarde automatique).
3. Appliquer 0135, 0136, 0137 et 0138, dans cet ordre.
4. Si Siri est souhaité, déployer `eva-siri` (`--no-verify-jwt`).
5. Fusionner vers `main` : Netlify publie le site.
6. Dans EVA → Réglages : confirmer le régime de TVA réel (rien n'est supposé), puis vérifier les horaires.
7. En cas de problème : appliquer `eva_0135_0137_rollback.sql` (couvre aussi 0138) et revenir au commit précédent sur `main`.
