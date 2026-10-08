// Supabase Edge Function — traite les rappels d'entretien dus
// (reminder_jobs.status='pending' et scheduled_for <= aujourd'hui).
//
// DÉCLENCHEMENT : pg_cron (job 'hayeva-reminder-cycle', toutes les 15 min —
// voir 0053_reminder_scheduler.sql), via net.http_post authentifié par un
// secret partagé (jamais un JWT utilisateur : aucun admin n'est connecté
// quand le cron se déclenche). Peut aussi être appelée manuellement depuis
// l'admin ("Envoyer maintenant").
//
// IDEMPOTENCE : chaque job est d'abord marqué 'processing' par une UPDATE
// conditionnelle (WHERE status='pending') avant tout envoi — si deux
// exécutions se chevauchaient (ne devrait jamais arriver avec pg_cron,
// mais en cas d'appel manuel concurrent), un seul des deux appels peut
// gagner la course sur une ligne donnée, l'autre la trouve déjà en
// 'processing' et l'ignore. Un job 'sent' n'est jamais retraité.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';
import { sendReminderSMS } from '../_shared/sms.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const CRON_SHARED_SECRET = Deno.env.get('CRON_SHARED_SECRET');

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
}

const ENERGY_LABEL: Record<string, string> = { gaz: 'chaudière gaz', fioul: 'chaudière fioul' };

const corsHeaders = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type, x-cron-secret' };

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    // Authentification : secret partagé (cron) OU admin connecté (bouton
    // "Envoyer maintenant" côté admin) — jamais l'un sans l'autre.
    const cronSecret = req.headers.get('x-cron-secret');
    const authHeader = req.headers.get('authorization') || '';
    const jwt = authHeader.replace(/^Bearer\s+/i, '');
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    let authorized = false;
    if (CRON_SHARED_SECRET && cronSecret === CRON_SHARED_SECRET) authorized = true;
    if (!authorized && jwt) {
      const { data: userRes } = await supabase.auth.getUser(jwt);
      if (userRes?.user) {
        const { data: profile } = await supabase.from('profiles').select('global_role').eq('user_id', userRes.user.id).maybeSingle();
        if (profile?.global_role === 'admin') authorized = true;
      }
    }
    if (!authorized) return json({ error: 'unauthorized' }, 401);

    const { data: dueJobs, error: dueErr } = await supabase
      .from('reminder_jobs')
      .select('id')
      .eq('status', 'pending')
      .lte('scheduled_for', new Date().toISOString().slice(0, 10))
      .limit(100);
    if (dueErr) throw dueErr;

    const results: Array<{ id: string; status: string }> = [];

    for (const row of dueJobs || []) {
      // Claim atomique : seule une ligne encore 'pending' passe à
      // 'processing' — la condition .eq('status','pending') dans l'UPDATE
      // est ce qui empêche un double traitement.
      const { data: claimed } = await supabase
        .from('reminder_jobs').update({ status: 'processing', updated_at: new Date().toISOString() })
        .eq('id', row.id).eq('status', 'pending').select('*').maybeSingle();
      if (!claimed) { results.push({ id: row.id, status: 'skipped_already_claimed' }); continue; }

      try {
        const { data: job } = await supabase
          .from('reminder_jobs')
          .select(`
            id, reminder_type, scheduled_for, customer_user_id, channel,
            service_contracts(energy_type, end_date, customer_equipment(brand, model)),
            customer_equipment(brand, model)
          `)
          .eq('id', claimed.id).maybeSingle();
        if (!job) throw new Error('job_not_found_after_claim');

        const { data: prof } = await supabase.from('profiles').select('email').eq('user_id', job.customer_user_id).maybeSingle();
        const { data: cp } = await supabase.from('customer_profiles').select('first_name,last_name,phone').eq('user_id', job.customer_user_id).maybeSingle();
        const contactEmail = prof?.email;
        const contactName = cp ? [cp.first_name, cp.last_name].filter(Boolean).join(' ') : 'Client';

        const contract = (job as any).service_contracts;
        const equip = contract?.customer_equipment || (job as any).customer_equipment;
        const equipLabel = [equip?.brand, equip?.model].filter(Boolean).join(' ') || (contract ? ENERGY_LABEL[contract.energy_type] : 'votre équipement');
        const equipmentTypeLabel = contract ? ENERGY_LABEL[contract.energy_type] : 'votre équipement';

        if ((job as any).channel === 'sms') {
          if (!cp?.phone) throw new Error('no_contact_phone');
          const smsMessage = `HAYEVA : votre entretien ${equipmentTypeLabel} approche. Prenez rendez-vous sur https://hayeva.fr/#rdv`;
          const smsRes = await sendReminderSMS(cp.phone, smsMessage);
          if (!smsRes.ok) throw new Error(smsRes.reason);
          await supabase.from('reminder_jobs').update({
            status: 'sent', sent_at: new Date().toISOString(), result: `sms_sent_${smsRes.provider}`, updated_at: new Date().toISOString(),
          }).eq('id', claimed.id);
          results.push({ id: claimed.id, status: 'sent' });
          continue;
        }

        if (!contactEmail) throw new Error('no_contact_email');
        if (!RESEND_API_KEY) throw new Error('missing_resend_key');

        const bodyHtml = `
          ${statusBadgeHtml('Rappel d’entretien', 'received')}
          <h2 style="color:#101B24;margin:0 0 14px;">Bonjour ${escapeHtml(contactName)},</h2>
          <p>Votre entretien ${escapeHtml(equipmentTypeLabel)} arrive prochainement à échéance${contract?.end_date ? ` (échéance de votre contrat : ${escapeHtml(new Date(contract.end_date).toLocaleDateString('fr-FR'))})` : ''}.</p>
          <p><strong>Équipement :</strong> ${escapeHtml(equipLabel)}</p>
          <p>Vous pouvez réserver votre prochain rendez-vous directement depuis votre espace HAYEVA.</p>
          <p style="margin-top:20px;"><a href="https://hayeva.fr/#rdv" style="background:#E85A12;color:#fff;padding:12px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Prendre rendez-vous</a></p>
          <p style="margin-top:24px;color:#5B6B78;font-size:13px;">HAYEVA — Climatisation • Chauffage • Plomberie</p>
        `;
        const html = renderEmailShell(bodyHtml);

        const emailRes = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ from: FROM_EMAIL, to: [contactEmail], subject: 'HAYEVA — Votre entretien approche', html }),
        });
        if (!emailRes.ok) throw new Error(`resend_failed_${emailRes.status}`);

        await supabase.from('reminder_jobs').update({
          status: 'sent', sent_at: new Date().toISOString(), result: 'email_sent', updated_at: new Date().toISOString(),
        }).eq('id', claimed.id);
        results.push({ id: claimed.id, status: 'sent' });
      } catch (jobErr) {
        console.error('process-reminders: échec job', claimed.id, jobErr);
        await supabase.from('reminder_jobs').update({
          status: 'failed', error: String(jobErr instanceof Error ? jobErr.message : jobErr), updated_at: new Date().toISOString(),
        }).eq('id', claimed.id);
        results.push({ id: claimed.id, status: 'failed' });
      }
    }

    return json({ ok: true, processed: results.length, results });
  } catch (err) {
    console.error('process-reminders: erreur inattendue', err);
    return json({ error: 'unexpected', detail: String(err instanceof Error ? err.message : err) }, 500);
  }
});
