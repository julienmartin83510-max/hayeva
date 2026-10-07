// Supabase Edge Function — e-mail au client quand un DEVIS est envoyé
// (quotes.status → SENT) ou qu'une FACTURE est émise (invoices.status →
// ISSUED). Déclenchée par le trigger notify_document_email (0101, pg_net +
// secret de webhook). Anti-doublon : document_emails.dedupe_key.
//
// Aucune donnée confidentielle superflue : référence, date, prestations,
// montant. Le document complet reste consultable uniquement dans l'espace
// client / pro, derrière la connexion (jamais de lien public permanent).
// Un client sans compte reçoit le récapitulatif et les coordonnées HAYEVA.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET');
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const REPLY_TO_EMAIL = Deno.env.get('REPLY_TO_EMAIL') || 'contact@hayeva.fr';
const SITE_URL = Deno.env.get('PUBLIC_SITE_URL') || 'https://hayeva.fr';
const PHONE = '06 71 26 23 02';

// deno-lint-ignore no-explicit-any
type Sb = any;

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

type Recipient = { email: string; name: string; space: 'client' | 'pro' | 'none' };

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
    const { data: cl } = await supabase.from('clients').select('email, first_name, last_name, user_id, merged_into').eq('id', doc.client_id).maybeSingle();
    if (cl?.email) return { email: cl.email, name: cl.first_name || '', space: cl.user_id ? 'client' : 'none' };
  }
  return null;
}

function accessBlock(r: Recipient, kind: 'quote' | 'invoice'): string {
  if (r.space === 'client') {
    return button(`${SITE_URL}/#espaceClient/${kind === 'quote' ? 'devis' : 'factures'}`, kind === 'quote' ? 'Consulter mon devis' : 'Consulter ma facture')
      + `<p style="margin:10px 0 0;font-size:12px;color:#8A97A3;">Accès sécurisé : connexion à votre espace client HAYEVA requise.</p>`;
  }
  if (r.space === 'pro') {
    return button(`${SITE_URL}/#espacePro`, kind === 'quote' ? 'Consulter le devis' : 'Consulter la facture')
      + `<p style="margin:10px 0 0;font-size:12px;color:#8A97A3;">Accès sécurisé : connexion à votre espace professionnel HAYEVA requise.</p>`;
  }
  return `<p style="margin:22px 0 0;font-size:14px;">Pour toute question${kind === 'quote' ? ' ou pour donner votre accord' : ''}, répondez simplement à cet e-mail ou appelez-nous au <strong>${PHONE}</strong>.</p>`;
}

