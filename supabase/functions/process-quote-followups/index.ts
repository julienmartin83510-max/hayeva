// Supabase Edge Function — relances automatiques des devis envoyés
// (V2 phase 4 : J+3, J+7, J+14). Déclenchée par pg_cron
// ('hayeva-quote-followups', voir 0102_quote_followups.sql) avec le secret
// partagé du Vault, ou manuellement par un admin connecté.
//
// claim_due_quote_followups() réserve atomiquement les relances dues
// (contrainte unique quote_id + step : jamais deux fois la même relance).
// Juste avant l'envoi, le statut du devis est relu : un devis accepté,
// refusé, expiré ou dont les relances ont été coupées entre-temps n'est
// jamais relancé (ligne marquée 'skipped').

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CRON_SHARED_SECRET = Deno.env.get('CRON_SHARED_SECRET');
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const REPLY_TO_EMAIL = Deno.env.get('REPLY_TO_EMAIL') || 'contact@hayeva.fr';
const SITE_URL = Deno.env.get('PUBLIC_SITE_URL') || 'https://hayeva.fr';
const PHONE = '06 71 26 23 02';

// deno-lint-ignore no-explicit-any
type Sb = any;
type Recipient = { email: string; name: string; space: 'client' | 'pro' | 'none' };

function escapeHtml(s: string): string {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
}
function fmtEuros(cents: number | null | undefined): string {
  return ((cents || 0) / 100).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €';
}
function fmtDate(iso: string | null | undefined): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('fr-FR', { timeZone: 'Europe/Paris', day: '2-digit', month: '2-digit', year: 'numeric' });
}
function row(label: string, value: string, strong = false): string {
  return `<tr><td style="padding:7px 0;color:#5B6B78;width:150px;vertical-align:top;">${label}</td><td style="padding:7px 0;text-align:right;${strong ? 'font-weight:700;' : ''}">${value}</td></tr>`;
}
function button(href: string, label: string): string {
  return `<p style="margin:24px 0 0;"><a href="${href}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:700;font-size:15px;">${label}</a></p>`;
}

// Même résolution du destinataire que notify-document (e-mail du devis).
// deno-lint-ignore no-explicit-any
async function resolveRecipient(supabase: Sb, doc: any): Promise<Recipient | null> {
  if (doc.customer_user_id) {
    const [{ data: prof }, { data: cp }] = await Promise.all([
      supabase.from('profiles').select('email').eq('user_id', doc.customer_user_id).maybeSingle(),
      supabase.from('customer_profiles').select('first_name').eq('user_id', doc.customer_user_id).maybeSingle(),
    ]);
    if (prof?.email) return { email: prof.email, name: cp?.first_name || '', space: 'client' };
  }
  if (doc.professional_account_id) {
    const { data: pa } = await supabase.from('professional_accounts').select('legal_name, created_by').eq('id', doc.professional_account_id).maybeSingle();
    if (pa?.created_by) {
      const { data: prof } = await supabase.from('profiles').select('email').eq('user_id', pa.created_by).maybeSingle();
      if (prof?.email) return { email: prof.email, name: pa.legal_name || '', space: 'pro' };
    }
  }
  if (doc.client_id) {
    const { data: cl } = await supabase.from('clients').select('email, first_name, user_id').eq('id', doc.client_id).maybeSingle();
    if (cl?.email) return { email: cl.email, name: cl.first_name || '', space: cl.user_id ? 'client' : 'none' };
  }
  return null;
}

