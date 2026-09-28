# HAYEVA — « Mon Histoire » — Shot list définitive (production plan par plan)

Ce document est la référence unique pour générer/tourner chaque plan
séparément. Il remplace la numérotation précédente par une numérotation
strictement séquentielle (SHOT 001 → SHOT 023) alignée sur le script voix
off final.

**Règle appliquée à tous les plans ci-dessous, sans exception** (mise à
jour suite à confirmation : aucune photo ancienne ni de référence actuelle
n'est disponible pour l'instant) :

- **Aucun visage n'est généré ou présenté comme celui de Julien Martin, de
  son père, de son grand-père, ou de Julien adolescent/enfant.**
- Tous les plans impliquant une personne utilisent : silhouettes, plans de
  dos, cadrages ¾ non identifiables, mains, plans serrés, POV, gestes
  professionnels, détails d'outils et d'environnement.
- Si Julien fournit des photos plus tard, seuls les plans listés en fin de
  document (§ Photos utiles) devront être régénérés/retournés avec un
  visage identifiable — le reste du montage n'a pas besoin de changer.

Chaque plan liste un **fichier final attendu** dans
`images/story/shots/shot-0NN.mp4` (voir `images/story/shots/README.md`).
Ratio de génération principal : 16:9. Une déclinaison 9:16 est notée quand
son cadrage diffère du simple recadrage du 16:9.

---

