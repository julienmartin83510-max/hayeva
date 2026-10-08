// Supabase Edge Function — envoie au client un e-mail proposant un autre
// créneau pour une réservation, depuis le bouton "🕐 Proposer un autre
// créneau" du panneau Administration.
//
// DÉCLENCHEMENT : appelée directement par le frontend (fetch), authentifiée
// avec le jeton de session de l'admin connecté — PAS par un trigger comme
// notify-admin-booking. C'est un geste explicite d'un utilisateur réel, pas
// un événement base de données : Supabase vérifie déjà que le jeton est
// valide (JWT), et cette fonction revérifie EN PLUS, côté serveur, que ce
// compte a bien global_role='admin' avant d'envoyer quoi que ce soit —
// jamais de confiance dans une affirmation venue du client.
//
// SÉCURITÉ : aucun secret exposé au frontend. SUPABASE_URL et
// SUPABASE_SERVICE_ROLE_KEY sont injectées automatiquement. RESEND_API_KEY
// et RESEND_FROM_EMAIL (optionnel) sont des secrets de fonction, partagés
// avec notify-admin-booking.
//
// N'écrit rien en base (pas de changement de statut ni de date) : la
// proposition n'est communiquée que par e-mail, exactement comme demandé —
// c'est à l'admin de suivre la réponse du client comme aujourd'hui (par
// téléphone, ou en confirmant manuellement une fois d'accord).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const REPLY_TO_EMAIL = Deno.env.get('REPLY_TO_EMAIL') || 'contact@hayeva.fr';

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string
  ));
}

function fmtDate(d: string): string {
  const [y, m, day] = d.slice(0, 10).split('-');
  return `${day}/${m}/${y}`;
}

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const authHeader = req.headers.get('authorization') || '';
    const jwt = authHeader.replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ error: 'unauthorized' }, 401);

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: userRes, error: userErr } = await supabase.auth.getUser(jwt);
    if (userErr || !userRes?.user) return json({ error: 'unauthorized' }, 401);

    const { data: profile } = await supabase
      .from('profiles')
      .select('global_role')
      .eq('user_id', userRes.user.id)
      .maybeSingle();
    if (!profile || profile.global_role !== 'admin') {
      return json({ error: 'forbidden' }, 403);
    }

    const body = await req.json();
    const bookingId = body.booking_id;
    const proposedDate = body.proposed_date;
    const proposedTime = body.proposed_time;
    const message = body.message ? String(body.message).slice(0, 500) : null;
    if (!bookingId || !proposedDate || !proposedTime) {
      return json({ error: 'missing_fields' }, 400);
    }

    const { data: booking } = await supabase
      .from('bookings')
      .select('id, reference, date, start_time, guest_name, guest_email, customer_user_id, services(name)')
      .eq('id', bookingId)
      .maybeSingle();
    if (!booking) return json({ error: 'not_found' }, 404);

    let contactEmail: string | null = booking.guest_email;
    let contactName: string = booking.guest_name || 'Client';
    if (booking.customer_user_id) {
      const [{ data: cp }, { data: prof }] = await Promise.all([
        supabase.from('customer_profiles').select('first_name,last_name').eq('user_id', booking.customer_user_id).maybeSingle(),
        supabase.from('profiles').select('email').eq('user_id', booking.customer_user_id).maybeSingle(),
      ]);
      if (prof?.email) contactEmail = prof.email;
      if (cp) contactName = [cp.first_name, cp.last_name].filter(Boolean).join(' ') || contactName;
    }
    if (!contactEmail) return json({ error: 'no_contact_email' }, 422);

    if (!RESEND_API_KEY) return json({ error: 'missing_resend_key' }, 500);

    const svcName = (booking.services as { name?: string } | null)?.name || 'votre intervention';
    const subject = `HAYEVA — Nouveau créneau proposé pour votre rendez-vous`;

    const html = renderEmailShell(`
      <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(contactName)},</h2>
      <p style="margin:0 0 18px; font-size:15px;">Le créneau initialement demandé pour <strong>${escapeHtml(svcName)}</strong> (initialement le ${fmtDate(booking.date)} à ${(booking.start_time || '').slice(0, 5)}) n'est finalement pas disponible.</p>
      ${statusBadgeHtml('🕐 Nouveau créneau proposé', 'rescheduled')}
      <p style="margin:0 0 8px; font-size:15px;">Nous vous proposons à la place :</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:0 0 16px;">
        <tr><td style="background:#EAF4FB;border-radius:12px;padding:14px 16px;font-size:17px;font-weight:700;color:#101B24;">📅 ${fmtDate(proposedDate)} à ${String(proposedTime).slice(0, 5)}</td></tr>
      </table>
      ${message ? `<p style="margin:0 0 16px; font-size:14px;">${escapeHtml(message)}</p>` : ''}
      <p style="margin:0; font-size:14px;">Pour confirmer ce nouveau créneau ou nous en demander un autre, répondez simplement à cet e-mail ou appelez-nous au <strong>06 71 26 23 02</strong>.</p>
    `, escapeHtml(booking.reference || ''));

    const emailRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM_EMAIL, to: [contactEmail], reply_to: REPLY_TO_EMAIL, subject, html }),
    });

    if (!emailRes.ok) {
      console.error('propose-alternative-slot: échec envoi Resend', emailRes.status, await emailRes.text());
      return json({ error: 'email_failed' }, 502);
    }

    return json({ ok: true });
  } catch (err) {
    console.error('propose-alternative-slot: erreur inattendue', err);
    return json({ error: 'unexpected' }, 500);
  }
});
