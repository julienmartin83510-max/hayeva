// Supabase Edge Function — rappels d'entretien des équipements
// (V2 phase 3 : J-30, J-7, échéance). Déclenchée chaque matin par pg_cron
// ('hayeva-maintenance-reminders', voir 0103_equipment_maintenance_reminders.sql)
// avec le secret partagé du Vault, ou manuellement par un admin connecté.
//
// claim_due_maintenance_reminders() réserve atomiquement les rappels dus
// (unique equipment_id + due_date + step : jamais deux fois le même rappel).

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

const EQUIPMENT_LABEL: Record<string, string> = {
  climatisation: 'climatisation', chaudiere_gaz: 'chaudière gaz', chaudiere_fioul: 'chaudière fioul',
  pac: 'pompe à chaleur', chauffe_eau: 'chauffe-eau', radiateur: 'chauffage', circulateur: 'circulateur',
};

function escapeHtml(s: string): string {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
}
function fmtDate(d: string): string {
  return new Date(d + 'T12:00:00Z').toLocaleDateString('fr-FR', { timeZone: 'Europe/Paris', day: '2-digit', month: 'long', year: 'numeric' });
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

    const { data: due, error: claimErr } = await supabase.rpc('claim_due_maintenance_reminders');
    if (claimErr) throw claimErr;

    const results: Array<{ id: string; status: string }> = [];
    for (const m of (due as Array<{ reminder_id: string; equipment_id: string; due_date: string; step: string }>) || []) {
      const finish = (fields: Record<string, unknown>) => supabase.from('maintenance_reminders').update(fields).eq('id', m.reminder_id);
      try {
        const { data: eq } = await supabase.from('customer_equipment')
          .select('id, equipment_type, brand, model, customer_user_id, client_id, maintenance_reminders_enabled')
          .eq('id', m.equipment_id).maybeSingle();
        if (!eq || !eq.maintenance_reminders_enabled) {
          await finish({ status: 'skipped', error_message: 'Rappels désactivés pour cet équipement.' });
          results.push({ id: m.reminder_id, status: 'skipped' });
          continue;
        }
        let email: string | null = null;
        let name = '';
        let hasAccount = false;
        if (eq.customer_user_id) {
          const [{ data: prof }, { data: cp }] = await Promise.all([
            supabase.from('profiles').select('email').eq('user_id', eq.customer_user_id).maybeSingle(),
            supabase.from('customer_profiles').select('first_name').eq('user_id', eq.customer_user_id).maybeSingle(),
          ]);
          email = prof?.email || null; name = cp?.first_name || ''; hasAccount = !!email;
        }
        if (!email && eq.client_id) {
          const { data: cl } = await supabase.from('clients').select('email, first_name').eq('id', eq.client_id).maybeSingle();
          email = cl?.email || null; name = name || cl?.first_name || '';
        }
        if (!email) {
          await finish({ status: 'skipped', error_message: 'Aucune adresse e-mail pour ce client.' });
          results.push({ id: m.reminder_id, status: 'skipped' });
          continue;
        }
        if (!RESEND_API_KEY) throw new Error('RESEND_API_KEY manquant.');

        const typeLabel = EQUIPMENT_LABEL[eq.equipment_type] || 'équipement';
        const model = [eq.brand, eq.model].filter(Boolean).join(' ');
        const intro = m.step === 'J0'
          ? `L'entretien de votre ${escapeHtml(typeLabel)} arrive à échéance (${fmtDate(m.due_date)}).`
          : `L'entretien de votre ${escapeHtml(typeLabel)} est à prévoir d'ici le <strong>${fmtDate(m.due_date)}</strong>.`;
        const bodyHtml = `
          <h2 style="margin:0 0 4px; font-size:20px; color:#101B24;">Bonjour ${escapeHtml(name)},</h2>
          <p style="margin:0 0 18px; font-size:15px;">${intro} Un entretien régulier préserve les performances et la durée de vie de votre installation.</p>
          ${statusBadgeHtml('🔧 Rappel d’entretien', 'received')}
          ${model ? `<p style="margin:0 0 6px;font-size:14px;"><strong>Équipement :</strong> ${escapeHtml(model)}</p>` : ''}
          <p style="margin:24px 0 0;"><a href="${SITE_URL}/#rdv" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:700;font-size:15px;">Prendre rendez-vous</a></p>
          <p style="margin:18px 0 0;font-size:13px;color:#5B6B78;">Vous pouvez aussi répondre à cet e-mail ou nous appeler au <strong>${PHONE}</strong>.${hasAccount ? ' Vos équipements sont visibles dans votre espace client.' : ''}</p>
          <p style="margin:12px 0 0;font-size:12px;color:#8A97A3;">Entretien déjà réalisé ? Ignorez simplement ce message.</p>`;

        const res = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json', 'Idempotency-Key': `maintenance_reminder:${m.reminder_id}` },
          body: JSON.stringify({ from: FROM_EMAIL, to: [email], reply_to: REPLY_TO_EMAIL, subject: `HAYEVA — L'entretien de votre ${typeLabel} approche`, html: renderEmailShell(bodyHtml) }),
        });
        if (!res.ok) throw new Error(`Resend ${res.status}: ${(await res.text()).slice(0, 300)}`);
        await finish({ status: 'sent', sent_at: new Date().toISOString(), recipient_email: email });
        results.push({ id: m.reminder_id, status: 'sent' });
      } catch (err) {
        console.error('process-maintenance-reminders: échec', m.reminder_id, err instanceof Error ? err.message : String(err));
        await finish({ status: 'failed', error_message: String(err instanceof Error ? err.message : err).slice(0, 400) });
        results.push({ id: m.reminder_id, status: 'failed' });
      }
    }
    return json({ ok: true, processed: results.length, results });
  } catch (err) {
    console.error('process-maintenance-reminders: erreur inattendue', err instanceof Error ? err.message : String(err));
    return json({ error: 'unexpected' }, 500);
  }
});