## SHOT 001
- **TIMECODE** : 00:00–00:06
- **DURÉE** : 6s
- **RATIO** : 16:9 (9:16 : recadrer verticalement sur l'horizon, pas de recadrage automatique)
- **DESCRIPTION** : Plan aérien, paysage du sud de la France au lever du jour.
- **PERSONNAGE** : Aucun.
- **ACTION** : Descente lente de la caméra vers le paysage.
- **ENVIRONNEMENT** : Campagne provençale, lumière dorée du matin.
- **CAMÉRA** : Plan large aérien (drone).
- **MOUVEMENT** : Descente continue, lente.
- **LUMIÈRE** : Lever de soleil, tons chauds/dorés.
- **SON** : Vent léger, ambiance extérieure calme.
- **VOIX OFF** : « Je m'appelle Julien. Je suis originaire du Muy. »
- **TRANSITION** : Fondu d'ouverture.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic aerial drone shot, southern French countryside at sunrise, warm golden light, slow continuous descending movement, photorealistic, documentary premium quality, natural film grain, no text overlays, no people visible"
- **NEGATIVE PROMPT** : voir liste globale (§ Negative prompt commun) + "no urban skyline, no modern wind turbines, no visible drone in frame, no text, no logo"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-001.mp4`

## SHOT 002
- **TIMECODE** : 00:06–00:14
- **DURÉE** : 8s
- **RATIO** : 16:9
- **DESCRIPTION** : Maison ancienne, extérieur, hiver.
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune, plan contemplatif.
- **ENVIRONNEMENT** : Maison de campagne ancienne, ciel gris-bleu.
- **CAMÉRA** : Plan large statique avec très léger drift.
- **MOUVEMENT** : Quasi statique, dérive minimale.
- **LUMIÈRE** : Froide, fin d'après-midi hivernale.
- **SON** : Vent, silence habité.
- **VOIX OFF** : « J'ai grandi dans une grande maison ancienne — une maison qui n'a jamais vraiment su garder la chaleur. »
- **TRANSITION** : Coupe franche depuis SHOT 001.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic establishing shot, old French countryside house in winter, cold blue-grey overcast light, static wide shot with very subtle handheld drift, natural grain, photorealistic, documentary style, no people"
- **NEGATIVE PROMPT** : liste globale + "no fantasy architecture, no exaggerated snow"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-002.mp4`

## SHOT 003
- **TIMECODE** : 00:14–00:18
- **DURÉE** : 4s
- **RATIO** : 16:9
- **DESCRIPTION** : Gros plan sur un vieux radiateur en fonte.
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Intérieur maison ancienne.
- **CAMÉRA** : Macro / gros plan.
- **MOUVEMENT** : Statique.
- **LUMIÈRE** : Froide, naturelle.
- **SON** : Léger grincement métallique.
- **VOIX OFF** : « Attention au chauffage, ça coûte cher. » *(continuité)*
- **TRANSITION** : Coupe.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Close-up macro shot, old cast iron radiator in a dimly lit room, cold natural window light, realistic dust and texture detail, shallow depth of field, photorealistic, no people"
- **NEGATIVE PROMPT** : liste globale
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-003.mp4`

## SHOT 004
- **TIMECODE** : 00:18–00:22
- **DURÉE** : 4s
- **RATIO** : 16:9
- **DESCRIPTION** : Fenêtre à simple vitrage, condensation.
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Intérieur maison ancienne.
- **CAMÉRA** : Gros plan.
- **MOUVEMENT** : Statique.
- **LUMIÈRE** : Froide, contre-jour léger.
- **SON** : Silence.
- **VOIX OFF** : (silence, transition VO)
- **TRANSITION** : Coupe vers SHOT 005.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Close-up shot, single-glazed window with realistic condensation droplets, cold light filtering through, shallow depth of field, photorealistic texture, no people"
- **NEGATIVE PROMPT** : liste globale + "no unrealistic ice patterns, no exaggerated fog"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-004.mp4`

## SHOT 005
- **TIMECODE** : 00:22–00:27
- **DURÉE** : 5s
- **RATIO** : 16:9 (9:16 : cadrage vertical serré dès la génération, centré sur les mains)
- **DESCRIPTION** : Mains d'un adolescent qui débouche un tuyau.
- **PERSONNAGE** : Julien adolescent — **jamais de visage** (mains uniquement).
- **ACTION** : Manie une clé à molette sur un tuyau, sous un évier.
- **ENVIRONNEMENT** : Sous-sol / garage familial.
- **CAMÉRA** : Plan très serré sur les mains.
- **MOUVEMENT** : Léger handheld.
- **LUMIÈRE** : Chaude, pratique (ampoule de garage).
- **SON** : Bruit métallique discret, respiration concentrée.
- **VOIX OFF** : « Vers quinze ans, je m'attaquais déjà à la plomberie de la maison — des tuyaux à déboucher, de petits problèmes à résoudre. »
- **TRANSITION** : Coupe.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Close-up realistic shot of a teenager's hands only (no face, no head visible in frame) using a wrench on a pipe under a sink, warm practical garage lighting, documentary handheld feel, natural skin texture, authentic worn tools"
- **NEGATIVE PROMPT** : liste globale + "no visible face, no head in frame, no deformed hands, no extra fingers, no floating tool"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-005.mp4`

## SHOT 006
- **TIMECODE** : 00:27–00:32
- **DURÉE** : 5s
- **RATIO** : 16:9
- **DESCRIPTION** : Plan large, adolescent vu de dos, tâche terminée.
- **PERSONNAGE** : Julien adolescent — **de dos uniquement**.
- **ACTION** : Se redresse, geste terminé, satisfaction discrète (posture uniquement).
- **ENVIRONNEMENT** : Sous-sol / garage familial.
- **CAMÉRA** : Plan large, depuis l'arrière.
- **MOUVEMENT** : Statique.
- **LUMIÈRE** : Chaude, pratique.
- **SON** : Silence, léger raclement d'outil posé.
- **VOIX OFF** : « Je ne le savais pas encore, mais j'étais déjà en train de découvrir mon futur métier. »
- **TRANSITION** : Fondu enchaîné vers SHOT 007.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Wide realistic shot, teenager seen strictly from behind in a home garage/basement, warm practical lighting, calm accomplished body language, documentary style, face never visible or implied"
- **NEGATIVE PROMPT** : liste globale + "no face turned toward camera, no three-quarter view revealing face"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-006.mp4`

## SHOT 007
- **TIMECODE** : 00:32–00:40
- **DURÉE** : 8s
- **RATIO** : 16:9
- **DESCRIPTION** : Plan de transition — nature morte évoquant la découverte tardive (outils anciens, sans personnage).
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Établi ou atelier, neutre dans le temps.
- **CAMÉRA** : Plan rapproché, nature morte.
- **MOUVEMENT** : Très léger drift.
- **LUMIÈRE** : Neutre, tons doux.
- **SON** : Silence.
- **VOIX OFF** : « Ce que j'ai compris bien plus tard, c'est que ce n'était peut-être pas un hasard. »
- **TRANSITION** : Fondu enchaîné vers la séquence "Trois générations" (SHOT 008–011).
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic still-life shot, an assortment of plumbing and heating tools laid on a wooden workbench, soft neutral lighting, shallow depth of field, photorealistic texture, no people, no visible brand logos"
- **NEGATIVE PROMPT** : liste globale + "no invented logo, no readable text on tools"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-007.mp4`

---

## Séquence « Trois générations » — SHOT 008 à 011

Traitement volontairement symbolique, jamais un visage : uniquement des
objets, outils et lieux, avec un texte sobre en surimpression (typographie
simple, jamais animée façon générique de film d'action).

## SHOT 008
- **TIMECODE** : 00:40–00:44
- **DURÉE** : 4s
- **RATIO** : 16:9
- **DESCRIPTION** : Outil de chauffagiste ancien (ex. manomètre vintage), tons sépia.
- **PERSONNAGE** : Aucun (symbolique : le grand-père n'est jamais incarné).
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Établi ancien, évocation "les Vosges" par la lumière (jamais un lieu réel non vérifié présenté comme authentique).
- **CAMÉRA** : Plan rapproché.
- **MOUVEMENT** : Statique.
- **LUMIÈRE** : Sépia doux, chaude.
- **SON** : Souffle de vent léger.
- **VOIX OFF** : « Mon père avait été formé à la plomberie. Mon grand-père, lui, travaillait dans le chauffage — dans les Vosges. »
- **TRANSITION** : Fondu enchaîné vers SHOT 009.
- **TEXTE À L'ÉCRAN** : « GRAND-PÈRE — CHAUFFAGE »
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic close-up still-life, a vintage heating engineer's tool (old pressure gauge or wrench) on a worn wooden surface, warm sepia-toned lighting, shallow depth of field, photorealistic, no people, no readable brand text"
- **NEGATIVE PROMPT** : liste globale + "no invented person, no fabricated face, no fake vintage photograph with a face"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-008.mp4`

## SHOT 009
- **TIMECODE** : 00:44–00:48
- **DURÉE** : 4s
- **RATIO** : 16:9
- **DESCRIPTION** : Établi de plomberie, tons plus "années 90".
- **PERSONNAGE** : Aucun (symbolique : le père n'est jamais incarné).
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Atelier de plomberie.
- **CAMÉRA** : Plan rapproché.
- **MOUVEMENT** : Statique.
- **LUMIÈRE** : Tons neutres, légèrement plus "modernes" que SHOT 008.
- **SON** : Silence.
- **VOIX OFF** : (continuité silencieuse)
- **TRANSITION** : Fondu enchaîné vers SHOT 010.
- **TEXTE À L'ÉCRAN** : « PÈRE — PLOMBERIE »
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic close-up still-life, plumbing tools and pipe fittings on a workbench, neutral warm lighting evoking the 1990s, shallow depth of field, photorealistic, no people"
- **NEGATIVE PROMPT** : liste globale
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-009.mp4`

## SHOT 010
- **TIMECODE** : 00:48–00:52
- **DURÉE** : 4s
- **RATIO** : 16:9
- **DESCRIPTION** : Établi ou véhicule HAYEVA actuel.
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Atelier/van HAYEVA d'aujourd'hui.
- **CAMÉRA** : Plan rapproché puis léger élargissement.
- **MOUVEMENT** : Très léger zoom arrière.
- **LUMIÈRE** : Neutre, actuelle.
- **SON** : Silence.
- **VOIX OFF** : « Trois générations. Une même attirance pour ce métier — sans qu'aucun de nous ne l'ait vraiment choisi comme ça. »
- **TRANSITION** : Fondu enchaîné vers SHOT 011.
- **TEXTE À L'ÉCRAN** : « JULIEN — PLOMBERIE • CHAUFFAGE • CLIMATISATION »
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic close-up of modern plumbing/heating/climate control tools and equipment on a HAYEVA service vehicle workbench, neutral present-day lighting, shallow depth of field, photorealistic, no people, no visible invented logos"
- **NEGATIVE PROMPT** : liste globale + "no AI-generated logo — real HAYEVA logo only, composited in post-production if shown"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-010.mp4`

## SHOT 011
- **TIMECODE** : 00:52–00:56
- **DURÉE** : 4s
- **RATIO** : 16:9
- **DESCRIPTION** : Plan de clôture de la séquence, les trois objets/époques réunis symboliquement.
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Neutre / composite des trois précédents.
- **CAMÉRA** : Plan large ou triptyque.
- **MOUVEMENT** : Statique.
- **LUMIÈRE** : Transition sépia → neutre.
- **SON** : Silence.
- **VOIX OFF** : (continuité silencieuse)
- **TRANSITION** : Coupe vers SHOT 012 (formation).
- **TEXTE À L'ÉCRAN** : « TROIS GÉNÉRATIONS » puis « UNE MÊME ATTIRANCE POUR LE MÉTIER »
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic composite still shot, three eras of plumbing/heating tools arranged together symbolically, soft lighting transition from sepia to neutral tones, photorealistic, no people, sober typography space reserved for text overlay in post-production"
- **NEGATIVE PROMPT** : liste globale + "no Hollywood-style dramatic lighting, no lens flare overload"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-011.mp4`

---

## SHOT 012
- **TIMECODE** : 00:56–01:06
- **DURÉE** : 10s
- **RATIO** : 16:9
- **DESCRIPTION** : Mains sur des schémas techniques, formation.
- **PERSONNAGE** : Julien (jeune) — **mains uniquement, pas de visage**.
- **ACTION** : Étudie/feuillette des plans techniques.
- **ENVIRONNEMENT** : Centre de formation / atelier.
- **CAMÉRA** : Plan moyen sur le plan de travail.
- **MOUVEMENT** : Léger travelling.
- **LUMIÈRE** : Neutre d'atelier.
- **SON** : Pages, ambiance atelier discrète.
- **VOIX OFF** : « Bac professionnel, CAP plomberie, puis une mention complémentaire en maintenance des équipements de chauffage. »
- **TRANSITION** : Coupe.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic shot of hands studying technical heating/plumbing diagrams on a workbench, neutral workshop lighting, documentary texture, no face in frame"
- **NEGATIVE PROMPT** : liste globale + "no garbled diagram text, no fictional certification logos, no face"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-012.mp4`

## SHOT 013
- **TIMECODE** : 01:06–01:14
- **DURÉE** : 8s
- **RATIO** : 16:9
- **DESCRIPTION** : Julien technicien s'exerçant, cadrage non identifiable.
- **PERSONNAGE** : Julien — **dos ou ¾ non identifiable**.
- **ACTION** : Répare/manipule un équipement en atelier.
- **ENVIRONNEMENT** : Atelier de formation.
- **CAMÉRA** : Plan moyen, angle qui évite le visage.
- **MOUVEMENT** : Léger handheld documentaire.
- **LUMIÈRE** : Naturelle d'atelier.
- **SON** : Outils, ambiance atelier.
- **VOIX OFF** : « Mais ce qui m'a le plus marqué, ce sont les dépannages chez des particuliers. »
- **TRANSITION** : Coupe.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic documentary shot of a technician practicing a plumbing/heating repair in a workshop, framed from behind or at a three-quarter angle that keeps the face out of frame, authentic work clothes, natural lighting, calm focused body language"
- **NEGATIVE PROMPT** : liste globale + "no face visible, no identifiable facial features"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-013.mp4`

## SHOT 014
- **TIMECODE** : 01:14–01:20
- **DURÉE** : 6s
- **RATIO** : 16:9 (9:16 : cadrage vertical suivant la marche, plan resserré)
- **DESCRIPTION** : Julien marche vers la maison d'un client, caisse à outils en main, polo HAYEVA.
- **PERSONNAGE** : Julien — **de dos ou de profil lointain, non identifiable**.
- **ACTION** : Marche vers une maison, caisse à outils à la main.
- **ENVIRONNEMENT** : Rue résidentielle / allée d'une maison.
- **CAMÉRA** : Plan large puis suivi (travelling arrière ou latéral).
- **MOUVEMENT** : Travelling d'accompagnement.
- **LUMIÈRE** : Naturelle, jour.
- **SON** : Pas sur gravier/trottoir, ambiance de quartier calme.
- **VOIX OFF** : (continuité silencieuse ou reprise de "une panne, en plein hiver...")
- **TRANSITION** : Coupe.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic tracking shot, a technician wearing a HAYEVA polo shirt (real logo composited in post-production) walking toward a residential house entrance carrying a toolbox, filmed from behind or at a distance that keeps the face unidentifiable, natural daylight, documentary style"
- **NEGATIVE PROMPT** : liste globale + "no visible identifiable face, no AI-generated logo on the polo — leave a plain placeholder area for logo compositing"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-014.mp4`

## SHOT 015
- **TIMECODE** : 01:20–01:26
- **DURÉE** : 6s
- **RATIO** : 16:9
- **DESCRIPTION** : Ouverture de la caisse à outils, préparation de l'intervention.
- **PERSONNAGE** : Julien — **mains uniquement**.
- **ACTION** : Ouvre la caisse à outils, sélectionne un outil.
- **ENVIRONNEMENT** : Intérieur, près d'un équipement de chauffage/plomberie.
- **CAMÉRA** : Plan rapproché sur les mains et la caisse.
- **MOUVEMENT** : Statique ou très léger handheld.
- **LUMIÈRE** : Intérieure naturelle.
- **SON** : Métal, clic d'ouverture de la caisse.
- **VOIX OFF** : « Une panne, en plein hiver — et ce moment où le problème est réglé... »
- **TRANSITION** : Coupe.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Close-up realistic shot of hands opening a professional toolbox and selecting a tool, natural indoor lighting, documentary texture, no face in frame"
- **NEGATIVE PROMPT** : liste globale + "no face, no deformed hands"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-015.mp4`

## SHOT 016
- **TIMECODE** : 01:26–01:34
- **DURÉE** : 8s
- **RATIO** : 16:9
- **DESCRIPTION** : Réparation en cours, geste précis et calme.
- **PERSONNAGE** : Julien — **mains/¾ non identifiable**.
- **ACTION** : Répare un équipement (plomberie ou chauffage).
- **ENVIRONNEMENT** : Intérieur résidentiel.
- **CAMÉRA** : Plan moyen puis rapproché sur le geste.
- **MOUVEMENT** : Handheld documentaire léger.
- **LUMIÈRE** : Intérieure naturelle, chaleureuse.
- **SON** : Outils, ambiance calme.
- **VOIX OFF** : « ...où les gens nous remercient vraiment. J'avais trouvé ce qui me plaisait : comprendre un problème, trouver une solution, rendre service. »
- **TRANSITION** : Coupe vers la séquence "Le déclic" (SHOT 017).
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic documentary shot, hands and partial body (no identifiable face) calmly repairing a home heating/plumbing appliance, warm natural indoor light, handheld camera, authentic tools, no exaggerated expressions"
- **NEGATIVE PROMPT** : liste globale + "no unrealistic plumbing configuration, no impossible pipe connections, no face"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-016.mp4`

---

## Séquence « Le déclic » — SHOT 017 à 020

Un mouvement de caméra continu si possible (un seul plan étiré en 4
segments pour la production), ou 4 plans raccordés en fondu si générés
séparément. Aucun texte à l'écran ici — l'effet doit être uniquement visuel.

## SHOT 017
- **TIMECODE** : 01:34–01:38
- **DURÉE** : 4s
- **RATIO** : 16:9
- **DESCRIPTION** : Très gros plan sur un équipement de chauffage (chaudière ou radiateur).
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Intérieur, près de l'équipement.
- **CAMÉRA** : Extrême gros plan.
- **MOUVEMENT** : Début du travelling arrière (amorce).
- **LUMIÈRE** : Intérieure neutre.
- **SON** : Léger ronronnement de chaudière.
- **VOIX OFF** : « Une question m'est restée en tête, longtemps : »
- **TRANSITION** : Continuité directe vers SHOT 018 (même mouvement).
- **PROMPT DE GÉNÉRATION VIDÉO** : "Extreme close-up realistic shot of a heating boiler or radiator, beginning of a slow continuous pull-back camera movement, neutral indoor lighting, photorealistic texture, no people"
- **NEGATIVE PROMPT** : liste globale + "no graphic overlay, no HUD, no infographic elements"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-017.mp4`

## SHOT 018
- **TIMECODE** : 01:38–01:44
- **DURÉE** : 6s
- **RATIO** : 16:9
- **DESCRIPTION** : La caméra continue de reculer, la pièce entière apparaît.
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Intérieur résidentiel complet.
- **CAMÉRA** : Plan large progressif.
- **MOUVEMENT** : Travelling/dolly arrière continu (suite de SHOT 017).
- **LUMIÈRE** : Transition intérieure → naturelle.
- **SON** : L'ambiance s'élargit avec le mouvement.
- **VOIX OFF** : « est-ce que l'équipement installé chez ce client est vraiment adapté à son logement, à ses besoins ? »
- **TRANSITION** : Continuité directe vers SHOT 019.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic continuous dolly-out shot, smoothly pulling back from the heating unit to reveal the entire room, natural lighting transition, photorealistic, documentary premium, no people, no graphic overlays"
- **NEGATIVE PROMPT** : liste globale + "no jump cut feel, no unrealistic room proportions"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-018.mp4`

## SHOT 019
- **TIMECODE** : 01:44–01:50
- **DURÉE** : 6s
- **RATIO** : 16:9
- **DESCRIPTION** : Poursuite du recul, la maison entière apparaît de l'extérieur ; apparitions très subtiles (toiture, murs, fenêtres, zones de déperdition).
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Extérieur de la maison, vue d'ensemble progressive.
- **CAMÉRA** : Plan large, suite du travelling.
- **MOUVEMENT** : Poursuite du dolly/drone arrière, jusqu'à l'extérieur.
- **LUMIÈRE** : Naturelle, neutre à légèrement chaude.
- **SON** : Ambiance extérieure qui s'installe.
- **VOIX OFF** : (silence, la question résonne)
- **TRANSITION** : Continuité directe vers SHOT 020.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic continuation of the same continuous pull-back shot, now revealing the house from outside, with very subtle emphasis (soft lighting accents, never graphic overlays) on the roof, walls, windows and potential heat-loss areas, photorealistic, documentary premium, no infographic elements, no people"
- **NEGATIVE PROMPT** : liste globale + "no flashy graphic overlays, no thermal-camera style false-color effect, no HUD, no unrealistic X-ray view"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-019.mp4`

## SHOT 020
- **TIMECODE** : 01:50–01:52
- **DURÉE** : 2s
- **RATIO** : 16:9
- **DESCRIPTION** : Plan final large, la maison entière visible, l'équipement de chauffage n'étant plus qu'un détail minuscule.
- **PERSONNAGE** : Aucun.
- **ACTION** : Aucune.
- **ENVIRONNEMENT** : Extérieur, vue d'ensemble complète.
- **CAMÉRA** : Plan large fixe (fin du mouvement).
- **MOUVEMENT** : Arrêt du travelling.
- **LUMIÈRE** : Naturelle.
- **SON** : Ambiance extérieure stable.
- **VOIX OFF** : (silence, transition vers la suite)
- **TRANSITION** : Coupe vers SHOT 021.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic wide static shot, the whole house visible from a distance, the heating equipment now an imperceptible detail within the frame, natural lighting, photorealistic, documentary premium, no people"
- **NEGATIVE PROMPT** : liste globale
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-020.mp4`

---

## SHOT 021
- **TIMECODE** : 01:52–02:00
- **DURÉE** : 8s
- **RATIO** : 16:9
- **DESCRIPTION** : Bureau, documents d'isolation, ordinateur portable.
- **PERSONNAGE** : Julien — **mains uniquement**.
- **ACTION** : Feuillette des documents techniques, tape sur un clavier.
- **ENVIRONNEMENT** : Bureau/table de travail.
- **CAMÉRA** : Plan rapproché.
- **MOUVEMENT** : Statique.
- **LUMIÈRE** : Chaude, lampe de bureau.
- **SON** : Pages, clavier discret.
- **VOIX OFF** : « Alors j'ai commencé à apprendre, seul, tout ce qui touche à l'isolation, aux déperditions, à la performance énergétique. Pas pour vendre plus. Pour comprendre mieux. »
- **TRANSITION** : Coupe.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic close-up shot, hands reviewing insulation technical papers next to a laptop with simple non-readable schematic shapes on screen, warm desk lamp lighting, documentary texture, no face"
- **NEGATIVE PROMPT** : liste globale + "no fake brand UI, no garbled screen text, no face"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-021.mp4`

## SHOT 022
- **TIMECODE** : 02:00–02:08
- **DURÉE** : 8s
- **RATIO** : 16:9 (9:16 : cadrage vertical resserré sur le van/la silhouette)
- **DESCRIPTION** : Extérieur, véhicule/matériel HAYEVA, golden hour.
- **PERSONNAGE** : Julien — **de dos ou ¾ non identifiable**.
- **ACTION** : Range son matériel près du véhicule de service.
- **ENVIRONNEMENT** : Extérieur, près du van HAYEVA.
- **CAMÉRA** : Plan large.
- **MOUVEMENT** : Léger travelling latéral.
- **LUMIÈRE** : Golden hour, tons chauds navy/orange HAYEVA.
- **SON** : Ambiance extérieure calme, portière de van.
- **VOIX OFF** : « C'est cette idée qui est devenue HAYEVA. »
- **TRANSITION** : Coupe.
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic wide shot, a technician (filmed from behind or at an angle keeping the face unidentifiable) near a service vehicle at golden hour, warm navy-and-orange toned lighting, authentic branding area left plain for logo compositing in post-production, documentary premium feel"
- **NEGATIVE PROMPT** : liste globale + "no AI-generated logo, no distorted vehicle branding, no identifiable face"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-022.mp4`

## SHOT 023
- **TIMECODE** : 02:08–02:16
- **DURÉE** : 8s
- **RATIO** : 16:9 (9:16 : plan resserré, silhouette centrée)
- **DESCRIPTION** : Plan de clôture, Julien de dos/silhouette face au soleil couchant.
- **PERSONNAGE** : Julien — **silhouette à contre-jour ou de dos, non identifiable**.
- **ACTION** : Reste immobile un instant, posture calme et confiante.
- **ENVIRONNEMENT** : Extérieur, golden hour.
- **CAMÉRA** : Plan moyen-large.
- **MOUVEMENT** : Très léger, quasi statique.
- **LUMIÈRE** : Contre-jour chaud, silhouette.
- **SON** : Ambiance extérieure calme, puis silence progressif.
- **VOIX OFF** : « Et aujourd'hui, quand je repense au parcours de mon grand-père, à celui de mon père, et maintenant au mien — HAYEVA, c'est aussi la continuité d'une histoire familiale que je n'avais jamais prévu d'écrire. Bienvenue chez HAYEVA. »
- **TRANSITION** : Fondu au noir vers l'écran final (généré séparément, voir `docs/mon-histoire-production-package.md` §13 — écran statique HTML/logo, pas un plan vidéo à générer).
- **PROMPT DE GÉNÉRATION VIDÉO** : "Realistic medium-wide shot, a technician's silhouette or back view against warm golden-hour backlight, calm confident stillness, documentary premium feel, face not identifiable due to backlighting/framing"
- **NEGATIVE PROMPT** : liste globale + "no identifiable facial features, no fake smile, no oversaturated golden-hour cliché"
- **FICHIER FINAL ATTENDU** : `images/story/shots/shot-023.mp4`

---

## Negative prompt commun (à ajouter à chaque plan, en plus du négatif spécifique)

```
deformed hands, extra fingers, missing fingers, impossible tools, unrealistic
plumbing, incoherent pipe connections, garbled generated text, invented
logos, unstable/morphing faces, artificial jittery motion, cartoon look,
video-game look, excessive saturation, plastic skin texture, oversharpened
edges, warped architecture, distorted vehicle branding, fantasy elements,
glossy CGI sheen, exaggerated facial expressions, fake smile, generic stock-
footage look, visible watermark, visible AI-generation artifacts, invented
identifiable face presented as a real person
```

## Continuité entre les plans

- Grade colorimétrique progressif : froid/bleuté (SHOT 001–004) → sépia
  doux (SHOT 007–011) → neutre atelier (SHOT 012–016) → transition
  introspective (SHOT 017–020) → chaud navy/orange HAYEVA (SHOT 021–023).
- Aucun raccord de mouvement brutal : chaque coupe listée "Coupe" peut être
  adoucie par un fondu de 4–6 images si le montage le rend nécessaire.
- La séquence "Le déclic" (SHOT 017–020) doit être conçue, si possible,
  comme un seul plan continu généré/tourné en une fois plutôt que 4 plans
  raccordés, pour préserver l'effet de révélation progressive.

## Photos utiles (facultatif, à fournir plus tard si souhaité)

| Personne | Utile pour améliorer | Statut |
|---|---|---|
| Julien (adulte, aujourd'hui) | SHOT 013–014, 016, 022–023 (passer d'un cadrage anonyme à un visage réel) | Non fournie — plans conçus pour fonctionner sans |
| Julien (adolescent) | SHOT 005–006 | Non fournie — plans conçus pour fonctionner sans |
| Père | Séquence "Trois générations" (SHOT 009) | Non fournie — traitement restera symbolique |
| Grand-père | Séquence "Trois générations" (SHOT 008) | Non fournie — traitement restera symbolique |

Aucune de ces photos n'est requise pour produire une version complète et
diffusable du film — leur ajout ultérieur ne ferait qu'améliorer certains
plans, jamais une condition bloquante.
