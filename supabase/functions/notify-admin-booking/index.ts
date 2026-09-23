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
// FUTUR : notification push HAYEVA (iPhone/PWA). Ce fichier est structuré
// pour que l'ajout futur d'un second canal soit un ajout, pas une reprise :
// une fois les infos de réservation résolues (contactName, categoryLabel,
// prestationLabel, date, heure...), il suffira d'ajouter un second bloc
// d'envoi (ex. Web Push / APNs via un service tiers) juste après l'appel
// Resend ci-dessous, avec ses propres secrets. Rien n'est mis en place
// maintenant : ça demande de choisir un service tiers (Web Push nécessite
// des clés VAPID, APNs un certificat Apple Developer), une décision à
// prendre explicitement avant d'y toucher.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

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

    if (!RESEND_API_KEY || !ADMIN_EMAIL) {
      console.error('notify-admin-booking: RESEND_API_KEY ou ADMIN_NOTIFICATION_EMAIL manquant — notification ignorée, réservation non affectée.');
      return new Response('missing config', { status: 200 });
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

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('notify-admin-booking: erreur inattendue', err);
    // Toujours 200 : un échec ici ne doit jamais remonter comme une erreur
    // de réservation côté client (le webhook se déclenche après coup, la
    // réservation est déjà enregistrée).
    return new Response('error handled', { status: 200 });
  }
});
