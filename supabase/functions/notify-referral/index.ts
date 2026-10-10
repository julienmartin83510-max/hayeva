// Supabase Edge Function — e-mails du programme de parrainage :
// recommandation enregistrée, récompense validée, règlement effectué.
// Déclenchée par le trigger referral_email_on_notification (0134, pg_net +
// secret de webhook). Contenu construit à partir de referral_email_context()
// (données serveur, aucune donnée du client recommandé). Anti-doublon :
// referral_emails.notification_id (une seule fois par notification, sauf échec).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell } from '../_shared/email-template.ts';
import { buildReferralEmail } from '../_shared/referral-email.mjs';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET');
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const REPLY_TO_EMAIL = Deno.env.get('REPLY_TO_EMAIL') || 'contact@hayeva.fr';
const SITE_URL = Deno.env.get('PUBLIC_SITE_URL') || 'https://hayeva.fr';

Deno.serve(async (req: Request) => {
  try {
    if (!WEBHOOK_SECRET || req.headers.get('authorization') !== `Bearer ${WEBHOOK_SECRET}`) {
      return new Response('unauthorized', { status: 401 });
    }
    const payload = await req.json().catch(() => ({}));
    const id = typeof payload?.notification_id === 'string' ? payload.notification_id : '';
    if (!/^[0-9a-f-]{36}$/i.test(id)) return new Response('ignored', { status: 200 });

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: ctx, error: ctxErr } = await supabase.rpc('referral_email_context', { p_notification_id: id });
    if (ctxErr) { console.error('notify-referral: contexte illisible', ctxErr.message); return new Response('error handled', { status: 200 }); }
    if (!ctx) return new Response('ignored kind', { status: 200 });

    const { data: inserted, error: insErr } = await supabase.from('referral_emails')
      .insert({ notification_id: id, kind: ctx.kind, recipient_email: ctx.recipient_email || null, status: 'pending' })
      .select('id').maybeSingle();
    let logId = inserted?.id || null;
    if (!logId) {
      if (insErr && insErr.code !== '23505') { console.error('notify-referral: journalisation impossible', insErr.message); return new Response('error handled', { status: 200 }); }
      const { data: retry } = await supabase.from('referral_emails')
        .update({ status: 'pending', error_message: null, recipient_email: ctx.recipient_email || null })
        .eq('notification_id', id).eq('status', 'failed').select('id').maybeSingle();
      if (!retry) return new Response('duplicate', { status: 200 });
      logId = retry.id;
    }
    const finish = (fields: Record<string, unknown>) => supabase.from('referral_emails').update(fields).eq('id', logId);

    const mail = buildReferralEmail(ctx, SITE_URL);
    if (!mail) { await finish({ status: 'skipped', error_message: 'Aucun destinataire ou situation non confirmée.' }); return new Response('skipped', { status: 200 }); }
    if (!RESEND_API_KEY) { await finish({ status: 'failed', error_message: 'RESEND_API_KEY manquant.' }); return new Response('error handled', { status: 200 }); }

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json', 'Idempotency-Key': `referral-notification:${id}` },
      body: JSON.stringify({ from: FROM_EMAIL, to: [ctx.recipient_email], reply_to: REPLY_TO_EMAIL, subject: mail.subject, html: renderEmailShell(mail.html, mail.reference) }),
    });
    if (!res.ok) {
      const t = await res.text();
      console.error('notify-referral: échec Resend', res.status);
      await finish({ status: 'failed', error_message: `Resend ${res.status}: ${t.slice(0, 400)}` });
      return new Response('error handled', { status: 200 });
    }
    await finish({ status: 'sent', sent_at: new Date().toISOString() });
    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('notify-referral: erreur inattendue', err instanceof Error ? err.message : String(err));
    return new Response('error handled', { status: 200 });
  }
});
