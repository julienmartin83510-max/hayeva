// Supabase Edge Function — e-mail au CLIENT (pas à l'admin, voir
// notify-admin-booking pour ça) juste après la création d'une réservation :
// "Votre demande de rendez-vous HAYEVA a bien été reçue".
//
// DÉCLENCHEMENT : trigger Postgres AFTER INSERT ON bookings (voir
// supabase/migrations/0007_travel_and_emails.sql, trg_notify_customer_new_booking),
// même mécanisme pg_net + WEBHOOK_SECRET que notify-admin-booking (Dashboard
// Webhooks indisponible sur ce projet). Les deux triggers AFTER INSERT
// (admin + client) sont indépendants et se déclenchent tous les deux.
//
// SOURCE DE VÉRITÉ : Supabase reste l'unique source de vérité pour la
// réservation elle-même — cette fonction se contente de LIRE la ligne déjà
// insérée (booking.service_price_cents/travel_fee_cents/total_cents,
// snapshotés au moment de la réservation) et d'envoyer un e-mail informatif.
// Un échec d'envoi ici ne modifie jamais la réservation : on journalise le
// résultat dans booking_emails (pending -> sent/failed) pour que
// l'administrateur puisse voir l'échec et renvoyer l'e-mail (voir
// resend-booking-email), jamais pour bloquer ou annuler le rendez-vous.
//
// EXPÉDITEUR : RESEND_FROM_EMAIL est un secret de fonction configurable
// (`supabase secrets set RESEND_FROM_EMAIL="HAYEVA <contact@votre-domaine>"`)
// — tant qu'aucun domaine HAYEVA n'est vérifié dans Resend, la valeur par
// défaut ci-dessous (onboarding@resend.dev) ne peut délivrer qu'à l'adresse
// du compte Resend lui-même : l'envoi vers un vrai client échouera alors
// proprement (journalisé 'failed' dans booking_emails, jamais silencieux,
// jamais présenté comme un succès). Aucune clé n'est jamais exposée au
// frontend : RESEND_API_KEY reste un secret côté serveur uniquement.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const CLIENT_PANEL_URL = Deno.env.get('CLIENT_PANEL_URL') || 'https://hayeva.netlify.app/#espaceClient';

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string
  ));
}
function fmtDate(d: string): string {
  const [y, m, day] = d.slice(0, 10).split('-');
  return `${day}/${m}/${y}`;
}
function fmtEuros(cents: number): string {
  return (cents / 100).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €';
}

