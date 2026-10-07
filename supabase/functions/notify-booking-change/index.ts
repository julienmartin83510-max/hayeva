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
import { ADMIN_BOOKING_EMAIL, sendEmailOnce } from '../_shared/mail.ts';
import { escapeHtml, fmtDate, fmtTime, resolveBookingContact, rowHtml } from '../_shared/booking-contact.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET');
const ADMIN_PANEL_URL = Deno.env.get('ADMIN_PANEL_URL') || 'https://hayeva.fr/#espacePro';
const CLIENT_PANEL_URL = Deno.env.get('CLIENT_PANEL_URL') || 'https://hayeva.fr/#espaceClient';

function fmtDateTime(d: string, t: string): string {
  return `${fmtDate(d)} à ${fmtTime(t)}`;
}
const STATUS_LABELS: Record<string, string> = {
  PENDING: 'En attente de validation',
  CONFIRMED: 'Confirmé',
};

// E-mail admin (contact@hayeva.fr) — flux séparé de l'e-mail client.
function adminHtml(title: string, introHtml: string, rowsHtml: string, reference: string): string {
  return renderEmailShell(`
    <h2 style="margin:0 0 16px; font-size:20px; color:#101B24;">${escapeHtml(title)}</h2>
    <p style="margin:0 0 18px; font-size:15px;">${introHtml}</p>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">${rowsHtml}</table>
    <p style="margin:24px 0 0;">
      <a href="${ADMIN_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-weight:600;font-size:14px;">Voir le rendez-vous</a>
    </p>
  `, escapeHtml(reference || ''));
}

