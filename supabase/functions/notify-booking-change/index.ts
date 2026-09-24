// Supabase Edge Function — notifie l'administrateur (et, pour un
// déplacement, le client) après qu'un CLIENT CONNECTÉ a lui-même déplacé ou
// annulé son propre rendez-vous depuis l'Espace Client.
//
// DÉCLENCHEMENT : appelée uniquement depuis les fonctions RPC
// reschedule_own_booking() / cancel_own_booking() (voir
// supabase/migrations/0017_customer_reschedule_cancel.sql), via pg_net —
// jamais depuis le frontend directement. Authentifiée par le même jeton
// partagé (Vault "webhook_secret") que les triggers de notification déjà en
// place (voir _shared, ou plutôt 0008_webhook_secret_vault.sql pour le
// mécanisme).
//
// L'e-mail client de confirmation d'ANNULATION existe déjà et se déclenche
// tout seul (trigger notify_customer_status_change, sur tout passage de
// status à CANCELLED, quel qu'en soit l'auteur) — cette fonction n'envoie
// donc un e-mail client que pour un DÉPLACEMENT. Pour l'admin, elle envoie
// systématiquement une alerte (e-mail + push), les deux événements n'ayant
// aucun autre canal de notification aujourd'hui (notify-admin-booking est
// volontairement INSERT-only).
//
// FIABILITÉ : le déplacement/l'annulation est déjà enregistré en base avant
// que ce webhook ne se déclenche — un échec ici ne peut jamais l'annuler.
// Toujours 200, erreurs journalisées uniquement.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const ADMIN_EMAIL = Deno.env.get('ADMIN_NOTIFICATION_EMAIL');
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const ADMIN_PANEL_URL = Deno.env.get('ADMIN_PANEL_URL') || 'https://hayeva.netlify.app/#espacePro';
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
function fmtDateTime(d: string, t: string): string {
  return `${fmtDate(d)} à ${(t || '').slice(0, 5)}`;
}

// Résout le nom/téléphone/e-mail/adresse du client d'une réservation — même
// logique (invité / particulier connecté / professionnel) que celle déjà
// écrite dans notify-admin-booking/index.ts, recopiée ici plutôt
// qu'extraite en module partagé pour rester cohérent avec le reste du
// projet (chaque fonction de notification a toujours porté sa propre copie
// de cette résolution).
async function resolveContact(supabase: ReturnType<typeof createClient>, booking: any) {
  let name = 'Client';
  let email = '';
  if (booking.guest_name) {
    name = booking.guest_name;
    email = booking.guest_email || '';
  } else if (booking.customer_user_id) {
    const [{ data: cp }, { data: prof }] = await Promise.all([
      supabase.from('customer_profiles').select('first_name,last_name').eq('user_id', booking.customer_user_id).maybeSingle(),
      supabase.from('profiles').select('email').eq('user_id', booking.customer_user_id).maybeSingle(),
    ]);
    if (cp) name = [cp.first_name, cp.last_name].filter(Boolean).join(' ') || name;
    if (prof) email = prof.email || '';
  } else if (booking.professional_account_id) {
    const { data: pa } = await supabase.from('professional_accounts').select('legal_name').eq('id', booking.professional_account_id).maybeSingle();
    if (pa) name = pa.legal_name || name;
  }
  return { name, email };
}

async function sendAdminAlert(subject: string, badgeLabel: string, bodyHtml: string, reference: string) {
  if (!RESEND_API_KEY || !ADMIN_EMAIL) {
    console.error('notify-booking-change: RESEND_API_KEY ou ADMIN_NOTIFICATION_EMAIL manquant — e-mail admin ignoré.');
    return;
  }
  const html = renderEmailShell(`
    <h2 style="margin:0 0 16px; font-size:20px; color:#101B24;">${escapeHtml(badgeLabel)}</h2>
    ${bodyHtml}
    <p style="margin:24px 0 0;">
      <a href="${ADMIN_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-weight:600;font-size:14px;">Voir le rendez-vous</a>
    </p>
  `, escapeHtml(reference || ''));
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: FROM_EMAIL, to: [ADMIN_EMAIL], subject, html }),
  });
  if (!res.ok) console.error('notify-booking-change: échec envoi Resend (admin)', res.status, await res.text());
}

// Push admin — même bloc que notify-admin-booking/index.ts (best-effort,
// jamais bloquant, désactive l'abonnement sur 404/410).
async function sendAdminPush(supabase: ReturnType<typeof createClient>, title: string, body: string, bookingId: string) {
  try {
    const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY');
    const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY');
    const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') || 'mailto:contact@hayeva.fr';
    if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) return;
    const { data: subs } = await supabase.from('admin_push_subscriptions').select('id, endpoint, p256dh, auth_key').eq('enabled', true);
    if (!subs || !subs.length) return;
    webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
    const hashIdx = ADMIN_PANEL_URL.indexOf('#');
    const panelBase = hashIdx === -1 ? ADMIN_PANEL_URL : ADMIN_PANEL_URL.slice(0, hashIdx);
    const panelHash = hashIdx === -1 ? 'espacePro' : ADMIN_PANEL_URL.slice(hashIdx + 1);
    const pushUrl = `${panelBase}?booking=${bookingId}#${panelHash}`;
    const payload = JSON.stringify({ title, body, bookingId, url: pushUrl });
    await Promise.all(subs.map(async (sub: { id: string; endpoint: string; p256dh: string; auth_key: string }) => {
      try {
        await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth_key } }, payload);
      } catch (pushErr: unknown) {
        const statusCode = (pushErr as { statusCode?: number })?.statusCode;
        console.error('notify-booking-change: échec envoi push', sub.id, statusCode);
        if (statusCode === 404 || statusCode === 410) {
          await supabase.from('admin_push_subscriptions').update({ enabled: false }).eq('id', sub.id);
        }
      }
    }));
  } catch (err) {
    console.error('notify-booking-change: bloc push — erreur inattendue', err);
  }
}

