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

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const ADMIN_EMAIL = Deno.env.get('ADMIN_NOTIFICATION_EMAIL');
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const ADMIN_PANEL_URL = Deno.env.get('ADMIN_PANEL_URL') || 'https://hayeva.netlify.app/#espacePro';

const CATEGORY_LABELS: Record<string, string> = {
  climatisation: 'Climatisation',
  chauffage: 'Chauffage',
  plomberie: 'Plomberie',
  multi: 'Multi-services',
  pro: 'Professionnel',
};

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string
  ));
}

function fmtDate(d: string): string {
  const [y, m, day] = d.slice(0, 10).split('-');
  return `${day}/${m}/${y}`;
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

    // Ni l'e-mail ni le push ne sont plus une condition d'arrêt l'un pour
    // l'autre (avant : un RESEND_API_KEY/ADMIN_NOTIFICATION_EMAIL manquant
    // coupait TOUTE la fonction avant même d'atteindre le bloc push
    // ci-dessous) — chaque canal vérifie désormais sa propre config et
    // s'ignore silencieusement si elle manque, sans empêcher l'autre.
    if (!RESEND_API_KEY || !ADMIN_EMAIL) {
      console.error('notify-admin-booking: RESEND_API_KEY ou ADMIN_NOTIFICATION_EMAIL manquant — e-mail admin ignoré (le push, ci-dessous, reste tenté).');
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // ---- Service / prestation ----
    let serviceName = 'Intervention';
    let categoryLabel = 'HAYEVA';
    if (booking.service_id) {
      const { data: svc } = await supabase
        .from('services')
        .select('name, category')
        .eq('id', booking.service_id)
        .maybeSingle();
      if (svc) {
        serviceName = svc.name;
        categoryLabel = CATEGORY_LABELS[svc.category] || svc.category;
      }
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
    let contactName = 'Client';
    let contactPhone = '';
    let contactEmail = '';
    let contactAddress = '';

    if (booking.guest_name) {
      contactName = booking.guest_name;
      contactPhone = booking.guest_phone || '';
      contactEmail = booking.guest_email || '';
      contactAddress = booking.guest_address || '';
    } else if (booking.customer_user_id) {
      const [{ data: cp }, { data: prof }] = await Promise.all([
        supabase.from('customer_profiles').select('first_name,last_name,phone').eq('user_id', booking.customer_user_id).maybeSingle(),
        supabase.from('profiles').select('email').eq('user_id', booking.customer_user_id).maybeSingle(),
      ]);
      if (cp) {
        contactName = [cp.first_name, cp.last_name].filter(Boolean).join(' ') || contactName;
        contactPhone = cp.phone || '';
      }
      if (prof) contactEmail = prof.email || '';
      if (booking.customer_address_id) {
        const { data: addr } = await supabase
          .from('customer_addresses')
          .select('address,postal_code,city')
          .eq('id', booking.customer_address_id)
          .maybeSingle();
        if (addr) contactAddress = [addr.address, addr.postal_code, addr.city].filter(Boolean).join(', ');
      }
    } else if (booking.professional_account_id) {
      const { data: pa } = await supabase
        .from('professional_accounts')
        .select('legal_name,phone,address_line1,address_line2,postal_code,city')
        .eq('id', booking.professional_account_id)
        .maybeSingle();
      if (pa) {
        contactName = pa.legal_name || contactName;
        contactPhone = pa.phone || '';
        contactAddress = [pa.address_line1, pa.address_line2, pa.postal_code, pa.city].filter(Boolean).join(', ');
      }
    }

    const prestationLabel = packName ? `${serviceName} — ${packName}` : serviceName;
    const subject = `🔔 Nouveau rendez-vous HAYEVA – ${categoryLabel}`;

    const html = `
      <div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;color:#16222c;">
        <h2 style="color:#101B24;margin-bottom:18px;">Nouveau rendez-vous HAYEVA</h2>
        <table style="width:100%;border-collapse:collapse;font-size:14px;">
          <tr><td style="padding:6px 0;color:#5B6B78;width:120px;">Client</td><td style="padding:6px 0;font-weight:600;">${escapeHtml(contactName)}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Téléphone</td><td style="padding:6px 0;">${contactPhone ? escapeHtml(contactPhone) : '—'}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">E-mail</td><td style="padding:6px 0;">${contactEmail ? escapeHtml(contactEmail) : '—'}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Type</td><td style="padding:6px 0;">${escapeHtml(categoryLabel)}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Prestation</td><td style="padding:6px 0;">${escapeHtml(prestationLabel)}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Date</td><td style="padding:6px 0;">${fmtDate(booking.date)}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Heure</td><td style="padding:6px 0;">${(booking.start_time || '').slice(0, 5)}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Adresse</td><td style="padding:6px 0;">${contactAddress ? escapeHtml(contactAddress) : '—'}</td></tr>
          ${booking.notes ? `<tr><td style="padding:6px 0;color:#5B6B78;vertical-align:top;">Commentaire</td><td style="padding:6px 0;">${escapeHtml(booking.notes)}</td></tr>` : ''}
        </table>
        <p style="margin-top:26px;">
          <a href="${ADMIN_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:600;font-size:14px;">Voir le rendez-vous</a>
        </p>
        <p style="margin-top:20px;font-size:12px;color:#8A97A3;">Réf. ${escapeHtml(booking.reference || '')}</p>
      </div>
    `;

    if (RESEND_API_KEY && ADMIN_EMAIL) {
      const emailRes = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${RESEND_API_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          from: FROM_EMAIL,
          to: [ADMIN_EMAIL],
          subject,
          html,
        }),
      });

      if (!emailRes.ok) {
        console.error('notify-admin-booking: échec envoi Resend', emailRes.status, await emailRes.text());
      }
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

      if (VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY) {
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
            title: '🔔 Nouvelle réservation HAYEVA',
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
