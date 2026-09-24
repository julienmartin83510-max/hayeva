# Personnage Hayeva — version actuelle : PNG statique + CSS/JS

**Approche WebM/Blender/Mixamo abandonnée pour l'instant** (gardée en
archive plus bas si vous voulez y revenir plus tard). L'intégration
actuelle, déjà codée et en ligne dans `sudmaintenance.html`, utilise une
**seule image PNG transparente**, animée uniquement en CSS/JS (aucune
vidéo, aucun WebGL, aucune librairie).

## Fichier attendu — un seul

| Fichier | Format | Résolution | Notes |
|---|---|---|---|
| `character.png` | PNG-24, **fond transparent** | carré, 512×512 px+ | Buste/portrait, posture neutre de repos (bras croisés ou main sur la hanche), cadrage identique à ce que montrera le personnage sur le site |

À déposer dans `images/assistant-character/character.png`. **Tant que ce
fichier n'existe pas**, le site affiche automatiquement l'ancien bouton
texte « ✨ Assistant Hayeva » — rien n'est cassé, aucune image factice
n'a été créée.

## Charte du personnage
- Technicien HAYEVA adulte, sympathique, professionnel — jamais cartoon.
- Polo bleu marine avec le **vrai logo** (`images/brand/hayeva-logo.png`),
  appliqué comme décalque, jamais redessiné par une IA.
- Yeux bleu-vert (cohérent avec `--turquoise:#2FB6A8`).
- Rendu semi-réaliste premium.

## Comment l'image est utilisée (déjà codé)
Une seule image, réutilisée à deux endroits :
- Bouton flottant fermé (avec une bulle "Besoin d'aide ?" à côté, desktop/tablette ; bulle masquée sur mobile où seul le personnage réduit reste visible).
- Petit avatar dans l'en-tête de la fenêtre de chat une fois ouverte.

Repli automatique (`onerror`) si le fichier est absent/casse : le bouton
retrouve son apparence texte d'origine, le panneau affiche "✨" à la place
de l'avatar — jamais d'icône cassée.

## Animations (CSS uniquement, déjà codées)
| État | Effet CSS | Déclenché par |
|---|---|---|
| `idle` | Respiration très légère en boucle (translateY + scale) | Par défaut |
| Ouverture du chat | Petit salut (léger zoom + rotation, une fois) | `openPanel()` |
| Réflexion | Pulsation discrète + texte "Je réfléchis…" | Pendant l'attente de la réponse IA |
| Réponse | Halo turquoise discret en boucle courte | À l'arrivée de la réponse, ~1,4 s |
| Succès | Petit rebond positif, puis retour au repos | Quand une prestation/un devis est proposé |

`prefers-reduced-motion` : toutes les animations sont désactivées via une
règle CSS globale, le personnage reste alors parfaitement statique.

## Testé
Desktop, tablette (768px) et mobile (375px) — bouton/personnage bien
positionné, n'empiète sur aucun bouton important, repli fonctionnel
confirmé (fichier absent testé en conditions réelles).

---

## Archive — approche vidéo (WebM), abandonnée pour l'instant

Si vous souhaitez repasser à des animations vidéo pré-rendues plus tard
(rendu 3D réel via Blender, mouvement complet plutôt qu'un CSS simple),
l'ancienne spécification (6 fichiers `idle.webm`/`hello.webm`/
`thinking.webm`/`talking.webm`/`success.webm`/`poster.png`, WebM/VP9
alpha, 512×512, <400 Ko/clip) reste valable et peut être redemandée à tout
moment — l'architecture du widget (déclencheurs JS déjà en place) est
compatible avec les deux approches.