Deno.serve(async (req: Request) => {
  try {
    if (!WEBHOOK_SECRET || req.headers.get('authorization') !== `Bearer ${WEBHOOK_SECRET}`) {
      return new Response('unauthorized', { status: 401 });
    }
    const payload = await req.json().catch(() => ({}));
    const type = payload?.type;
    const id = typeof payload?.id === 'string' ? payload.id : '';
    if ((type !== 'quote' && type !== 'invoice') || !/^[0-9a-f-]{36}$/i.test(id)) return new Response('ignored', { status: 200 });

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    let subject = '';
    let bodyHtml = '';
    let reference = '';
    let recipient: Recipient | null = null;
    const emailType = type === 'quote' ? 'quote_sent' : 'invoice_issued';
    const dedupeKey = `${emailType}:${id}`;

    if (type === 'quote') {
      // Deux lectures séparées : quotes ↔ quote_options a deux clés
      // étrangères (quote_id et selected_option_id), une jointure imbriquée
      // serait ambiguë.
      const { data: q, error: qErr } = await supabase.from('quotes')
        .select('id, reference, status, title, total_cents, created_at, sent_at, customer_user_id, professional_account_id, client_id')
        .eq('id', id).maybeSingle();
      if (qErr) console.error('notify-document: lecture du devis impossible', qErr.message);
      if (!q || q.status !== 'SENT') return new Response('ignored status', { status: 200 });
      const { data: optRows } = await supabase.from('quote_options')
        .select('label, total_cents, sort_order').eq('quote_id', id).order('sort_order', { ascending: true });
      recipient = await resolveRecipient(supabase, q);
      reference = q.reference || '';
      const options = (optRows as Array<{ label: string; total_cents: number; sort_order: number }>) || [];
      const lines = options.length
        ? options.map((o) => row(escapeHtml(o.label || 'Option'), fmtEuros(o.total_cents))).join('')
        : row('Total', fmtEuros(q.total_cents), true);
      subject = `Votre devis HAYEVA ${reference}`.trim();
      bodyHtml = `
        <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(recipient?.name || '')},</h2>
        <p style="margin:0 0 18px; font-size:15px;">Votre devis HAYEVA est disponible${options.length > 1 ? ` : il comporte <strong>${options.length} options</strong>, à vous de choisir celle qui vous convient` : ''}.</p>
        ${statusBadgeHtml('📄 Devis envoyé', 'received')}
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
          ${row('Référence', escapeHtml(reference), true)}
          ${row('Date', fmtDate(q.sent_at || q.created_at))}
          ${q.title ? row('Objet', escapeHtml(q.title)) : ''}
          ${lines}
        </table>
        ${recipient ? accessBlock(recipient, 'quote') : ''}`;
    } else {
      const { data: inv, error: invErr } = await supabase.from('invoices')
        .select('id, reference, status, total_cents, created_at, customer_user_id, professional_account_id, client_id')
        .eq('id', id).maybeSingle();
      if (invErr) console.error('notify-document: lecture de la facture impossible', invErr.message);
      if (!inv || inv.status !== 'ISSUED') return new Response('ignored status', { status: 200 });
      recipient = await resolveRecipient(supabase, inv);
      reference = inv.reference || '';
      subject = `Votre facture HAYEVA ${reference}`.trim();
      bodyHtml = `
        <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(recipient?.name || '')},</h2>
        <p style="margin:0 0 18px; font-size:15px;">Votre facture HAYEVA a été émise. Merci pour votre confiance.</p>
        ${statusBadgeHtml('🧾 Facture émise', 'confirmed')}
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
          ${row('Référence', escapeHtml(reference), true)}
          ${row('Date', fmtDate(inv.created_at))}
          ${row('Montant', fmtEuros(inv.total_cents), true)}
        </table>
        ${recipient ? accessBlock(recipient, 'invoice') : ''}`;
    }

    // Journal + anti-doublon (une seule fois par document, sauf échec précédent).
    const { data: inserted, error: insErr } = await supabase.from('document_emails')
      .insert({ doc_type: type, doc_id: id, email_type: emailType, status: 'pending', recipient_email: recipient?.email || null, dedupe_key: dedupeKey })
      .select('id').maybeSingle();
    let logId = inserted?.id || null;
    if (!logId) {
      if (insErr && insErr.code !== '23505') { console.error('notify-document: journalisation impossible', insErr.message); return new Response('error handled', { status: 200 }); }
      const { data: retry } = await supabase.from('document_emails')
        .update({ status: 'pending', error_message: null, recipient_email: recipient?.email || null })
        .eq('dedupe_key', dedupeKey).eq('status', 'failed').select('id').maybeSingle();
      if (!retry) return new Response('duplicate', { status: 200 });
      logId = retry.id;
    }
    const finish = (fields: Record<string, unknown>) => supabase.from('document_emails').update(fields).eq('id', logId);

    if (!recipient) { await finish({ status: 'skipped', error_message: 'Aucune adresse e-mail associée au document.' }); return new Response('no recipient', { status: 200 }); }
    if (!RESEND_API_KEY) { await finish({ status: 'failed', error_message: 'RESEND_API_KEY manquant.' }); return new Response('error handled', { status: 200 }); }

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json', 'Idempotency-Key': dedupeKey },
      body: JSON.stringify({ from: FROM_EMAIL, to: [recipient.email], reply_to: REPLY_TO_EMAIL, subject, html: renderEmailShell(bodyHtml, escapeHtml(reference)) }),
    });
    if (!res.ok) {
      const t = await res.text();
      console.error('notify-document: échec Resend', res.status);
      await finish({ status: 'failed', error_message: `Resend ${res.status}: ${t.slice(0, 400)}` });
      return new Response('error handled', { status: 200 });
    }
    await finish({ status: 'sent', sent_at: new Date().toISOString() });
    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('notify-document: erreur inattendue', err instanceof Error ? err.message : String(err));
    return new Response('error handled', { status: 200 });
  }
});
