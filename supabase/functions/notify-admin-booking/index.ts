// Supabase Edge Function — notifie l'administrateur HAYEVA par e-mail
// immédiatement après la création d'une nouvelle réservation.
//
// DÉCLENCHEMENT : cette fonction n'est JAMAIS appelée depuis le frontend, ni
// depuis create_booking(). Elle est appelée par un trigger Postgres AFTER
// INSERT ON bookings (voir supabase/migrations/0005_booking_notify_trigger.sql),
// qui utilise pg_net pour faire un appel HTTP asynchrone — pas de "Database
// Webhook" via le Dashboard (le schéma technique supabase_functions dont
// cette fonctionnalité dépend n'existe pas sur ce projet). C'est le choix
// INSERT-only du trigger qui garantit structurellement une seule
// notification par réservation : un rafraîchissement de page ne réinsère
// rien, et un changement de statut (PENDING -> CONFIRMED) est un UPDATE,
// jamais écouté par ce trigger. Aucune logique applicative de "déjà
// notifié" à maintenir.
//
// SÉCURITÉ : aucune clé n'est jamais exposée au frontend. SUPABASE_URL et
// SUPABASE_SERVICE_ROLE_KEY sont injectées automatiquement par Supabase pour
// toute Edge Function (rien à configurer). RESEND_API_KEY,
// ADMIN_NOTIFICATION_EMAIL et WEBHOOK_SECRET doivent être définies comme
// secrets de la fonction (`supabase secrets set ...`) — jamais commitées
// dans ce fichier. WEBHOOK_SECRET est un jeton partagé avec le trigger SQL
// (passé dans l'en-tête Authorization) : sans lui, n'importe qui connaissant
// l'URL de cette fonction pourrait déclencher un faux e-mail de
// notification — vérifié ci-dessous avant tout traitement.
//
// FIABILITÉ : la réservation est déjà enregistrée en base AVANT que ce
// webhook ne se déclenche (il réagit à un INSERT déjà commité). Un échec
// d'envoi d'e-mail ici (Resend down, mauvaise clé, etc.) ne peut donc
// jamais annuler ni empêcher la réservation du client — elle est déjà
// sauvegardée. On répond 200 même en cas d'échec d'envoi pour éviter des
// tentatives de re-livraison du webhook, et on journalise l'erreur (console
// Supabase > Edge Functions > Logs) pour pouvoir la diagnostiquer.
//
// NOTIFICATION PUSH (Web Push réelle, PWA/iPhone/Android) : ajoutée comme
// second canal, juste après l'appel Resend ci-dessous, en réutilisant les
// mêmes infos de réservation déjà résolues (contactName, categoryLabel,
// prestationLabel, date, heure, adresse, prix). Lit admin_push_subscriptions
// (service_role, bypass RLS comme le reste de cette fonction) et envoie via
// web-push (VAPID) — jamais bloquant : toute erreur y reste locale à son
// propre bloc try/catch, sans jamais affecter l'e-mail déjà envoyé ni la
// réponse 200 de cette fonction. VAPID_PRIVATE_KEY n'est lue qu'ici, jamais
// exposée au frontend (qui ne connaît que VAPID_PUBLIC_KEY, servie par
// get-public-config).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';
import { ADMIN_BOOKING_EMAIL, bigButtonHtml, sendEmailOnce } from '../_shared/mail.ts';
import { escapeHtml, fmtDate, fmtDuration, fmtTime, resolveBookingContact, rowHtml } from '../_shared/booking-contact.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET');
const ADMIN_PANEL_URL = Deno.env.get('ADMIN_PANEL_URL') || 'https://hayeva.fr/#espacePro';
const SITE_BASE_URL = Deno.env.get('SITE_BASE_URL') || 'https://hayeva.fr';
// Page de validation (site Netlify) : le jeton est passé dans le fragment
// (#...), jamais envoyé à un serveur ni dans un en-tête Referer.
const ACTION_PAGE_URL = `${SITE_BASE_URL}/rdv-action.html`;
// Liens d'action personnels : 7 jours (et jamais après la date du RDV).
const TOKEN_TTL_DAYS = 7;