// Push admin — même bloc que notify-admin-booking/index.ts (best-effort,
// jamais bloquant, désactive l'abonnement sur 404/410).
// deno-lint-ignore no-explicit-any
async function sendAdminPush(supabase: any, title: string, body: string, bookingId: string) {
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

    const contact = await resolveBookingContact(supabase, booking);
    const serviceName = (booking.services && booking.services.name) || 'Intervention';
    const phoneHtml = contact.phone ? `<a href="tel:${escapeHtml(contact.phone.replace(/\s+/g, ''))}" style="color:#1AA6EE;">${escapeHtml(contact.phone)}</a>` : '';

    if (payload.event === 'rescheduled') {
      const oldWhen = fmtDateTime(payload.old_date, payload.old_start_time);
      const newWhen = fmtDateTime(payload.new_date, payload.new_start_time);
      const slotKey = `${payload.new_date}T${fmtTime(payload.new_start_time)}`;
      // Politique ACTUELLE conservée telle quelle (reschedule_own_booking) :
      // le statut ne change pas lors d'un déplacement — un RDV confirmé reste
      // confirmé (événement Apple mis à jour, même UID, sans doublon), une
      // demande en attente reste en attente de validation.
      const statusLabel = STATUS_LABELS[booking.status] || booking.status;

      // Déplacement fait par l'administrateur lui-même (HAYEVA Pro) : pas
      // d'e-mail admin à soi-même, uniquement l'e-mail au client.
      const byAdmin = payload.by === 'admin';
      const adminRes = byAdmin ? 'duplicate' : await sendEmailOnce(supabase, {
        dedupeKey: `admin_rescheduled:${booking.id}:${slotKey}`,
        bookingId: booking.id,
        emailType: 'admin_rescheduled',
        to: ADMIN_BOOKING_EMAIL,
        subject: 'Rendez-vous HAYEVA modifié',
        html: adminHtml('Rendez-vous modifié',
          `${escapeHtml(contact.name)} a déplacé son rendez-vous : <strong>${oldWhen}</strong> → <strong>${newWhen}</strong>.`,
          rowHtml('Client', escapeHtml(contact.name), true) +
          rowHtml('Téléphone', phoneHtml) +
          rowHtml('Prestation', escapeHtml(serviceName)) +
          rowHtml('Ancien créneau', `<s>${oldWhen}</s>`) +
          rowHtml('Nouveau créneau', newWhen, true) +
          rowHtml('Adresse', escapeHtml(contact.address)) +
          rowHtml('Statut', escapeHtml(statusLabel) + ' (inchangé)') +
          rowHtml('Référence', escapeHtml(booking.reference || '')),
          booking.reference),
      });
      if (adminRes !== 'duplicate') await sendAdminPush(supabase, 'Rendez-vous HAYEVA modifié', `${contact.name}\n${oldWhen} → ${newWhen}`, booking.id);

      if (contact.email) {
        const pendingNote = booking.status === 'PENDING'
          ? '<p style="margin:18px 0 0; font-size:14px;">Votre demande reste <strong>en attente de validation</strong> par HAYEVA. Vous recevrez un email dès qu\'elle sera confirmée.</p>'
          : '';
        const html = renderEmailShell(`
          <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(contact.firstName)},</h2>
          <p style="margin:0 0 18px; font-size:15px;">${byAdmin ? 'Votre rendez-vous HAYEVA a été <strong>déplacé</strong> par HAYEVA. Merci de nous contacter si ce nouveau créneau ne vous convient pas.' : 'Votre rendez-vous HAYEVA a bien été <strong>déplacé</strong>, comme demandé.'}</p>
          ${statusBadgeHtml('🔁 Déplacé', 'rescheduled')}
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
            <tr><td style="padding:7px 0;color:#5B6B78;width:150px;">Prestation</td><td style="padding:7px 0;font-weight:600;text-align:right;">${escapeHtml(serviceName)}</td></tr>
            <tr><td style="padding:7px 0;color:#5B6B78;">Ancien créneau</td><td style="padding:7px 0;text-align:right;">${oldWhen}</td></tr>
            <tr><td style="padding:10px 0 0;color:#101B24;font-weight:700;border-top:1px solid #E5E0D5;">Nouveau créneau</td><td style="padding:10px 0 0;font-weight:700;text-align:right;border-top:1px solid #E5E0D5;">${newWhen}</td></tr>
          </table>
          ${pendingNote}
          <p style="margin:22px 0 0;"><a href="${CLIENT_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-weight:600;font-size:14px;">Voir mon rendez-vous</a></p>
        `, escapeHtml(booking.reference || ''));
        await sendEmailOnce(supabase, {
          dedupeKey: `client_rescheduled:${booking.id}:${slotKey}`,
          bookingId: booking.id,
          emailType: 'rescheduled',
          to: contact.email,
          subject: 'Votre rendez-vous HAYEVA a été déplacé',
          html,
        });
      }
    } else {
      // cancelled_by_customer : l'e-mail de confirmation d'annulation au
      // CLIENT part séparément (trigger notify_customer_status_change) — ici
      // uniquement l'alerte admin.
      const when = fmtDateTime(payload.date, payload.start_time);
      const adminRes = await sendEmailOnce(supabase, {
        dedupeKey: `admin_cancelled:${booking.id}`,
        bookingId: booking.id,
        emailType: 'admin_cancelled',
        to: ADMIN_BOOKING_EMAIL,
        subject: '⚠️ Rendez-vous HAYEVA annulé',
        html: adminHtml('Rendez-vous annulé par le client',
          `${escapeHtml(contact.name)} a annulé son rendez-vous du <strong>${when}</strong>. Le créneau est libéré.`,
          rowHtml('Client', escapeHtml(contact.name), true) +
          rowHtml('Téléphone', phoneHtml) +
          rowHtml('Prestation', escapeHtml(serviceName)) +
          rowHtml('Date / heure annulées', when, true) +
          rowHtml('Adresse', escapeHtml(contact.address)) +
          rowHtml('Référence', escapeHtml(booking.reference || '')),
          booking.reference),
      });
      if (adminRes !== 'duplicate') await sendAdminPush(supabase, '⚠️ Rendez-vous HAYEVA annulé', `${contact.name}\n${when}`, booking.id);
    }

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('notify-booking-change: erreur inattendue', err);
    return new Response('error handled', { status: 200 });
  }
});
