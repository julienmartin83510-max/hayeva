// Supabase Edge Function — envoie en Web Push (iPhone/iPad/ordinateur,
// HAYEVA Pro) une notification administrateur enregistrée dans
// admin_notifications (devis accepté, paiement, stock faible, rappel
// d'intervention…). Appelée uniquement par le trigger SQL
// trg_admin_notifications_dispatch (pg_net + WEBHOOK_SECRET).
// Idempotente : une notification déjà envoyée (pushed_at) n'est jamais
// renvoyée. VAPID_PRIVATE_KEY reste un secret serveur.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET');

Deno.serve(async (req: Request) => {
  try {
    if (!WEBHOOK_SECRET || req.headers.get('authorization') !== `Bearer ${WEBHOOK_SECRET}`) {
      return new Response('unauthorized', { status: 401 });
    }
    const { notification_id } = await req.json();
    if (!notification_id) return new Response('ignored', { status: 200 });
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // Réservation atomique de l'envoi : seul le premier appel passe.
    const { data: n } = await supabase
      .from('admin_notifications')
      .update({ pushed_at: new Date().toISOString() })
      .eq('id', notification_id)
      .is('pushed_at', null)
      .eq('push', true)
      .select('id, title, body, url, booking_id')
      .maybeSingle();
    if (!n) return new Response('already sent', { status: 200 });

    const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY');
    const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY');
    const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') || 'mailto:contact@hayeva.fr';
    if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) return new Response('no vapid', { status: 200 });

    const { data: subs } = await supabase.from('admin_push_subscriptions').select('id, endpoint, p256dh, auth_key').eq('enabled', true);
    if (!subs || !subs.length) return new Response('no subscription', { status: 200 });
    webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
    const payload = JSON.stringify({ title: n.title, body: n.body || '', bookingId: n.booking_id || undefined, url: n.url || './?app=pro#espacePro' });
    await Promise.all(subs.map(async (sub: { id: string; endpoint: string; p256dh: string; auth_key: string }) => {
      try {
        await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth_key } }, payload);
      } catch (err: unknown) {
        const statusCode = (err as { statusCode?: number })?.statusCode;
        console.error('admin-push: échec envoi', sub.id, statusCode);
        if (statusCode === 404 || statusCode === 410) {
          await supabase.from('admin_push_subscriptions').update({ enabled: false }).eq('id', sub.id);
        }
      }
    }));
    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('admin-push: erreur inattendue', err);
    return new Response('error handled', { status: 200 });
  }
});
