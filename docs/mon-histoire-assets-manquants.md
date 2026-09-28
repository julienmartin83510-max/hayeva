# « Mon Histoire » — Fichiers définitifs restant à fournir

Le système technique (lecteur vidéo, overlay plein écran, sous-titres,
analytics, responsive, performance) est déjà construit sur le site et
fonctionne dès que ces fichiers réels existent. Aucune fausse vidéo
placeholder n'a été mise en production.

Déposer les fichiers exactement à ces emplacements (créer les dossiers s'ils
n'existent pas) :

| Fichier attendu | Emplacement | Format |
|---|---|---|
| Vidéo principale 16:9 | `images/story/mon-histoire-16x9.mp4` | MP4 H.264, ≤ ~15 Mo idéalement (site déjà optimisé, pas de gros fichiers) |
| Vidéo verticale 9:16 | `images/story/mon-histoire-9x16.mp4` | MP4 H.264 |
| Image d'affiche (poster) | `images/story/mon-histoire-poster.jpg` | JPG, 1920×1080, < 300 Ko |
| Sous-titres français | `images/story/mon-histoire.fr.vtt` | WebVTT, voir script fourni dans `mon-histoire-production-package.md` §2 |
| Teaser 30s (optionnel, réseaux sociaux) | `images/story/mon-histoire-teaser-30s.mp4` | MP4 H.264 |
| Teaser 15s (optionnel) | `images/story/mon-histoire-teaser-15s.mp4` | MP4 H.264 |

Tant que ces fichiers n'existent pas :
- Le bouton **« Voir mon histoire en vidéo »** reste visible sur le site,
  s'ouvre normalement, affiche un état clair *« Vidéo bientôt disponible »*
  plutôt qu'un lecteur cassé ou une fausse vidéo.
- Dès que les fichiers sont déposés aux emplacements ci-dessus, le lecteur
  les détecte et fonctionne automatiquement — **aucune autre modification de
  code n'est nécessaire.**

Si de vraies photos de Julien Martin (ou de son grand-père/père, si elles
existent) sont fournies pour la production vidéo elle-même, les transmettre
séparément à l'équipe de tournage/montage — jamais laisser un outil de
génération vidéo inventer ces visages (voir la charte dans
`mon-histoire-production-package.md`, §4).
