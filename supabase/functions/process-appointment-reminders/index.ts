// Supabase Edge Function — rappel au client la veille de son rendez-vous.
//
// DÉCLENCHEMENT : pg_cron quotidien ('hayeva-appointment-reminders', voir
// 0128_v4_appointment_reminders.sql) avec le secret partagé du Vault, ou
// manuellement par un admin connecté.
//
// Cible : réservations CONFIRMED du lendemain (jour civil Europe/Paris).
// Anti-doublon : sendEmailOnce avec la clé reminder_j1:<booking>:<date> —
// un rendez-vous déplacé à une autre date reçoit son propre rappel, jamais
// deux rappels pour la même date.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';
import { sendEmailOnce } from '../_shared/mail.ts';
import { escapeHtml, fmtDate, fmtTime, resolveBookingContact, rowHtml } from '../_shared/booking-contact.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CRON_SHARED_SECRET = Deno.env.get('CRON_SHARED_SECRET');
const SITE_URL = Deno.env.get('PUBLIC_SITE_URL') || 'https://hayeva.fr';
const PHONE = '06 71 26 23 02';

const corsHeaders = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type, x-cron-secret' };

function tomorrowParis(): string {
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Europe/Paris' });
  const d = new Date(today + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    let authorized = !!CRON_SHARED_SECRET && req.headers.get('x-cron-secret') === CRON_SHARED_SECRET;
    const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!authorized && jwt) {
      const { data: userRes } = await supabase.auth.getUser(jwt);
      if (userRes?.user) {
        const { data: profile } = await supabase.from('profiles').select('global_role').eq('user_id', userRes.user.id).maybeSingle();
        authorized = profile?.global_role === 'admin';
      }
    }
    if (!authorized) return json({ error: 'unauthorized' }, 401);

    const day = tomorrowParis();
    const { data: rows, error } = await supabase.from('bookings')
      .select('id, reference, date, start_time, status, guest_name, guest_email, guest_phone, guest_address, customer_user_id, customer_address_id, professional_account_id, client_id, services(name)')
      .eq('status', 'CONFIRMED').eq('date', day).limit(200);
    if (error) throw error;

    const results: Array<{ id: string; status: string }> = [];
    for (const b of rows || []) {
      try {
        const contact = await resolveBookingContact(supabase, b);
        const serviceName = (b as { services?: { name?: string } }).services?.name || 'Intervention';
        const hasAccount = !!(b.customer_user_id || b.professional_account_id);
        const bodyHtml = `
          <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(contact.firstName)},</h2>
          <p style="margin:0 0 18px; font-size:15px;">Petit rappel : votre rendez-vous HAYEVA a lieu <strong>demain</strong>.</p>
          ${statusBadgeHtml('📅 Rendez-vous demain', 'confirmed')}
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
            ${rowHtml('Prestation', escapeHtml(serviceName), true)}
            ${rowHtml('Date', fmtDate(b.date))}
            ${rowHtml('Heure', fmtTime(b.start_time))}
            ${rowHtml('Adresse', escapeHtml(contact.address))}
          </table>
          <p style="margin:20px 0 0; font-size:14px;">Merci de prévoir un accès dégagé aux équipements concernés. Un empêchement ? Prévenez-nous au plus vite au <strong>${PHONE}</strong> ou en répondant à cet e-mail.</p>
          ${hasAccount ? `<p style="margin:22px 0 0;"><a href="${SITE_URL}/#espaceClient" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-weight:600;font-size:14px;">Voir mon rendez-vous</a></p>` : ''}`;
        const r = await sendEmailOnce(supabase, {
          dedupeKey: `reminder_j1:${b.id}:${b.date}`,
          bookingId: b.id,
          emailType: 'reminder',
          to: contact.email,
          subject: `Rappel : votre rendez-vous HAYEVA demain à ${fmtTime(b.start_time)}`,
          html: renderEmailShell(bodyHtml, escapeHtml(b.reference || '')),
        });
        results.push({ id: b.id, status: r });
      } catch (e) {
        console.error('process-appointment-reminders: échec', b.id, e instanceof Error ? e.message : String(e));
        results.push({ id: b.id, status: 'failed' });
      }
    }
    return json({ ok: true, day, processed: results.length, results });
  } catch (err) {
    console.error('process-appointment-reminders: erreur inattendue', err instanceof Error ? err.message : String(err));
    return json({ error: 'unexpected' }, 500);
  }
});
