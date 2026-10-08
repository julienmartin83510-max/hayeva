# HAYEVA — Centre de communication SMS

État : **prêt, désactivé**. Aucun SMS n'est envoyé et aucun fournisseur n'est appelé
tant que vous n'avez pas fait les 4 étapes de la section 4.

## 1. Ce que fait le module

| SMS | Déclencheur | Exemple de texte (1 SMS) |
|---|---|---|
| Confirmation | Rendez-vous passé de « en attente » à « confirmé » | HAYEVA : votre RDV est confirmé le 10/03 à 10h00. Infos ou changement : 06 71 26 23 02 |
| Rappel 24 h avant | Tâche horaire, rendez-vous confirmés dans 23 à 25 h | HAYEVA : rappel, votre RDV est demain 10/03 à 10h00. Empêchement ? 06 71 26 23 02 |
| Déplacement | Date ou heure modifiée d'un rendez-vous confirmé | HAYEVA : votre RDV est déplacé au 10/03 à 14h00. Questions : 06 71 26 23 02 |
| Annulation | Rendez-vous confirmé annulé | HAYEVA : votre RDV du 10/03 à 14h00 est annulé. Pour le reprogrammer : 06 71 26 23 02 |
| En route | Bouton « En route » de la vue technicien | HAYEVA : votre technicien est en route, arrivée prévue vers 14h20. Contact : 06 71 26 23 02 |
| Manuel | Bouton « SMS » de la fiche client | Texte libre ou modèle (459 caractères max., soit 3 SMS) |

- **Une seule fois** par événement : un double clic, un double passage ou un
  rendez-vous déplacé deux fois à la même heure ne crée qu'un seul SMS.
- **Historique** : Administration → SMS clients (et dans chaque fiche client).
- **Désinscription** : le client décoche l'option dans son espace (Profil), ou
  vous cochez « Ce client ne souhaite pas recevoir de SMS » dans sa fiche. Elle
  est respectée par tous les envois, automatiques et manuels, et conservée
  comme trace même si elle est annulée ensuite.
- **Heures calmes** : aucun envoi automatique entre 21 h et 8 h (le message part
  à 8 h). « En route » et les messages manuels ne sont pas retardés.
- **Mode test** (activé par défaut) : les SMS partent uniquement vers votre
  numéro de test, préfixés « [TEST] », jamais vers les clients.

## 2. Comparatif des fournisseurs (France, octobre 2026)

Tarifs indicatifs relevés sur les pages publiques et des comparatifs : à
vérifier dans votre espace client avant tout achat.

| Fournisseur | Prix indicatif / SMS France | Facturation | Expéditeur « HAYEVA » | Intégré au module |
|---|---|---|---|---|
| **Brevo** (recommandé) | ≈ 0,045 à 0,08 € | Crédits sans abonnement, sans expiration | Oui (11 caractères max.) | **Oui** |
| Twilio | ≈ 0,08 $ (≈ 0,074 €) par segment | À l'usage, compte payant obligatoire | Oui, sans enregistrement préalable en France | **Oui** |
| OVHcloud SMS | ≈ 0,054 à 0,06 € HT | Packs prépayés | Oui, après validation | Non (API signée plus complexe ; possible plus tard) |
| SMSFactor | ≈ 0,04 à 0,066 € HT | Packs prépayés | Oui | Non |
| Octopush | ≈ 0,039 € HT (Premium) | Packs | Oui (Premium) | Non |

Pourquoi Brevo : entreprise française, prix bas, pas d'abonnement, crédits
qui n'expirent pas, clé d'API simple, et vous pourriez y regrouper plus tard vos
e-mails marketing. Le volume prévisible de HAYEVA (quelques centaines de SMS
par an) coûte quelques dizaines d'euros par an.

## 3. Utiliser votre numéro 06 71 26 23 02 comme expéditeur ?

**Non, pas pour des SMS automatiques.** Depuis le 1er janvier 2023, l'ARCEP
interdit d'utiliser les numéros 06 et 07 pour des systèmes automatisés
d'envoi, et les opérateurs bloquent ce trafic. Les solutions légales :

- **Expéditeur alphanumérique « HAYEVA »** (retenu) : votre marque s'affiche,
  mais le client ne peut pas répondre au SMS. C'est pourquoi chaque message
  contient votre numéro 06 71 26 23 02.
- Numéro virtuel ou numéro court du fournisseur (réponses possibles,
  moins identifiable, souvent payant au mois) : non retenu.

Votre 06 reste votre ligne pour les échanges individuels depuis votre
téléphone.

## 4. Activation — à faire par vous, dans cet ordre

1. **Ouvrir un compte Brevo** (brevo.com), acheter un petit pack de crédits SMS
   (100 suffisent pour tester) et demander, si Brevo le propose, la
   validation de l'expéditeur « HAYEVA ».
2. **Créer une clé d'API** dans Brevo (SMTP & API → Clés API).
3. **L'enregistrer dans Supabase** : Edge Functions → Secrets → ajouter
   `BREVO_API_KEY`. Ne la collez jamais ailleurs, ni dans cette conversation.
   Le secret `SMS_PROVIDER` doit rester **vide** (sinon doublon « en route »).
4. **Administration → SMS clients** :
   - Fournisseur : Brevo — la ligne « Clé Brevo : configurée » doit apparaître ;
   - Mode test : coché, avec votre numéro de mobile ;
   - cocher « Activer l'envoi de SMS » → Enregistrer (une confirmation est demandée) ;
   - envoyer un SMS manuel depuis une fiche client : vous devez le recevoir
     préfixé « [TEST] » ;
   - quand tout est correct, décocher le mode test → Enregistrer.

Pour couper le service à tout moment : décocher « Activer l'envoi de SMS ».

## 5. Cadre légal retenu

- SMS **transactionnels uniquement** (rendez-vous demandés par le client) :
  pas de prospection, donc pas de consentement marketing préalable requis ;
  le client peut toutefois refuser à tout moment (espace client ou demande).
- Aucune campagne promotionnelle n'est prévue dans ce module. Une campagne
  marketing exigerait un consentement explicite et la mention « STOP ».
- Numéros conservés au format international, jamais affichés en entier dans
  les listes (masqués : 06 12 •• •• 78).
