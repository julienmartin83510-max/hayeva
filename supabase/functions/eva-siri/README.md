# EVA — « Dis Siri, EVA » et « Dis EVA »

## 1. « Dis Siri, EVA » (raccourci iPhone) — lecture seule

**Fonctionnement.** Siri lance un raccourci nommé « EVA ». Le raccourci dicte la
question, l'envoie à la fonction serveur `eva-siri` avec le jeton de l'iPhone,
puis lit la réponse à voix haute.

**Exemples de questions :**
- « qu'est-ce que j'ai demain ? »
- « combien de rendez-vous ai-je cette semaine ? »
- « fiche de Monsieur Martin »
- « entretiens à renouveler »
- « mes disponibilités jeudi »
- « combien j'ai facturé ce mois ? »

**Sécurité :**
- **L'accès est désactivé par défaut.** Il s'active dans EVA → Réglages → « Dis Siri, EVA ».
- **Un jeton par appareil :**
  - 192 bits, affiché une seule fois ;
  - seule son empreinte SHA-256 est conservée en base ;
  - valable 365 jours au plus, révocable à tout moment ;
  - 5 appareils actifs au maximum.
- **Lecture seule.** Les actions (créer, envoyer, annuler, modifier) ne sont jamais exécutées par la voix. EVA répond « ouvrez EVA » et propose un lien qui ouvre l'application avec la demande pré-remplie, à relire puis à confirmer.
- **Mêmes garde-fous que l'application :**
  - rôle administrateur revérifié à chaque demande ;
  - EVA et ses agents doivent être activés ;
  - 20 demandes par minute par appareil, plus les limites générales d'EVA ;
  - chaque commande est inscrite au journal sous la forme « Siri : … ».
- **Gratuit.** Le raccourci repose sur la dictée et la voix d'Apple, la compréhension sur les règles locales d'EVA, sans IA et sans service payant. L'appel de la fonction reste dans le quota gratuit de Supabase.

**Créer le raccourci** (mode d'emploi aussi affiché dans EVA → Réglages) :
1. App **Raccourcis** → **+** → nommer le raccourci **EVA**.
2. Ajouter l'action **Demander une entrée** (type Texte), question « Que souhaitez-vous faire ? » : Siri la pose à voix haute et écoute la réponse.
3. Ajouter l'action **Obtenir le contenu de l'URL** :
   - adresse : `https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/eva-siri` ;
   - méthode : **POST** ;
   - en-tête : `x-eva-token` = le jeton de l'iPhone ;
   - corps : **JSON**, clé `text` = **Entrée fournie**.
4. Ajouter l'action **Énoncer le texte** avec le **Contenu de l'URL**.
5. Dire : « Dis Siri, EVA ».

**Variante avancée.** Avec l'en-tête `Accept: application/json`, la réponse est
`{ "speech": "…", "open_url": "…" }`. Le raccourci peut alors ouvrir `open_url`
pour les actions.

**Mise en service** (NON effectuée, à valider) :
1. Appliquer la migration `0137_eva_siri.sql`, après `0135` et `0136`.
2. Déployer la fonction : `supabase functions deploy eva-siri --no-verify-jwt`.
   - Elle utilise les variables `SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY`, déjà fournies par Supabase.
   - `PUBLIC_SITE_URL` est facultative.
3. Publier le site, qui contient la section Réglages et le lien `?eva=`.
4. Dans EVA : activer Siri, créer l'accès de l'iPhone, puis créer le raccourci.

**Fichier partagé.** `_shared/eva-intents.js` est une **copie identique** de
`assets/eva/eva-intents.js`. Un test vérifie l'égalité des deux fichiers ;
à recopier après chaque modification de l'interprète.

## 2. « Dis EVA » dans l'application — étude et prototype

**Limites d'iOS :**
- Aucune application ni aucun site ne peut écouter en arrière-plan, ni quand l'écran est verrouillé. Seul Siri, intégré au système, le peut ; c'est pourquoi « Dis Siri, EVA » est la voie recommandée.
- Dans Safari ou en application web, le micro ne fonctionne que page ouverte et visible, après un geste de l'utilisateur.

| Solution | Coût | Confidentialité | Faisabilité iPhone |
|---|---|---|---|
| Reconnaissance du navigateur, écoute continue pendant qu'EVA est ouverte (**prototype livré**) | Gratuit | Sur iPhone, l'audio passe par la dictée d'Apple, traitée sur ses serveurs, pendant toute la durée du mode | Oui, écran allumé. iOS peut couper l'écoute : EVA la relance, ou demande un toucher si le système refuse |
| Détection locale (Vosk / WebAssembly, modèle français d'environ 40 Mo) | Gratuit | Audio traité sur l'appareil | Possible, mais lourd : téléchargement, mémoire, batterie. À tester sur l'iPhone avant décision |
| Mot d'activation commercial (Picovoice…) | Payant en usage professionnel | Local | Écarté : abonnement |
| Application native | Compte développeur Apple payant | Local | Même limite : pas d'écoute en arrière-plan |

**Prototype livré**, expérimental et désactivé par défaut :
1. **Activation volontaire, en deux temps :**
   - le mode se propose dans EVA → Réglages ;
   - l'écoute commence seulement après un toucher sur « Écouter “Dis EVA” ».
2. **Indicateur permanent** (point animé, « Mains libres : dites « EVA, … » ») et bouton **Arrêter**.
3. **Seules les phrases commençant par « EVA »** sont utilisées. Les autres sont ignorées, jamais affichées ni envoyées au serveur d'EVA.
4. **Arrêt automatique :**
   - quand EVA se ferme ;
   - en ouvrant l'onglet Réglages ;
   - quand l'écran est quitté ;
   - après 3 minutes sans « EVA » ;
   - si le système refuse le micro.
5. **EVA ne s'entend pas elle-même :** l'écoute est suspendue pendant qu'elle parle.

**Vérifié en simulation automatisée** : écoute uniquement après le geste,
conversation ambiante ignorée, commande « EVA … » exécutée sur les données
réelles de la base de test, relance automatique, arrêts. **À valider sur
l'iPhone** : la tenue de l'écoute continue dans Safari dépend de la version
d'iOS.
