# HAYEVA SIGNATURE V5 — Design system « Motion Signature »

Source unique des réglages de mouvement, d'élévation et de focus de toute la
plateforme (site public, réservation, espaces particulier et professionnel,
administration, assistant, PWA).

- CSS : bloc `<style id="hv-signature-v5">` de `index.html` (jetons + composants).
- JS : `assets/hv-fx.js` (`window.HvFx`) et `assets/hv-illus.js` (`window.HvIllus`),
  sur la bibliothèque `vendor/hayeva-motion-14.0.0.min.js` (Motion 14, sous-ensemble
  hébergé, MIT). Pas de React dans le projet : Framer Motion n'est pas utilisé.

## Principes

1. Le logo officiel n'est jamais redessiné, recoloré ni déformé.
2. Couleurs : voir `black-signature.md` (cuivre = action principale, bleu nuit
   et ivoire = surfaces). Les animations n'introduisent aucune couleur propre.
3. On anime `transform` et `opacity` (exception : la coche de validation, dessinée
   par `clip-path` sur un élément de 28 px).
4. Rien d'indispensable à la compréhension n'est porté par une animation ; tout
   s'arrête avec « réduire les animations » (les durées passent à 0).
5. Aucune confirmation n'est animée avant la réponse réelle du serveur.
6. Les décors en boucle s'arrêtent hors écran et sous un espace ouvert.

## Jetons

| Jeton | Valeur | Usage |
|---|---|---|
| `--sig-dur-instant` | 100 ms | enfoncement à l'appui |
| `--sig-dur-press` | 140 ms | retour d'un bouton, puce, case |
| `--sig-dur-state` | 240 ms (180 ms dans les espaces pro/admin) | onglet, filtre, état |
| `--sig-dur-card` | 300 ms (220 ms) | déploiement de carte |
| `--sig-dur-page` | 360 ms (240 ms) | changement de vue |
| `--sig-dur-open` | 420 ms | modale, panneau, fiche |
| `--sig-dur-close` | 240 ms | fermeture (toujours plus courte que l'ouverture) |
| `--sig-dur-section` | 520 ms (320 ms) | apparition de section |
| `--sig-ease-standard` | `cubic-bezier(.2,0,0,1)` | cas général |
| `--sig-ease-enter` | `cubic-bezier(0,0,.2,1)` | entrées |
| `--sig-ease-exit` | `cubic-bezier(.3,0,1,1)` | sorties |
| `--sig-ease-emph` | `cubic-bezier(.16,1,.3,1)` | moments importants |
| `--sig-ease-spring` | `cubic-bezier(.34,1.56,.64,1)` | relâché d'un appui |
| `--sig-move-xs/sm/md/lg` | 4 / 8 / 16 / 24 px | distances de déplacement |
| `--sig-scale-press` / `--sig-scale-hover` | 0,97 / 1,01 | échelles |
| `--sig-op-muted` / `--sig-op-disabled` | 0,64 / 0,45 | opacités |
| `--sig-elev-0…4` | ombres | profondeur (cartes 2, survol 3, modales 4) |
| `--sig-focus` | `#8A5A2B` sur clair, `#D7A16B` sur sombre (Black Signature) | anneau de focus clavier (3 px, décalé de 2 px) |

Les anciens jetons V4 (`--hv-t-*`, `--hv-dur-*`, `--hv-ease-*`, `--hv-shadow-*`)
sont des alias de ces jetons. En JS : `HvFx.t('press' | 'state' | 'open' | 'close')`.

## Composants et comportements

| Composant | Où | Détail |
|---|---|---|
| Indicateur d'onglet glissant | barres basses, familles, filtres, période du planning | `hv-fx.js` (`IND`) |
| Transition de vue orientée | onglets des 3 espaces | `--hv-view-dx` selon le sens |
| Révélation de section | `.reveal-on-scroll`, `.section-head`, `[data-hv-reveal]` | une seule fois, sans bloquer le défilement |
| Révélation + parallaxe de photo | `.photo-frame` | ±16 px max, photos visibles seulement |
| Progression de lecture | site public | barre cuivre de 3 px, masquée sous un espace |
| En-tête posé | `header.hv-scrolled` | ombre, sans changement de hauteur |
| Signature lumineuse | CTA principaux (prendre RDV, réserver, confirmer) | un reflet au survol/focus |
| Continuité carte ↔ fiche | fiches « Détails » | titre et prix qui volent, retour à la carte |
| Rappel de prestation + progression | réservation | `#bkChosen`, `#bkProgress` |
| Validation d'un rendez-vous | étape 4 (après enregistrement réel) | sceau : anneau cuivre tracé, logo officiel, pastille verte |
| Carte « À traiter maintenant » | administration | point cuivre en pulsation lente |
| Compteur de statistiques réelles | admin, pro, parrainage | `HvFx` (COUNT_SEL), valeur serveur toujours prioritaire |
| Déblocage parrainage | seuil de versement réellement atteint | `.ec-amb-progress.is-unlocked` |
| Assistant | bulle site + espaces | s'efface au défilement, ouverture depuis la bulle |
| Squelettes, listes vides, erreurs | partout | `.ec-loading`, `.ec-empty`, « Réessayer » |
| Messages de confirmation | admin et espaces | `hvToast()` après réponse serveur |

## Ajouter une animation

1. Utiliser un jeton existant (durée, courbe, distance) — jamais une valeur en dur.
2. Placer la règle dans un `@media (prefers-reduced-motion: no-preference)`.
3. Préférer `animation-fill-mode: backwards` pour une entrée : l'élément retrouve
   ses états `:hover`/`:active` une fois l'animation terminée.
4. Pour un décor en boucle, le ranger sous `.hv-illus` (suspendu hors écran).
