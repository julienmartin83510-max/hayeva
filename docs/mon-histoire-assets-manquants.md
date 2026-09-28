# « Mon Histoire » — Fichiers définitifs restant à produire/fournir

Le système technique (lecteur vidéo, overlay plein écran, sous-titres,
analytics, responsive, performance) est déjà construit sur le site et
fonctionne dès que les fichiers ci-dessous existent aux emplacements exacts
indiqués. **Aucune fausse vidéo placeholder n'a été mise en production** —
tant qu'un fichier n'existe pas, le lecteur affiche proprement
« Vidéo bientôt disponible » plutôt qu'un écran cassé.

Voir `docs/mon-histoire-shot-list.md` pour la liste plan par plan (script,
storyboard, prompts de génération) à produire pour arriver au montage final.

## Arborescence (déjà créée dans le projet, avec un README dans chaque dossier)

```
images/story/
  master/       → les 2 fichiers vidéo finaux lus par le site
  shots/        → les plans individuels bruts, avant montage (espace de travail)
  audio/        → voix off, musique, bruitages (espace de travail)
  subtitles/    → le fichier .vtt lu par le site
  posters/      → l'image d'affiche lue par le site
  teasers/      → versions courtes pour usage externe (réseaux sociaux)
```

## Fichiers lus directement par le site

| Fichier attendu | Emplacement exact | Format | Statut |
|---|---|---|---|
| Vidéo principale 16:9 | `images/story/master/mon-histoire-16x9.mp4` | MP4 H.264 | **Manquant — nécessite génération/tournage + montage** |
| Vidéo verticale 9:16 | `images/story/master/mon-histoire-9x16.mp4` | MP4 H.264 | **Manquant — idem** |
| Image d'affiche | `images/story/posters/mon-histoire-poster.jpg` | JPG, 1920×1080, < 300 Ko | **Manquant — à extraire du montage final** |
| Sous-titres français | `images/story/subtitles/mon-histoire.fr.vtt` | WebVTT | **Fait — fichier réel déjà livré et testé** |

Dès que les 3 fichiers manquants sont déposés à ces emplacements exacts, le
bouton « Voir mon histoire en vidéo » fonctionne intégralement — **aucune
autre modification de code n'est nécessaire.** Un fichier EDL
(`images/story/mon-histoire-edl.csv`) liste déjà, plan par plan, où chaque
export de `shots/` doit se placer sur la timeline une fois généré.

## Fichiers de production (espace de travail, non lus par le site)

| Dossier | Contenu attendu |
|---|---|
| `images/story/shots/` | `shot-001.mp4` à `shot-023.mp4` (voir `mon-histoire-shot-list.md`), assemblés ensuite dans `master/` |
| `images/story/audio/` | Voix off finale, musique, bruitages, avant mixage dans les fichiers `master/` |
| `images/story/teasers/` | `mon-histoire-teaser-30s.mp4`, `mon-histoire-teaser-15s.mp4` — usage réseaux sociaux, non utilisés par le lecteur du site |

## Photos de référence (facultatives, jamais bloquantes)

Aucune photo de Julien Martin, de son père ou de son grand-père n'est
requise pour produire une version complète du film : le storyboard est
conçu dès le départ pour fonctionner sans (silhouettes, mains, plans de
dos — voir `mon-histoire-shot-list.md` § Photos utiles). Si ces photos sont
fournies plus tard, seuls certains plans précis pourront être améliorés/
retournés avec un visage réel — jamais une condition pour publier le film.
