// Supabase Edge Function — e-mail au client quand HAYEVA confirme ou
// annule/refuse un rendez-vous (changement de statut depuis l'espace
// administrateur).
//
// DÉCLENCHEMENT : trigger Postgres AFTER UPDATE ON bookings (voir
// supabase/migrations/0007_travel_and_emails.sql,
// trg_notify_customer_status_change), qui ne se déclenche QUE si le statut a
// réellement changé ET que le nouveau statut est CONFIRMED ou CANCELLED —
// jamais pour un simple rafraîchissement ou un changement d'un autre champ.
// Même mécanisme pg_net + WEBHOOK_SECRET que les autres triggers de ce
// projet (Dashboard Webhooks indisponible).
//
// Ne confond jamais un rendez-vous encore PENDING avec un rendez-vous
// confirmé : cette fonction n'envoie "confirmé" que lorsque Postgres a
// réellement écrit CONFIRMED en base (vérifié via le payload du trigger,
// jamais supposé côté client).

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
    if (payload.type !== 'UPDATE' || payload.table !== 'bookings') {
      return new Response('ignored', { status: 200 });
    }
    const booking = payload.record;
    if (booking.status !== 'CONFIRMED' && booking.status !== 'CANCELLED') {
      return new Response('ignored status', { status: 200 });
    }
    const emailType = booking.status === 'CONFIRMED' ? 'confirmed' : 'cancelled';
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

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

    const { data: logRow } = await supabase
      .from('booking_emails')
      .insert({ booking_id: booking.id, email_type: emailType, status: 'pending', recipient_email: contactEmail || null })
      .select('id')
      .maybeSingle();

    if (!contactEmail) {
      if (logRow) await supabase.from('booking_emails').update({ status: 'failed', error_message: 'Aucune adresse e-mail associée à cette réservation.' }).eq('id', logRow.id);
      return new Response('no contact email', { status: 200 });
    }
    if (!RESEND_API_KEY) {
      if (logRow) await supabase.from('booking_emails').update({ status: 'failed', error_message: 'RESEND_API_KEY manquant.' }).eq('id', logRow.id);
      return new Response('missing config', { status: 200 });
    }

    let serviceName = 'Intervention';
    let prepInstructionKey: string | null = null;
    if (booking.service_id) {
      const { data: svc } = await supabase.from('services').select('name, prep_instruction_key').eq('id', booking.service_id).maybeSingle();
      if (svc) {
        serviceName = svc.name;
        prepInstructionKey = svc.prep_instruction_key;
      }
    }

    // Consigne de préparation avant intervention : texte configuré en base
    // (prep_instruction_categories, voir 0025_prep_instructions.sql), JAMAIS
    // généré ici. Repli sur la catégorie générique (is_default) si la
    // prestation n'a pas de clé dédiée ou si sa catégorie est désactivée.
    // Affichée uniquement pour un rendez-vous CONFIRMÉ (jamais pour une
    // annulation).
    let prepInstructionText: string | null = null;
    if (emailType === 'confirmed') {
      const { data: prepRows } = await supabase
        .from('prep_instruction_categories')
        .select('key, instruction, is_active, is_default');
      const rows = prepRows || [];
      const match = prepInstructionKey
        ? rows.find((r) => r.key === prepInstructionKey && r.is_active)
        : null;
      const fallback = rows.find((r) => r.is_default && r.is_active);
      prepInstructionText = (match || fallback)?.instruction || null;
    }

    const priceLine = fmtEuros(booking.service_price_cents || 0);
    const travelLine = booking.distance_calculation_status !== 'ok'
      ? 'À vérifier par HAYEVA'
      : ((booking.travel_fee_cents || 0) > 0 ? fmtEuros(booking.travel_fee_cents) : 'Inclus');
    const totalLine = booking.distance_calculation_status !== 'ok'
      ? fmtEuros(booking.service_price_cents || 0) + ' + déplacement à vérifier'
      : fmtEuros(booking.total_cents || 0);

    // Deux annulations très différentes déclenchent ce même trigger (tout
    // passage à CANCELLED) : un refus/annulation ADMIN d'une demande pas
    // encore honorée (le texte "n'a pas pu être retenue" est adapté), et une
    // annulation VOLONTAIRE du client depuis son Espace (cancel_own_booking,
    // voir 0017_customer_reschedule_cancel.sql) — dans ce second cas, dire
    // "n'a pas pu être retenue" est trompeur (le client a annulé lui-même un
    // rendez-vous déjà confirmé) : booking.cancelled_by distingue les deux
    // (colonne posée uniquement par cancel_own_booking(), présente dans
    // to_jsonb(NEW) sans requête supplémentaire).
    const isCustomerCancellation = emailType === 'cancelled' && booking.cancelled_by === 'customer';

    let subject: string;
    let introText: string;
    let badgeLabel: string;
    let badgeTone: 'confirmed' | 'cancelled';
    if (emailType === 'confirmed') {
      subject = '✓ Votre rendez-vous HAYEVA est confirmé';
      introText = 'Bonne nouvelle, votre rendez-vous HAYEVA est <strong>confirmé</strong>.';
      badgeLabel = '✅ Confirmée';
      badgeTone = 'confirmed';
    } else if (isCustomerCancellation) {
      subject = 'Votre rendez-vous HAYEVA a bien été annulé';
      introText = 'Votre rendez-vous HAYEVA a bien été <strong>annulé</strong>, comme demandé. Le créneau a été libéré. Vous pouvez prendre un nouveau rendez-vous depuis votre espace client dès que vous le souhaitez.';
      badgeLabel = '✖ Annulé par vous';
      badgeTone = 'cancelled';
    } else {
      subject = 'Votre demande de rendez-vous HAYEVA a été annulée';
      introText = 'Votre demande de rendez-vous n\'a malheureusement pas pu être retenue. N\'hésitez pas à nous contacter ou à effectuer une nouvelle demande pour un autre créneau.';
      badgeLabel = '✖ Annulée';
      badgeTone = 'cancelled';
    }

    const detailsRows = emailType === 'confirmed' ? `
      <tr><td style="padding:7px 0;color:#5B6B78;">Prix prestation</td><td style="padding:7px 0;text-align:right;">${priceLine}</td></tr>
      <tr><td style="padding:7px 0;color:#5B6B78;">Frais de déplacement</td><td style="padding:7px 0;text-align:right;">${travelLine}</td></tr>
      <tr><td style="padding:10px 0 0;color:#101B24;font-weight:700;border-top:1px solid #E5E0D5;">Total</td><td style="padding:10px 0 0;font-weight:700;text-align:right;border-top:1px solid #E5E0D5;">${totalLine}</td></tr>
    ` : '';

    const prepBlockHtml = prepInstructionText ? `
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin-top:18px;">
        <tr><td style="background:#CFEFEA;border-radius:10px;padding:14px 16px;font-size:14px;color:#101B24;">
          <p style="margin:0 0 6px;font-weight:700;">🔧 Pour préparer notre intervention</p>
          <p style="margin:0;">${escapeHtml(prepInstructionText)}</p>
          <p style="margin:10px 0 0;font-style:italic;color:#3C4C58;">Ces quelques préparatifs nous permettront d'intervenir dans de bonnes conditions et d'éviter une perte de temps sur place.</p>
        </td></tr>
      </table>
    ` : '';

    const html = renderEmailShell(`
      <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(firstName || '')},</h2>
      <p style="margin:0 0 18px; font-size:15px;">${introText}</p>
      ${statusBadgeHtml(badgeLabel, badgeTone)}
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
        <tr><td style="padding:7px 0;color:#5B6B78;width:150px;">Prestation</td><td style="padding:7px 0;font-weight:600;text-align:right;">${escapeHtml(serviceName)}</td></tr>
        <tr><td style="padding:7px 0;color:#5B6B78;">Date</td><td style="padding:7px 0;text-align:right;">${fmtDate(booking.date)}</td></tr>
        <tr><td style="padding:7px 0;color:#5B6B78;">Créneau</td><td style="padding:7px 0;text-align:right;">${(booking.start_time || '').slice(0, 5)}</td></tr>
        <tr><td style="padding:7px 0;color:#5B6B78;">Adresse</td><td style="padding:7px 0;text-align:right;">${contactAddress ? escapeHtml(contactAddress) : '—'}</td></tr>
        ${detailsRows}
      </table>
      ${prepBlockHtml}
      ${booking.customer_user_id ? `<p style="margin:22px 0 0;"><a href="${CLIENT_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-weight:600;font-size:14px;">Voir mon rendez-vous</a></p>` : ''}
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
        console.error('notify-customer-status-change: échec envoi Resend', emailRes.status, errText);
        await supabase.from('booking_emails').update({ status: 'failed', error_message: `Resend ${emailRes.status}: ${errText.slice(0, 500)}` }).eq('id', logRow.id);
      }
    }

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('notify-customer-status-change: erreur inattendue', err);
    return new Response('error handled', { status: 200 });
  }
});