Deno.serve(async (req: Request) => {
  try {
    if (!WEBHOOK_SECRET || req.headers.get('authorization') !== `Bearer ${WEBHOOK_SECRET}`) {
      return new Response('unauthorized', { status: 401 });
    }
    const payload = await req.json();
    if (payload.event !== 'rescheduled' && payload.event !== 'cancelled_by_customer') {
      return new Response('ignored', { status: 200 });
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: booking } = await supabase.from('bookings').select('*, services(name)').eq('id', payload.booking_id).maybeSingle();
    if (!booking) return new Response('booking not found', { status: 200 });

    const contact = await resolveContact(supabase, booking);
    const serviceName = (booking.services && booking.services.name) || 'Intervention';

    if (payload.event === 'rescheduled') {
      const oldWhen = fmtDateTime(payload.old_date, payload.old_start_time);
      const newWhen = fmtDateTime(payload.new_date, payload.new_start_time);

      await sendAdminAlert(
        '🔁 Rendez-vous déplacé — HAYEVA',
        'Rendez-vous déplacé',
        `<p style="margin:0 0 18px; font-size:15px;">${escapeHtml(contact.name)} a déplacé son rendez-vous du <strong>${oldWhen}</strong> au <strong>${newWhen}</strong>.</p>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
          <tr><td style="padding:7px 0;color:#5B6B78;width:130px;">Client</td><td style="padding:7px 0;font-weight:600;text-align:right;">${escapeHtml(contact.name)}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Prestation</td><td style="padding:7px 0;text-align:right;">${escapeHtml(serviceName)}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Ancien créneau</td><td style="padding:7px 0;text-align:right;">${oldWhen}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Nouveau créneau</td><td style="padding:7px 0;text-align:right;font-weight:700;">${newWhen}</td></tr>
        </table>`,
        booking.reference
      );
      await sendAdminPush(supabase, '🔁 Rendez-vous déplacé', `${contact.name}\n${oldWhen} → ${newWhen}`, booking.id);

      if (contact.email) {
        const html = renderEmailShell(`
          <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour,</h2>
          <p style="margin:0 0 18px; font-size:15px;">Votre rendez-vous HAYEVA a bien été <strong>déplacé</strong>, comme demandé.</p>
          ${statusBadgeHtml('🔁 Déplacé', 'rescheduled')}
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
            <tr><td style="padding:7px 0;color:#5B6B78;width:150px;">Prestation</td><td style="padding:7px 0;font-weight:600;text-align:right;">${escapeHtml(serviceName)}</td></tr>
            <tr><td style="padding:7px 0;color:#5B6B78;">Ancien créneau</td><td style="padding:7px 0;text-align:right;">${oldWhen}</td></tr>
            <tr><td style="padding:10px 0 0;color:#101B24;font-weight:700;border-top:1px solid #E5E0D5;">Nouveau créneau</td><td style="padding:10px 0 0;font-weight:700;text-align:right;border-top:1px solid #E5E0D5;">${newWhen}</td></tr>
          </table>
          <p style="margin:22px 0 0;"><a href="${CLIENT_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-weight:600;font-size:14px;">Voir mon rendez-vous</a></p>
        `, escapeHtml(booking.reference || ''));
        if (RESEND_API_KEY) {
          const res = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ from: FROM_EMAIL, to: [contact.email], subject: 'Votre rendez-vous HAYEVA a été déplacé', html }),
          });
          if (!res.ok) console.error('notify-booking-change: échec envoi Resend (client)', res.status, await res.text());
        }
      }
    } else {
      // cancelled_by_customer : l'e-mail client existe déjà (trigger
      // notify_customer_status_change) — uniquement l'alerte admin ici.
      const when = fmtDateTime(payload.date, payload.start_time);
      await sendAdminAlert(
        '✖ Rendez-vous annulé par le client — HAYEVA',
        'Rendez-vous annulé',
        `<p style="margin:0 0 18px; font-size:15px;">${escapeHtml(contact.name)} a annulé son rendez-vous du <strong>${when}</strong>.</p>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
          <tr><td style="padding:7px 0;color:#5B6B78;width:130px;">Client</td><td style="padding:7px 0;font-weight:600;text-align:right;">${escapeHtml(contact.name)}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Prestation</td><td style="padding:7px 0;text-align:right;">${escapeHtml(serviceName)}</td></tr>
          <tr><td style="padding:7px 0;color:#5B6B78;">Créneau annulé</td><td style="padding:7px 0;text-align:right;">${when}</td></tr>
        </table>`,
        booking.reference
      );
      await sendAdminPush(supabase, '✖ Rendez-vous annulé', `${contact.name}\n${when}`, booking.id);
    }

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('notify-booking-change: erreur inattendue', err);
    return new Response('error handled', { status: 200 });
  }
});
