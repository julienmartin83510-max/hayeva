// Supabase Edge Function — demande d'avis Google après intervention
// (V2 phase 17). Déclenchée chaque matin par pg_cron
// ('hayeva-review-requests', voir 0106_review_requests.sql) avec le secret
// partagé du Vault, ou manuellement par un admin connecté.
//
// Inactive tant que company_settings.google_review_url est vide. Une seule
// demande par rendez-vous terminé, au plus une par adresse e-mail sur 12 mois.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell } from '../_shared/email-template.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CRON_SHARED_SECRET = Deno.env.get('CRON_SHARED_SECRET');
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const REPLY_TO_EMAIL = Deno.env.get('REPLY_TO_EMAIL') || 'contact@hayeva.fr';

function escapeHtml(s: string): string {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
}

const corsHeaders = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type, x-cron-secret' };

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

    const { data: company } = await supabase.from('company_settings').select('google_review_url').eq('id', 1).maybeSingle();
    const reviewUrl = String(company?.google_review_url || '').trim();
    if (!/^https:\/\//i.test(reviewUrl)) return json({ ok: true, processed: 0, inactive: true });

    const { data: due, error: claimErr } = await supabase.rpc('claim_due_review_requests');
    if (claimErr) throw claimErr;

    const results: Array<{ id: string; status: string }> = [];
    for (const r of (due as Array<{ request_id: string; booking_id: string }>) || []) {
      const finish = (fields: Record<string, unknown>) => supabase.from('review_requests').update(fields).eq('id', r.request_id);
      try {
        const { data: b } = await supabase.from('bookings')
          .select('id, reference, status, guest_name, guest_email, customer_user_id, client_id').eq('id', r.booking_id).maybeSingle();
        if (!b || b.status !== 'COMPLETED') { await finish({ status: 'skipped', error_message: 'Rendez-vous non terminé.' }); results.push({ id: r.request_id, status: 'skipped' }); continue; }
        let email = '';
        let name = '';
        if (b.guest_email) {
          email = b.guest_email; name = String(b.guest_name || '').trim().split(/\s+/)[0] || '';
        } else if (b.customer_user_id) {
          const [{ data: prof }, { data: cp }] = await Promise.all([
            supabase.from('profiles').select('email').eq('user_id', b.customer_user_id).maybeSingle(),
            supabase.from('customer_profiles').select('first_name').eq('user_id', b.customer_user_id).maybeSingle(),
          ]);
          email = prof?.email || ''; name = cp?.first_name || '';
        }
        if (!email && b.client_id) {
          const { data: cl } = await supabase.from('clients').select('email, first_name').eq('id', b.client_id).maybeSingle();
          email = cl?.email || ''; name = name || cl?.first_name || '';
        }
        if (!email) { await finish({ status: 'skipped', error_message: 'Aucune adresse e-mail.' }); results.push({ id: r.request_id, status: 'skipped' }); continue; }

        const since = new Date(Date.now() - 365 * 86400000).toISOString();
        const { count } = await supabase.from('review_requests').select('id', { count: 'exact', head: true })
          .ilike('recipient_email', email).eq('status', 'sent').gte('sent_at', since);
        if ((count || 0) > 0) { await finish({ status: 'skipped', recipient_email: email, error_message: 'Avis déjà demandé dans les 12 derniers mois.' }); results.push({ id: r.request_id, status: 'skipped' }); continue; }
        if (!RESEND_API_KEY) throw new Error('RESEND_API_KEY manquant.');

        const bodyHtml = `
          <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(name)},</h2>
          <p style="margin:0 0 14px; font-size:15px;">Merci d'avoir fait appel à HAYEVA. Votre avis nous aide énormément et permet à d'autres habitants du secteur de nous trouver.</p>
          <p style="margin:0 0 6px; font-size:15px;">Auriez-vous une minute pour partager votre expérience ?</p>
          <p style="margin:24px 0 0;"><a href="${escapeHtml(reviewUrl)}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:700;font-size:15px;">Laisser un avis Google</a></p>
          <p style="margin:18px 0 0;font-size:13px;color:#5B6B78;">Un souci avec l'intervention ? Répondez simplement à cet e-mail : nous revenons vers vous rapidement.</p>`;
        const res = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json', 'Idempotency-Key': `review_request:${r.request_id}` },
          body: JSON.stringify({ from: FROM_EMAIL, to: [email], reply_to: REPLY_TO_EMAIL, subject: 'Votre avis sur HAYEVA', html: renderEmailShell(bodyHtml, escapeHtml(b.reference || '')) }),
        });
        if (!res.ok) throw new Error(`Resend ${res.status}: ${(await res.text()).slice(0, 300)}`);
        await finish({ status: 'sent', sent_at: new Date().toISOString(), recipient_email: email });
        results.push({ id: r.request_id, status: 'sent' });
      } catch (err) {
        console.error('process-review-requests: échec', r.request_id, err instanceof Error ? err.message : String(err));
        await finish({ status: 'failed', error_message: String(err instanceof Error ? err.message : err).slice(0, 400) });
        results.push({ id: r.request_id, status: 'failed' });
      }
    }
    return json({ ok: true, processed: results.length, results });
  } catch (err) {
    console.error('process-review-requests: erreur inattendue', err instanceof Error ? err.message : String(err));
    return json({ error: 'unexpected' }, 500);
  }
});
