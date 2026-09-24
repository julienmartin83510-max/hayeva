// Supabase Edge Function — renvoie un e-mail client après un échec
// ('failed' dans booking_emails), depuis le bouton "Renvoyer" du panneau
// Administration.
//
// DÉCLENCHEMENT : appelée directement par le frontend (fetch), authentifiée
// avec le jeton de session de l'admin connecté — comme propose-alternative-
// slot, PAS par un trigger. Supabase vérifie déjà que le jeton est valide
// (JWT), et cette fonction revérifie EN PLUS, côté serveur, que ce compte a
// bien global_role='admin' avant d'envoyer quoi que ce soit.
//
// Réutilise le même contenu que notify-customer-booking /
// notify-customer-status-change plutôt qu'un nouveau template : email_type
// détermine simplement quel sujet/corps préparer à partir de la réservation
// actuelle (relue en base, jamais depuis des valeurs approximatives).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
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

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const authHeader = req.headers.get('authorization') || '';
    const jwt = authHeader.replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ error: 'unauthorized' }, 401);

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: userRes, error: userErr } = await supabase.auth.getUser(jwt);
    if (userErr || !userRes?.user) return json({ error: 'unauthorized' }, 401);

    const { data: profile } = await supabase.from('profiles').select('global_role').eq('user_id', userRes.user.id).maybeSingle();
    if (!profile || profile.global_role !== 'admin') return json({ error: 'forbidden' }, 403);

    const body = await req.json();
    const bookingId = body.booking_id;
    const emailType = body.email_type;
    if (!bookingId || !['received', 'confirmed', 'cancelled'].includes(emailType)) {
      return json({ error: 'missing_fields' }, 400);
    }

    const { data: booking } = await supabase.from('bookings').select('*').eq('id', bookingId).maybeSingle();
    if (!booking) return json({ error: 'not_found' }, 404);

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
    if (!contactEmail) return json({ error: 'no_contact_email' }, 422);
    if (!RESEND_API_KEY) return json({ error: 'missing_resend_key' }, 500);

    let serviceName = 'Intervention';
    if (booking.service_id) {
      const { data: svc } = await supabase.from('services').select('name').eq('id', booking.service_id).maybeSingle();
      if (svc) serviceName = svc.name;
    }

    const priceLine = fmtEuros(booking.service_price_cents || 0);
    const travelLine = booking.distance_calculation_status !== 'ok'
      ? 'À vérifier par HAYEVA'
      : ((booking.travel_fee_cents || 0) > 0 ? fmtEuros(booking.travel_fee_cents) : 'Inclus');
    const totalLine = booking.distance_calculation_status !== 'ok'
      ? fmtEuros(booking.service_price_cents || 0) + ' + déplacement à vérifier'
      : fmtEuros(booking.total_cents || 0);

    let subject: string;
    let badgeHtml: string;
    let introHtml: string;
    let detailsHtml: string;
    if (emailType === 'received') {
      subject = 'Votre demande de rendez-vous HAYEVA a bien été reçue';
      badgeHtml = statusBadgeHtml('📩 Demande reçue', 'received');
      introHtml = `<p style="margin:0 0 18px; font-size:15px;">Merci d'avoir choisi HAYEVA. Votre demande de rendez-vous a bien été enregistrée.</p>`;
      detailsHtml = `
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
      `;
    } else if (emailType === 'confirmed') {
      subject = '✓ Votre rendez-vous HAYEVA est confirmé';
      badgeHtml = statusBadgeHtml('✅ Confirmée', 'confirmed');
      introHtml = `<p style="margin:0 0 18px; font-size:15px;">Bonne nouvelle, votre rendez-vous HAYEVA est <strong>confirmé</strong>.</p>`;
      detailsHtml = `
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
          <tr><td style="padding:7px 0;color:#5B6B78;width:150px;">Prestation</td><td style="padding:7px 0;font-weight:600;text-align:right;">${escapeHtml(serviceName)}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Date</td><td style="padding:7px 0;text-align:right;">${fmtDate(booking.date)}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Créneau</td><td style="padding:7px 0;text-align:right;">${(booking.start_time || '').slice(0, 5)}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Adresse</td><td style="padding:7px 0;text-align:right;">${contactAddress ? escapeHtml(contactAddress) : '—'}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Prix prestation</td><td style="padding:7px 0;text-align:right;">${priceLine}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Frais de déplacement</td><td style="padding:7px 0;text-align:right;">${travelLine}</td></tr>
          <tr><td style="padding:10px 0 0;color:#101B24;font-weight:700;border-top:1px solid #E5E0D5;">Total</td><td style="padding:10px 0 0;font-weight:700;text-align:right;border-top:1px solid #E5E0D5;">${totalLine}</td></tr>
        </table>
      `;
    } else {
      subject = 'Votre demande de rendez-vous HAYEVA a été annulée';
      badgeHtml = statusBadgeHtml('✖ Annulée', 'cancelled');
      introHtml = `<p style="margin:0 0 18px; font-size:15px;">Votre demande de rendez-vous n'a malheureusement pas pu être retenue. N'hésitez pas à nous contacter ou à effectuer une nouvelle demande pour un autre créneau.</p>`;
      detailsHtml = '';
    }

    const html = renderEmailShell(`
      <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(firstName || '')},</h2>
      ${introHtml}
      ${badgeHtml}
      ${detailsHtml}
      ${booking.customer_user_id ? `<p style="margin:22px 0 0;"><a href="${CLIENT_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-weight:600;font-size:14px;">Voir mon espace</a></p>` : ''}
    `, escapeHtml(booking.reference || ''));

    const { data: logRow } = await supabase
      .from('booking_emails')
      .insert({ booking_id: booking.id, email_type: emailType, status: 'pending', recipient_email: contactEmail })
      .select('id')
      .maybeSingle();

    const emailRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM_EMAIL, to: [contactEmail], subject, html }),
    });

    if (!emailRes.ok) {
      const errText = await emailRes.text();
      if (logRow) await supabase.from('booking_emails').update({ status: 'failed', error_message: `Resend ${emailRes.status}: ${errText.slice(0, 500)}` }).eq('id', logRow.id);
      return json({ error: 'email_failed', detail: errText }, 502);
    }
    if (logRow) await supabase.from('booking_emails').update({ status: 'sent', sent_at: new Date().toISOString() }).eq('id', logRow.id);

    return json({ ok: true });
  } catch (err) {
    console.error('resend-booking-email: erreur inattendue', err);
    return json({ error: 'unexpected' }, 500);
  }
});