const INTRO: Record<number, string> = {
  3: 'Nous revenons vers vous au sujet du devis que nous vous avons transmis. Avez-vous pu en prendre connaissance ?',
  7: 'Votre devis HAYEVA est toujours disponible. Si vous avez la moindre question ou souhaitez ajuster une option, nous sommes à votre écoute.',
  14: 'Dernier petit rappel concernant votre devis HAYEVA. Sans retour de votre part, nous ne vous relancerons plus à son sujet.',
};

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

    const { data: due, error: claimErr } = await supabase.rpc('claim_due_quote_followups');
    if (claimErr) throw claimErr;

    const results: Array<{ id: string; status: string }> = [];
    for (const f of (due as Array<{ followup_id: string; quote_id: string; step: number }>) || []) {
      const finish = (fields: Record<string, unknown>) => supabase.from('quote_followups').update(fields).eq('id', f.followup_id);
      try {
        const { data: q } = await supabase.from('quotes')
          .select('id, reference, status, title, total_cents, sent_at, followups_enabled, customer_user_id, professional_account_id, client_id')
          .eq('id', f.quote_id).maybeSingle();
        if (!q || q.status !== 'SENT' || !q.followups_enabled) {
          await finish({ status: 'skipped', error_message: 'Devis plus en attente de réponse.' });
          results.push({ id: f.followup_id, status: 'skipped' });
          continue;
        }
        const recipient = await resolveRecipient(supabase, q);
        if (!recipient) {
          await finish({ status: 'skipped', error_message: 'Aucune adresse e-mail associée au devis.' });
          results.push({ id: f.followup_id, status: 'skipped' });
          continue;
        }
        if (!RESEND_API_KEY) throw new Error('RESEND_API_KEY manquant.');

        const { data: optRows } = await supabase.from('quote_options')
          .select('label, total_cents, sort_order').eq('quote_id', q.id).order('sort_order', { ascending: true });
        const options = (optRows as Array<{ label: string; total_cents: number }>) || [];
        const lines = options.length
          ? options.map((o) => row(escapeHtml(o.label || 'Option'), fmtEuros(o.total_cents))).join('')
          : row('Total', fmtEuros(q.total_cents), true);
        const reference = q.reference || '';
        const access = recipient.space === 'client'
          ? button(`${SITE_URL}/#espaceClient/devis`, 'Consulter mon devis')
          : recipient.space === 'pro'
            ? button(`${SITE_URL}/#espacePro`, 'Consulter le devis')
            : `<p style="margin:22px 0 0;font-size:14px;">Pour donner votre accord ou poser une question, répondez simplement à cet e-mail ou appelez-nous au <strong>${PHONE}</strong>.</p>`;
        const bodyHtml = `
          <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(recipient.name)},</h2>
          <p style="margin:0 0 18px; font-size:15px;">${INTRO[f.step] || INTRO[3]}</p>
          ${statusBadgeHtml('📄 Devis en attente de votre réponse', 'received')}
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
            ${row('Référence', escapeHtml(reference), true)}
            ${row('Envoyé le', fmtDate(q.sent_at))}
            ${q.title ? row('Objet', escapeHtml(q.title)) : ''}
            ${lines}
          </table>
          ${access}
          <p style="margin:18px 0 0;font-size:12px;color:#8A97A3;">Vous avez déjà répondu ou ne souhaitez pas donner suite ? Ignorez simplement ce message.</p>`;

        const res = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json', 'Idempotency-Key': `quote_followup:${f.followup_id}` },
          body: JSON.stringify({ from: FROM_EMAIL, to: [recipient.email], reply_to: REPLY_TO_EMAIL, subject: `Rappel : votre devis HAYEVA ${reference}`.trim(), html: renderEmailShell(bodyHtml, escapeHtml(reference)) }),
        });
        if (!res.ok) throw new Error(`Resend ${res.status}: ${(await res.text()).slice(0, 300)}`);
        await finish({ status: 'sent', sent_at: new Date().toISOString(), recipient_email: recipient.email });
        results.push({ id: f.followup_id, status: 'sent' });
      } catch (err) {
        console.error('process-quote-followups: échec', f.followup_id, err instanceof Error ? err.message : String(err));
        await finish({ status: 'failed', error_message: String(err instanceof Error ? err.message : err).slice(0, 400) });
        results.push({ id: f.followup_id, status: 'failed' });
      }
    }
    return json({ ok: true, processed: results.length, results });
  } catch (err) {
    console.error('process-quote-followups: erreur inattendue', err instanceof Error ? err.message : String(err));
    return json({ error: 'unexpected' }, 500);
  }
});
