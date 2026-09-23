# notify-admin-booking

E-mail à l'administrateur HAYEVA à chaque nouvelle réservation. Je n'ai pas
accès à ton compte Supabase/Resend depuis cet environnement — ces étapes
sont à faire une fois, toi-même.

## 1. Créer un compte Resend (service d'envoi d'e-mail)

- https://resend.com → créer un compte gratuit (100 e-mails/jour, largement
  suffisant).
- Dans le dashboard Resend, récupère ta clé API (Settings > API Keys).
- Optionnel mais recommandé : vérifie ton propre nom de domaine (ex.
  `hayeva.fr`) dans Resend (Domains) pour pouvoir envoyer depuis
  `notifications@hayeva.fr` plutôt que l'adresse de test
  `onboarding@resend.dev` (celle-ci ne peut envoyer que vers l'adresse avec
  laquelle tu t'es inscrit sur Resend — suffisant pour tester, pas pour la
  prod).

## 2. Installer la CLI Supabase et déployer la fonction

```bash
brew install supabase/tap/supabase
cd ~/Desktop/hayeva-repo
supabase login
supabase link --project-ref TON_PROJECT_REF   # visible dans Project Settings > General
supabase functions deploy notify-admin-booking
```

## 3. Configurer les secrets de la fonction

```bash
supabase secrets set RESEND_API_KEY=re_xxxxxxxxxxxx
supabase secrets set ADMIN_NOTIFICATION_EMAIL=ton-adresse@exemple.fr
# Optionnel :
supabase secrets set RESEND_FROM_EMAIL="HAYEVA <notifications@hayeva.fr>"
supabase secrets set ADMIN_PANEL_URL=https://hayeva.netlify.app/#espacePro
```

`SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY` sont injectées automatiquement
par Supabase pour toute Edge Function — rien à faire pour celles-ci.

## 4. Créer le Database Webhook (déclenche la fonction)

Dashboard Supabase > **Database > Webhooks** > **Create a new hook** :

- Name : `notify-admin-booking`
- Table : `bookings`
- Events : **Insert uniquement** (décoche Update et Delete — c'est ce qui
  garantit qu'un changement de statut ne redéclenche jamais l'e-mail)
- Type : **Supabase Edge Functions**
- Edge Function : `notify-admin-booking`
- HTTP Method : POST

Supabase signe automatiquement l'appel avec un jeton valide de ton projet —
rien d'autre à configurer côté sécurité.

## 5. Tester

Fais une vraie réservation sur le site (via le formulaire, en tant que
particulier connecté). Vérifie :

1. La réservation apparaît bien dans l'Espace Professionnel > Administration
   > Tous les rendez-vous (comme avant, rien n'a changé côté réservation).
2. Un seul e-mail arrive à `ADMIN_NOTIFICATION_EMAIL`, avec l'objet
   `🔔 Nouveau rendez-vous HAYEVA – <Type>` et le bouton "Voir le
   rendez-vous" qui ouvre directement l'Espace Professionnel (pas la page
   d'accueil).
3. Change le statut de cette réservation (PENDING → CONFIRMED) dans le
   panneau admin : **aucun** nouvel e-mail ne doit arriver.

En cas de problème : Dashboard Supabase > Edge Functions >
`notify-admin-booking` > Logs, pour voir l'erreur exacte (clé Resend
invalide, secret manquant, etc.).
