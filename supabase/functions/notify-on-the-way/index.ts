// Supabase Edge Function — « Je suis en route » (V2 phase 59 / V3 SMS).
// Appelée depuis la vue technicien par un admin connecté (JWT vérifié) :
// prévient le client (e-mail, et SMS si un fournisseur est configuré) avec
// l'heure d'arrivée estimée. Une seule notification par rendez-vous
// (booking_on_the_way.booking_id unique), uniquement pour un rendez-vous
// confirmé du jour. Aucun fournisseur SMS payant n'est activé ici : sans
// SMS_PROVIDER, le SMS est simplement marqué « not_configured ».

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';
import { sendReminderSMS } from '../_shared/sms.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const REPLY_TO_EMAIL = Deno.env.get('REPLY_TO_EMAIL') || 'contact@hayeva.fr';
const PHONE = '06 71 26 23 02';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function escapeHtml(s: string): string {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
}
function toE164(phone: string): string | null {
  const d = String(phone || '').replace(/[^\d+]/g, '');
  if (/^\+\d{8,15}$/.test(d)) return d;
  if (/^0[1-9]\d{8}$/.test(d)) return '+33' + d.slice(1);
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    const { data: userRes } = jwt ? await supabase.auth.getUser(jwt) : { data: null };
    const user = userRes?.user;
    if (!user) return json({ error: 'unauthorized' }, 401);
    const { data: profile } = await supabase.from('profiles').select('global_role').eq('user_id', user.id).maybeSingle();
    if (profile?.global_role !== 'admin') return json({ error: 'forbidden' }, 403);

    const body = await req.json().catch(() => ({}));
    const bookingId = typeof body?.booking_id === 'string' ? body.booking_id : '';
    const eta = Math.round(Number(body?.eta_minutes));
    if (!/^[0-9a-f-]{36}$/i.test(bookingId) || !(eta >= 5 && eta <= 180)) return json({ error: 'invalid_request' }, 400);

    const { data: booking } = await supabase.from('bookings')
      .select('id, reference, status, date, guest_name, guest_email, guest_phone, customer_user_id, client_id')
      .eq('id', bookingId).maybeSingle();
    if (!booking) return json({ error: 'not_found' }, 404);
    const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Europe/Paris' });
    if (booking.status !== 'CONFIRMED' || booking.date !== today) return json({ error: 'not_today_confirmed' }, 409);

    let email = '';
    let phone = '';
    let name = '';
    if (booking.guest_email || booking.guest_phone) {
      email = booking.guest_email || ''; phone = booking.guest_phone || '';
      name = String(booking.guest_name || '').trim().split(/\s+/)[0] || '';
    }
    if (!email && booking.customer_user_id) {
      const [{ data: prof }, { data: cp }] = await Promise.all([
        supabase.from('profiles').select('email').eq('user_id', booking.customer_user_id).maybeSingle(),
        supabase.from('customer_profiles').select('first_name, phone').eq('user_id', booking.customer_user_id).maybeSingle(),
      ]);
      email = prof?.email || ''; name = name || cp?.first_name || ''; phone = phone || cp?.phone || '';
    }
    if ((!email || !phone) && booking.client_id) {
      const { data: cl } = await supabase.from('clients').select('email, first_name, phone').eq('id', booking.client_id).maybeSingle();
      email = email || cl?.email || ''; phone = phone || cl?.phone || ''; name = name || cl?.first_name || '';
    }
    if (!email && !phone) return json({ error: 'no_email' }, 422);

    const { data: claim, error: claimErr } = await supabase.from('booking_on_the_way')
      .insert({ booking_id: bookingId, eta_minutes: eta, recipient_email: email || null, sent_by: user.id })
      .select('id').maybeSingle();
    if (!claim) {
      if (claimErr && claimErr.code !== '23505') throw claimErr;
      return json({ error: 'already_sent' }, 409);
    }

    const arrival = new Date(Date.now() + eta * 60000).toLocaleTimeString('fr-FR', { timeZone: 'Europe/Paris', hour: '2-digit', minute: '2-digit' });

    let emailStatus: 'sent' | 'failed' | 'no_email' = 'no_email';
    if (email && RESEND_API_KEY) {
      const bodyHtml = `
        <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(name)},</h2>
        <p style="margin:0 0 18px; font-size:15px;">Votre technicien HAYEVA est en route. Arrivée estimée vers <strong>${arrival}</strong> (environ ${eta} min), selon la circulation.</p>
        ${statusBadgeHtml('🚐 Technicien en route', 'confirmed')}
        <p style="margin:0; font-size:14px;">Besoin de nous joindre ? Appelez le <strong>${PHONE}</strong>.</p>`;
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json', 'Idempotency-Key': `on_the_way:${bookingId}` },
        body: JSON.stringify({ from: FROM_EMAIL, to: [email], reply_to: REPLY_TO_EMAIL, subject: 'Votre technicien HAYEVA est en route', html: renderEmailShell(bodyHtml, escapeHtml(booking.reference || '')) }),
      });
      emailStatus = res.ok ? 'sent' : 'failed';
      if (!res.ok) console.error('notify-on-the-way: échec Resend', res.status);
    } else if (email) {
      emailStatus = 'failed';
    }

    let smsStatus: 'sent' | 'not_configured' | 'failed' | 'no_phone' = 'no_phone';
    const e164 = toE164(phone);
    if (e164) {
      const sms = await sendReminderSMS(e164, `HAYEVA — Votre technicien est en route pour votre intervention. Arrivée estimée vers ${arrival}. Contact : ${PHONE}`);
      smsStatus = sms.ok ? 'sent' : (sms.reason === 'SMS_READY_NOT_CONFIGURED' ? 'not_configured' : 'failed');
    }

    if (emailStatus !== 'sent' && smsStatus !== 'sent') {
      // Aucun canal n'a abouti : la réservation de l'envoi est libérée pour un nouvel essai.
      await supabase.from('booking_on_the_way').delete().eq('id', claim.id);
      return json({ error: 'email_failed', sms: smsStatus }, 502);
    }
    await supabase.from('booking_on_the_way').update({ status: 'sent', sent_at: new Date().toISOString(), email_status: emailStatus, sms_status: smsStatus }).eq('id', claim.id);
    return json({ ok: true, arrival, email: emailStatus, sms: smsStatus });
  } catch (err) {
    console.error('notify-on-the-way: erreur inattendue', err instanceof Error ? err.message : String(err));
    return json({ error: 'unexpected' }, 500);
  }
});