Deno.serve(async (req: Request) => {
  try {
    if (!WEBHOOK_SECRET || req.headers.get('authorization') !== `Bearer ${WEBHOOK_SECRET}`) {
      return new Response('unauthorized', { status: 401 });
    }
    const payload = await req.json();
    if (payload.type !== 'INSERT' || payload.table !== 'bookings') {
      return new Response('ignored', { status: 200 });
    }
    const booking = payload.record;
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // ---- Contact réel du client (invité ou compte particulier) ----
    let firstName = '';
    let contactEmail = '';
    let contactAddress = '';
    if (booking.guest_name) {
      firstName = String(booking.guest_name).trim().split(/\s+/)[0] || booking.guest_name;
      contactEmail = booking.guest_email || '';
      contactAddress = booking.guest_address || '';
    } else if (booking.customer_user_id) {
      const [{ data: cp }, { data: prof }] = await Promise.all([
        supabase.from('customer_profiles').select('first_name').eq('user_id', booking.customer_user_id).maybeSingle(),
        supabase.from('profiles').select('email').eq('user_id', booking.customer_user_id).maybeSingle(),
      ]);
      if (cp?.first_name) firstName = cp.first_name;
      if (prof?.email) contactEmail = prof.email;
      if (booking.customer_address_id) {
        const { data: addr } = await supabase
          .from('customer_addresses')
          .select('address,postal_code,city')
          .eq('id', booking.customer_address_id)
          .maybeSingle();
        if (addr) contactAddress = [addr.address, addr.postal_code, addr.city].filter(Boolean).join(', ');
      }
    }

    // Journalise l'intention d'envoi AVANT de tenter (pending), pour que même
    // une fonction qui crashe avant l'appel Resend laisse une trace visible
    // côté admin plutôt qu'un silence total.
    const { data: logRow } = await supabase
      .from('booking_emails')
      .insert({ booking_id: booking.id, email_type: 'received', status: 'pending', recipient_email: contactEmail || null })
      .select('id')
      .maybeSingle();

    if (!contactEmail) {
      if (logRow) await supabase.from('booking_emails').update({ status: 'failed', error_message: 'Aucune adresse e-mail associée à cette réservation.' }).eq('id', logRow.id);
      return new Response('no contact email', { status: 200 });
    }
    if (!RESEND_API_KEY) {
      if (logRow) await supabase.from('booking_emails').update({ status: 'failed', error_message: 'RESEND_API_KEY manquant.' }).eq('id', logRow.id);
      console.error('notify-customer-booking: RESEND_API_KEY manquant — e-mail client non envoyé, réservation non affectée.');
      return new Response('missing config', { status: 200 });
    }

    // ---- Prestation ----
    let serviceName = 'Intervention';
    if (booking.service_id) {
      const { data: svc } = await supabase.from('services').select('name').eq('id', booking.service_id).maybeSingle();
      if (svc) serviceName = svc.name;
    }
    if (booking.service_pack_id) {
      const { data: pack } = await supabase.from('service_packs').select('name').eq('id', booking.service_pack_id).maybeSingle();
      if (pack?.name) serviceName = `${serviceName} — ${pack.name}`;
    }

    // ---- Prix / déplacement / total : lus directement sur la réservation
    // déjà enregistrée (jamais recalculés ici) — voir compute_travel_fee_cents()
    // côté SQL pour la seule source de vérité du calcul.
    const priceLine = fmtEuros(booking.service_price_cents || 0);
    let travelLine: string;
    if (booking.distance_calculation_status !== 'ok') {
      travelLine = 'À vérifier par HAYEVA';
    } else if ((booking.travel_fee_cents || 0) > 0) {
      travelLine = fmtEuros(booking.travel_fee_cents) + (booking.one_way_distance_km ? ` (${booking.one_way_distance_km} km)` : '');
    } else {
      travelLine = 'Inclus';
    }
    const totalLine = booking.distance_calculation_status !== 'ok'
      ? fmtEuros(booking.service_price_cents || 0) + ' + déplacement à vérifier'
      : fmtEuros(booking.total_cents || 0);

    const subject = 'Votre demande de rendez-vous HAYEVA a bien été reçue';
    const html = renderEmailShell(`
      <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(firstName || '')},</h2>
      <p style="margin:0 0 18px; font-size:15px;">Merci d'avoir choisi HAYEVA. Votre demande de rendez-vous a bien été enregistrée.</p>
      ${statusBadgeHtml('📩 Demande reçue', 'received')}
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
        <tr><td style="padding:7px 0;color:#5B6B78;width:150px;">Prestation</td><td style="padding:7px 0;font-weight:600;text-align:right;">${escapeHtml(serviceName)}</td></tr>
        <tr><td style="padding:7px 0;color:#5B6B78;">Date demandée</td><td style="padding:7px 0;text-align:right;">${fmtDate(booking.date)}</td></tr>
        <tr><td style="padding:7px 0;color:#5B6B78;">Créneau</td><td style="padding:7px 0;text-align:right;">${(booking.start_time || '').slice(0, 5)}</td></tr>
        <tr><td style="padding:7px 0;color:#5B6B78;">Adresse</td><td style="padding:7px 0;text-align:right;">${contactAddress ? escapeHtml(contactAddress) : '—'}</td></tr>
        <tr><td style="padding:7px 0;color:#5B6B78;">Prix prestation</td><td style="padding:7px 0;text-align:right;">${priceLine}</td></tr>
        <tr><td style="padding:7px 0;color:#5B6B78;">Frais de déplacement</td><td style="padding:7px 0;text-align:right;">${travelLine}</td></tr>
        <tr><td style="padding:10px 0 0;color:#101B24;font-weight:700;border-top:1px solid #E5E0D5;">Total estimé</td><td style="padding:10px 0 0;font-weight:700;text-align:right;border-top:1px solid #E5E0D5;">${totalLine}</td></tr>
      </table>
      <p style="margin:20px 0 0; font-size:14px;">Votre rendez-vous n'est <strong>pas encore confirmé</strong>. Nous allons vérifier votre demande et vous recevrez un nouvel e-mail dès sa confirmation.</p>
      ${booking.customer_user_id ? `<p style="margin:22px 0 0;"><a href="${CLIENT_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-weight:600;font-size:14px;">Voir ma demande</a></p>` : ''}
    `, escapeHtml(booking.reference || ''));

    const emailRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM_EMAIL, to: [contactEmail], subject, html }),
    });

    if (logRow) {
      if (emailRes.ok) {
        await supabase.from('booking_emails').update({ status: 'sent', sent_at: new Date().toISOString() }).eq('id', logRow.id);
      } else {
        const errText = await emailRes.text();
        console.error('notify-customer-booking: échec envoi Resend', emailRes.status, errText);
        await supabase.from('booking_emails').update({ status: 'failed', error_message: `Resend ${emailRes.status}: ${errText.slice(0, 500)}` }).eq('id', logRow.id);
      }
    }

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('notify-customer-booking: erreur inattendue', err);
    return new Response('error handled', { status: 200 });
  }
});
