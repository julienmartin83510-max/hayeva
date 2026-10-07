// Supabase Edge Function — « Je suis en route » (V2 phase 59).
// Appelée depuis la vue technicien par un admin connecté (JWT vérifié) :
// envoie au client un e-mail avec l'heure d'arrivée estimée. Une seule
// notification par rendez-vous (booking_on_the_way.booking_id unique),
// uniquement pour un rendez-vous confirmé du jour.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';

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
      .select('id, reference, status, date, guest_name, guest_email, customer_user_id, client_id')
      .eq('id', bookingId).maybeSingle();
    if (!booking) return json({ error: 'not_found' }, 404);
    const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Europe/Paris' });
    if (booking.status !== 'CONFIRMED' || booking.date !== today) return json({ error: 'not_today_confirmed' }, 409);

    let email = '';
    let name = '';
    if (booking.guest_email) {
      email = booking.guest_email;
      name = String(booking.guest_name || '').trim().split(/\s+/)[0] || '';
    } else if (booking.customer_user_id) {
      const [{ data: prof }, { data: cp }] = await Promise.all([
        supabase.from('profiles').select('email').eq('user_id', booking.customer_user_id).maybeSingle(),
        supabase.from('customer_profiles').select('first_name').eq('user_id', booking.customer_user_id).maybeSingle(),
      ]);
      email = prof?.email || ''; name = cp?.first_name || '';
    }
    if (!email && booking.client_id) {
      const { data: cl } = await supabase.from('clients').select('email, first_name').eq('id', booking.client_id).maybeSingle();
      email = cl?.email || ''; name = name || cl?.first_name || '';
    }
    if (!email) return json({ error: 'no_email' }, 422);

    const { data: claim, error: claimErr } = await supabase.from('booking_on_the_way')
      .insert({ booking_id: bookingId, eta_minutes: eta, recipient_email: email, sent_by: user.id })
      .select('id').maybeSingle();
    if (!claim) {
      if (claimErr && claimErr.code !== '23505') throw claimErr;
      return json({ error: 'already_sent' }, 409);
    }
    const finish = (fields: Record<string, unknown>) => supabase.from('booking_on_the_way').update(fields).eq('id', claim.id);
    if (!RESEND_API_KEY) { await supabase.from('booking_on_the_way').delete().eq('id', claim.id); return json({ error: 'email_unavailable' }, 503); }

    const arrival = new Date(Date.now() + eta * 60000).toLocaleTimeString('fr-FR', { timeZone: 'Europe/Paris', hour: '2-digit', minute: '2-digit' });
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
    if (!res.ok) {
      // Échec d'envoi : la réservation est libérée pour permettre un nouvel essai.
      console.error('notify-on-the-way: échec Resend', res.status, (await res.text()).slice(0, 200));
      await supabase.from('booking_on_the_way').delete().eq('id', claim.id);
      return json({ error: 'email_failed' }, 502);
    }
    await finish({ status: 'sent', sent_at: new Date().toISOString() });
    return json({ ok: true, arrival });
  } catch (err) {
    console.error('notify-on-the-way: erreur inattendue', err instanceof Error ? err.message : String(err));
    return json({ error: 'unexpected' }, 500);
  }
});
