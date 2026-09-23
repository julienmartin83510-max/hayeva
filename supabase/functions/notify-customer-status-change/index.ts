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
    let introHtml: string;
    if (emailType === 'confirmed') {
      subject = '✓ Votre rendez-vous HAYEVA est confirmé';
      introHtml = `<p style="margin-top:0;">Bonne nouvelle, votre rendez-vous HAYEVA est <strong>confirmé</strong>.</p>`;
    } else {
      subject = 'Votre demande de rendez-vous HAYEVA a été annulée';
      introHtml = `<p style="margin-top:0;">Votre demande de rendez-vous n'a malheureusement pas pu être retenue. N'hésitez pas à nous contacter ou à effectuer une nouvelle demande pour un autre créneau.</p>`;
    }

    const html = `
      <div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;color:#16222c;">
        <h2 style="color:#101B24;margin-bottom:6px;">Bonjour ${escapeHtml(firstName || '')},</h2>
        ${introHtml}
        <table style="width:100%;border-collapse:collapse;font-size:14px;margin-top:16px;">
          <tr><td style="padding:6px 0;color:#5B6B78;width:150px;">Prestation</td><td style="padding:6px 0;font-weight:600;">${escapeHtml(serviceName)}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Date</td><td style="padding:6px 0;">${fmtDate(booking.date)}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Heure</td><td style="padding:6px 0;">${(booking.start_time || '').slice(0, 5)}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Adresse d'intervention</td><td style="padding:6px 0;">${contactAddress ? escapeHtml(contactAddress) : '—'}</td></tr>
          ${emailType === 'confirmed' ? `
          <tr><td style="padding:6px 0;color:#5B6B78;">Prix prestation</td><td style="padding:6px 0;">${priceLine}</td></tr>
          <tr><td style="padding:6px 0;color:#5B6B78;">Frais de déplacement</td><td style="padding:6px 0;">${travelLine}</td></tr>
          <tr><td style="padding:8px 0;color:#101B24;font-weight:700;border-top:1px solid #e5e0d5;">Total</td><td style="padding:8px 0;font-weight:700;border-top:1px solid #e5e0d5;">${totalLine}</td></tr>
          ` : ''}
        </table>
        ${booking.customer_user_id ? `<p style="margin-top:22px;"><a href="${CLIENT_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:600;font-size:14px;">Voir mon rendez-vous</a></p>` : ''}
        <p style="margin-top:26px;">À bientôt,<br>L'équipe HAYEVA</p>
        <p style="margin-top:20px;font-size:12px;color:#8A97A3;">Réf. ${escapeHtml(booking.reference || '')}</p>
      </div>
    `;

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
