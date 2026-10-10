# HAYEVA BLACK SIGNATURE — identité visuelle

Bleu nuit, ivoire et cuivre, sur toute la plateforme : site public, réservation,
espaces particulier et professionnel, administration, assistant, fenêtres et PWA.

- CSS : bloc `<style id="hv-black-signature">` de `index.html` (dernier bloc de
  styles). Il s'appuie sur les jetons existants (`--hv-*`, `--adm-*`, `--pro-*`,
  `--sig-*`) sans rien renommer : aucun identifiant, aucune classe lue par le
  JavaScript, aucune donnée ni règle métier ne change.
- JS : `assets/hv-fx.js` ajoute seulement la classe `is-zero` sur les cartes
  d'indicateurs dont la valeur réelle (écrite par l'application) vaut 0.
- Mouvement : voir `motion-signature.md` (inchangé, mêmes jetons).

## Activation par interface

Le script en tête de page pose `html[data-bs]` : `public particulier pro admin`
par défaut. Chaque interface peut être activée ou retirée sans toucher au code :

| Adresse | Effet (mémorisé sur l'appareil) |
|---|---|
| `?bs=all` | les quatre interfaces |
| `?bs=public,admin` | seulement les interfaces citées |
| `?bs=off` | ancien rendu partout |

## Logo officiel

1. Toujours le fichier d'origine (`images/brand/hayeva-logo*.png`), jamais
   redessiné, recoloré, inversé ni déformé.
2. Sur ivoire : affiché tel quel (en-tête du site, sceau de réservation).
3. Sur bleu nuit : halo lumineux validé sur le portail
   (`drop-shadow` blanc, sans plaque ni fond). Barre latérale admin et pro,
   accueil du site.
4. L'ancienne version blanche inversée de la barre latérale admin/pro
   (`filter: brightness(0) invert(1)`) n'est plus utilisée.

## Jetons

| Jeton | Valeur | Usage | Contraste |
|---|---|---|---|
| `--bs-bg` | `#101A2B` | fond principal sombre | — |
| `--bs-bg-2` | `#0C1422` | barres, pied de page, barre latérale | — |
| `--bs-surface` | `#1B2B41` | carte | — |
| `--bs-surface-2` | `#243247` | surface secondaire, champ | — |
| `--bs-elevated` | `#2A3B54` | survol, fiche, élément sélectionné | — |
| `--bs-border` | `#34465E` | séparateur décoratif uniquement | 1,8:1 |
| `--bs-field-border` | `#7D90A8` | contour de champ | 4,4:1 sur carte |
| `--bs-text` | `#FFFFFF` | texte sur sombre | 17,4:1 |
| `--bs-text-2` | `#B7C4D4` | texte secondaire | 9,9:1 / 8,1:1 sur carte |
| `--bs-text-3` | `#8FA1B8` | métadonnées, valeurs à zéro | 5,4:1 sur carte |
| `--bs-accent` | `#D7A16B` | cuivre : action principale, accents | 7,6:1 / 6,3:1 sur carte |
| `--bs-accent-hover` | `#E3B47F` | survol cuivre | — |
| `--bs-on-accent` | `#101A2B` | texte sur cuivre | 7,6:1 |
| `--bs-accent-ink` | `#8A5A2B` | cuivre foncé : titres et liens sur ivoire | 5,4:1 ivoire / 5,9:1 blanc / 4,9:1 ivoire profond |
| `--bs-flame` | `#E85A12` | orange officiel du logo, couleur secondaire | — |
| `--bs-ivory` | `#F7F5F1` | fond clair premium | — |
| `--bs-ivory-2` | `#EFEBE4` | section claire alternée, puce | — |
| `--bs-ink` | `#172234` | texte sur ivoire | 14,7:1 |
| `--bs-ink-2` | `#4A5568` | texte secondaire sur ivoire | 6,9:1 |
| `--bs-success` / `-ink` | `#5FC795` / `#17643F` | succès sur sombre / sur clair | 6,9:1 sur carte / 7,2:1 sur blanc |
| `--bs-warning` / `-ink` | `#F2B84B` / `#7A4E0C` | attention | 8,0:1 sur carte / 7,2:1 sur blanc |
| `--bs-danger` / `-ink` | `#F28B7B` / `#9B2C1C` | erreur | 6,0:1 sur carte / 7,6:1 sur blanc |
| `--bs-focus` | `#D7A16B` (sombre), `#8A5A2B` (clair) | anneau de focus clavier | ≥ 3:1 |
| `--bs-disabled-op` | `.45` | élément désactivé | — |

Règles :
- Bouton principal : cuivre `#D7A16B`, texte bleu nuit. Jamais de texte blanc
  sur cuivre (2,2:1).
- Le cuivre clair n'est jamais un texte sur ivoire (2,1:1) : cuivre foncé.
- Tout fond plein clair (cuivre, vert, rouge) dans les espaces sombres porte un
  texte bleu nuit.
- Pas de bordure visible sur les cartes : la différence de surface suffit.
- Statuts : fond translucide de la couleur + texte de la couleur claire.

## Composition par interface

| Interface | Fond | Points clés |
|---|---|---|
| Site public | ivoire et bleu nuit en alternance | en-tête ivoire avec logo ; accueil bleu nuit sur la photo du portail ; Grand jeu, Chauffage, Réalisations, Tarifs, Pourquoi, Contact et pied en bleu nuit ; Besoin, Climatisation, Plomberie, Comment ça marche, Métiers, Réservation, Zone, FAQ en ivoire ; packs sombres dans Tarifs ; univers métier neutralisés (même identité quel que soit l'univers) |
| Particulier | bleu nuit | prochain rendez-vous en carte élevée, « Prendre rendez-vous » cuivre, familles en tuiles, statuts lisibles, assistant sombre |
| Professionnel | bleu nuit, dense | barre latérale bleu nuit profond, indicateurs à zéro atténués, packs « Check » sombres |
| Administration | bleu nuit | « Bonjour THE BIG BOSS », carte « À traiter maintenant » en tête (pulsation cuivre), interventions du jour, prochain rendez-vous, actions rapides, puis chiffres ; zéros atténués ; aucun cercle pastel |
| Réservation | ivoire | sceau de validation (voir ci-dessous), sélection date/heure cuivre |

## Confirmation « HAYEVA Signature »

Animation plein écran sur bleu nuit, déclenchée par le tunnel de réservation
(`window.hvSeal` dans `assets/hv-fx.js`, trois appels gardés dans `index.html`).
Purement visuelle : aucune donnée ni décision de réservation ne passe par elle.

| Temps | Étape |
|---|---|
| 0 ms | appui sur « Confirmer » : le bouton se contracte (0,92) |
| 0–600 ms | voile bleu nuit, médaillon, cercle cuivré tracé |
| 300–900 ms | logo officiel en profondeur (légère inclinaison qui se redresse) |
| dès 500 ms | couronne lumineuse qui parcourt le cercle, tant que le serveur n'a pas répondu |
| réponse positive du serveur (au plus tôt 900 ms) | coche verte dessinée, texte selon le statut réel |
| + 650 ms | fondu de sortie, l'étape 4 apparaît (total ≈ 1,6 à 1,9 s) |

- Texte : « Rendez-vous confirmé » seulement si le serveur renvoie le statut
  `CONFIRMED` ; sinon « Demande envoyée ». Aujourd'hui `create_booking` et
  `create_guest_or_quote_booking` enregistrent `PENDING` et ne renvoient pas
  de statut : le texte est donc « Demande envoyée ».
- Échec : le voile disparaît sans coche, le message d'erreur existant
  s'affiche, le bouton redevient actif.
- Vérification anti-robot qui demande une action : le voile s'efface aussitôt.
- Garde-fou : retrait automatique après 20 s sans réponse.
- Logo : `images/brand/hayeva-logo-sm.png` / `hayeva-logo.png` (PNG
  transparents officiels, `srcset` pour les écrans haute densité). Aucun fond
  blanc : centre du médaillon éclairé (`#51698C` → `#101A2B`) et halo
  lumineux qui suit le contour des lettres.
- Réduire les animations : états finaux directs, sans mouvement.
- Étape 4 : même médaillon en version fixe, pastille verte de validation.