function randomToken(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d)).map((x) => x.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req: Request) => {
  try {
    // Vérifie le jeton partagé envoyé par le trigger SQL (voir
    // 0005_booking_notify_trigger.sql) avant tout traitement. Rejette
    // silencieusement (401) tout appel qui ne le porte pas — empêche un
    // tiers connaissant l'URL de cette fonction de déclencher de faux
    // e-mails de notification.
    if (!WEBHOOK_SECRET || req.headers.get('authorization') !== `Bearer ${WEBHOOK_SECRET}`) {
      return new Response('unauthorized', { status: 401 });
    }

    const payload = await req.json();

    // Payload envoyé par le trigger SQL : { type, table, record }
    if (payload.type !== 'INSERT' || payload.table !== 'bookings') {
      return new Response('ignored', { status: 200 });
    }
    const booking = payload.record;

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // ---- Service / prestation ----
    let serviceName = 'Intervention';
    if (booking.service_id) {
      const { data: svc } = await supabase
        .from('services')
        .select('name')
        .eq('id', booking.service_id)
        .maybeSingle();
      if (svc) serviceName = svc.name;
    }
    let packName: string | null = null;
    if (booking.service_pack_id) {
      const { data: pack } = await supabase
        .from('service_packs')
        .select('name')
        .eq('id', booking.service_pack_id)
        .maybeSingle();
      if (pack) packName = pack.name;
    }

    // ---- Contact (invité / particulier connecté / professionnel) ----
    const contact = await resolveBookingContact(supabase, booking);
    const contactName = contact.name;
    const contactAddress = contact.address;

    const prestationLabel = packName ? `${serviceName} — ${packName}` : serviceName;
    const subject = '🔔 Nouvelle demande de rendez-vous HAYEVA';
    const dedupeKey = `admin_new:${booking.id}`;

    // Anti-doublon : un webhook rejoué ne régénère ni jetons ni e-mail.
    const { data: already } = await supabase
      .from('booking_emails').select('id').eq('dedupe_key', dedupeKey).eq('status', 'sent').maybeSingle();

    if (!already) {
      // Boutons ACCEPTER / DÉPLACER / REFUSER : uniquement pour une demande
      // encore en attente. Jetons aléatoires (256 bits), seul leur hash est
      // stocké. Le jeton est dans le fragment (#) de l'URL : jamais transmis
      // à un serveur ; l'ouverture du lien (ou un scanner anti-spam) ne fait
      // qu'AFFICHER la demande, l'action n'est exécutée qu'après un appui.
      let actionsHtml = '';
      if (booking.status === 'PENDING') {
        const confirmToken = randomToken();
        const refuseToken = randomToken();
        const moveToken = randomToken();
        const expiresAt = new Date(Date.now() + TOKEN_TTL_DAYS * 86400000).toISOString();
        const { error: tokErr } = await supabase.from('booking_action_tokens').insert([
          { booking_id: booking.id, action: 'confirm', token_hash: await sha256Hex(confirmToken), expires_at: expiresAt },
          { booking_id: booking.id, action: 'refuse', token_hash: await sha256Hex(refuseToken), expires_at: expiresAt },
        ]);
        const { error: moveErr } = tokErr ? { error: null } : await supabase.from('booking_move_tokens').insert(
          { booking_id: booking.id, token_hash: await sha256Hex(moveToken), expires_at: expiresAt },
        );
        if (tokErr) {
          console.error('notify-admin-booking: création des jetons impossible', tokErr.message);
        } else {
          if (moveErr) console.error('notify-admin-booking: jeton DÉPLACER impossible', moveErr.message);
          actionsHtml = `
            <div style="margin:26px 0 6px;">
              ${bigButtonHtml(`${ACTION_PAGE_URL}#a=confirm&t=${confirmToken}`, '✓ ACCEPTER', '#2F9E5B')}
              ${moveErr ? '' : bigButtonHtml(`${ACTION_PAGE_URL}#a=move&t=${moveToken}`, '↔ DÉPLACER', '#1AA6EE')}
              ${bigButtonHtml(`${ACTION_PAGE_URL}#a=refuse&t=${refuseToken}`, '✕ REFUSER', '#C8423B')}
            </div>
            <p style="margin:0 0 4px;font-size:12px;color:#8A97A3;text-align:center;">Liens personnels à usage unique, valables ${TOKEN_TTL_DAYS} jours — ne pas transférer.</p>`;
        }
      }
      const priceLabelEmail = booking.total_cents != null && Number(booking.total_cents) > 0
        ? `${(Number(booking.total_cents) / 100).toFixed(2).replace('.', ',')} €`
        : 'Sur devis';

      const html = renderEmailShell(`
        <h2 style="margin:0 0 16px; font-size:20px; color:#101B24; letter-spacing:.02em;">NOUVELLE DEMANDE DE RENDEZ-VOUS</h2>
        ${statusBadgeHtml('🟠 En attente de votre validation', 'received')}
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
          ${rowHtml('Client', escapeHtml(contactName), true)}
          ${rowHtml('Téléphone', contact.phone ? `<a href="tel:${escapeHtml(contact.phone.replace(/\s+/g, ''))}" style="color:#1AA6EE;">${escapeHtml(contact.phone)}</a>` : '')}
          ${rowHtml('E-mail', escapeHtml(contact.email))}
          ${rowHtml('Type de client', contact.kind)}
          ${rowHtml('Prestation', escapeHtml(prestationLabel))}
          ${rowHtml('Date', fmtDate(booking.date), true)}
          ${rowHtml('Heure', fmtTime(booking.start_time), true)}
          ${rowHtml('Durée estimée', fmtDuration(booking.service_duration_minutes))}
          ${rowHtml('Prix estimatif', priceLabelEmail, true)}
          ${rowHtml('Adresse', escapeHtml(contactAddress))}
          ${rowHtml('Informations / commentaire', booking.notes ? escapeHtml(booking.notes) : '')}
          ${rowHtml('Référence', escapeHtml(booking.reference || ''))}
        </table>
        ${actionsHtml}
        <p style="margin:18px 0 0;text-align:center;">
          <a href="${ADMIN_PANEL_URL}" style="color:#1AA6EE;font-size:13px;">Ouvrir l'espace administration</a>
        </p>
      `, escapeHtml(booking.reference || ''));

      await sendEmailOnce(supabase, {
        dedupeKey, bookingId: booking.id, emailType: 'admin_new', to: ADMIN_BOOKING_EMAIL, subject, html,
      });
    }

    // ---- Notification push (Web Push / PWA, Espace Administration) ----
    // Best-effort, jamais bloquant : un échec ici (abonnement expiré, clé
    // VAPID absente, service push indisponible...) ne doit jamais faire
    // échouer cette fonction ni, a fortiori, la réservation déjà enregistrée
    // en base avant que ce webhook ne se déclenche.
    try {
      const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY');
      const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY');
      const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') || 'mailto:contact@hayeva.fr';

      if (!already && VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY) {
        const { data: subs } = await supabase
          .from('admin_push_subscriptions')
          .select('id, endpoint, p256dh, auth_key')
          .eq('enabled', true);

        if (subs && subs.length) {
          webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

          const priceLabel = `${((booking.total_cents || 0) / 100).toFixed(2).replace('.', ',')} €`;
          const pushBody = [
            `${prestationLabel} – ${priceLabel}`,
            contactName,
            `${fmtDate(booking.date)} à ${(booking.start_time || '').slice(0, 5)}`,
            contactAddress || null,
          ].filter(Boolean).join('\n');

          // Le paramètre ?booking=<id> doit précéder le fragment #espacePro
          // pour rester lisible par location.search côté navigateur (tout ce
          // qui suit un # fait partie du fragment, jamais de la query string
          // — ADMIN_PANEL_URL contient déjà "#espacePro" par défaut, d'où
          // cette reconstruction plutôt qu'une simple concaténation).
          const hashIdx = ADMIN_PANEL_URL.indexOf('#');
          const panelBase = hashIdx === -1 ? ADMIN_PANEL_URL : ADMIN_PANEL_URL.slice(0, hashIdx);
          const panelHash = hashIdx === -1 ? 'espacePro' : ADMIN_PANEL_URL.slice(hashIdx + 1);
          const pushUrl = `${panelBase}?booking=${booking.id}#${panelHash}`;

          const pushPayload = JSON.stringify({
            title: '🔔 Nouvelle demande de rendez-vous HAYEVA',
            body: pushBody,
            bookingId: booking.id,
            url: pushUrl,
          });

          await Promise.all(subs.map(async (sub: { id: string; endpoint: string; p256dh: string; auth_key: string }) => {
            try {
              await webpush.sendNotification(
                { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth_key } },
                pushPayload,
              );
            } catch (pushErr: unknown) {
              const statusCode = (pushErr as { statusCode?: number })?.statusCode;
              console.error('notify-admin-booking: échec envoi push', sub.id, statusCode);
              // Abonnement expiré/révoqué (410 Gone / 404) : désactivé pour ne
              // plus retenter indéfiniment un envoi voué à échouer à chaque
              // future réservation.
              if (statusCode === 404 || statusCode === 410) {
                await supabase.from('admin_push_subscriptions').update({ enabled: false }).eq('id', sub.id);
              }
            }
          }));
        }
      }
    } catch (pushBlockErr) {
      console.error('notify-admin-booking: bloc notification push — erreur inattendue', pushBlockErr);
    }

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('notify-admin-booking: erreur inattendue', err);
    // Toujours 200 : un échec ici ne doit jamais remonter comme une erreur
    // de réservation côté client (le webhook se déclenche après coup, la
    // réservation est déjà enregistrée).
    return new Response('error handled', { status: 200 });
  }
});
