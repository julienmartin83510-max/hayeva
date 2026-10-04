// Supabase Edge Function — envoie au client le compte rendu HAYEVA d'une
// intervention déjà finalisée (report_status='FINALIZED'), après validation
// et signatures côté admin (module Fiche d'intervention, 0044_intervention_
// reports.sql).
//
// DÉCLENCHEMENT : appelée par le frontend admin juste après avoir marqué la
// fiche FINALIZED et le rendez-vous COMPLETED (voir admIvFinalize/
// admIvSendReportEmail, index.html) — jamais l'inverse : le compte rendu est
// déjà enregistré en base avant cet appel, un échec d'envoi ne perd donc
// jamais le rapport (voir email_status ci-dessous, géré indépendamment).
//
// SÉCURITÉ : même patron que propose-alternative-slot — jeton de session
// admin revérifié côté serveur (global_role='admin'), aucun secret exposé au
// frontend, réutilise le même compte Resend (RESEND_API_KEY/RESEND_FROM_EMAIL)
// et le même gabarit visuel partagé (_shared/email-template.ts) que le reste
// des e-mails HAYEVA — pas un second système d'envoi.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const REPLY_TO_EMAIL = Deno.env.get('REPLY_TO_EMAIL') || 'contact@hayeva.fr';

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string
  ));
}

const ITEM_STATUS_LABEL: Record<string, string> = {
  OK: 'OK', FUNCTIONAL: 'OK', WATCH: 'À surveiller', ANOMALY: 'Anomalie',
  INTERVENTION_RECOMMENDED: 'Anomalie', NOT_APPLICABLE: 'N/A',
};

const COMPLETION_STATUS_LABEL: Record<string, string> = {
  CONFORME: 'Fonctionnement normal après essais',
  SURVEILLANCE: 'Fonctionnement avec réserves',
  PROVISOIRE: 'Intervention provisoire',
  PIECE_A_COMMANDER: 'Pièce à commander',
  DEVIS_COMPLEMENTAIRE: 'Devis complémentaire nécessaire',
  NOUVELLE_INTERVENTION: 'Intervention complémentaire nécessaire',
  MISE_EN_SECURITE: "Appareil laissé à l'arrêt",
  ESSAIS_IMPOSSIBLES: 'Impossible de réaliser les essais',
};

// Section 3 du cahier des charges diagnostic/réserves : distincte de
// intervention_anomalies (liste libre détaillée) — réponse de synthèse
// obligatoire sur chaque fiche de dépannage (voir admIvFinalize, index.html).
const RESERVES_STATUS_LABEL: Record<string, string> = {
  AUCUNE: 'Aucune autre anomalie constatée lors des contrôles réalisés',
  AUTRE_ANOMALIE: 'Autre anomalie constatée',
  RISQUE_OU_ANOMALIE: 'Installation présentant un risque ou une anomalie nécessitant une intervention complémentaire',
  DIAGNOSTIC_PARTIEL: 'Contrôle limité / diagnostic partiel',
};

// Mention automatique obligatoire (section 4) — identique à IV_LEGAL_SCOPE_
// MENTION côté frontend (index.html) : ne supprime et ne restreint JAMAIS
// les garanties légales ou la responsabilité de HAYEVA lorsqu'applicables.
const LEGAL_SCOPE_MENTION = "L'intervention et le diagnostic portent exclusivement sur le défaut constaté et les contrôles réalisés lors de la présente intervention. À l'issue de l'intervention, l'état de fonctionnement de l'équipement est indiqué dans le présent compte rendu. Toute panne ultérieure provenant d'un autre composant, d'une autre anomalie ou d'une cause indépendante de la présente intervention nécessitera un nouveau diagnostic et pourra faire l'objet d'une nouvelle intervention et d'un nouveau devis. Les éventuelles réserves ou anomalies constatées mais non traitées sont expressément mentionnées sur le présent compte rendu. Cette mention ne supprime ni ne restreint les garanties légales applicables ni la responsabilité de HAYEVA.";

const ANOMALY_SEVERITY_LABEL: Record<string, string> = {
  INFO: 'Information', WATCH: 'À surveiller', RECOMMENDED: 'Intervention recommandée', SAFETY: 'Sécurité',
};

// Valeur affichée pour un contrôle donné, selon son field_type — un contrôle
// 'status' garde le libellé OK/À surveiller/Anomalie historique, tout autre
// type (text/number/boolean/select/textarea) affiche sa valeur saisie telle
// quelle (avec l'unité éventuelle), jamais un statut qui n'a pas de sens
// pour lui (voir DIAGNOSTIC_TEMPLATES côté frontend, section 8 du cahier
// des charges HAYEVA).
function itemDisplayValue(it: { field_type?: string; status?: string; measured_value?: string; field_meta?: any }): string {
  const ft = it.field_type || 'status';
  if (ft === 'status') return ITEM_STATUS_LABEL[it.status || ''] || it.status || '—';
  const unit = it.field_meta?.unit;
  const val = it.measured_value;
  if (!val) return '—';
  return unit ? `${val} ${unit}` : val;
}

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const authHeader = req.headers.get('authorization') || '';
    const jwt = authHeader.replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ error: 'unauthorized' }, 401);

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: userRes, error: userErr } = await supabase.auth.getUser(jwt);
    if (userErr || !userRes?.user) return json({ error: 'unauthorized' }, 401);

    const { data: profile } = await supabase
      .from('profiles').select('global_role').eq('user_id', userRes.user.id).maybeSingle();
    if (!profile || profile.global_role !== 'admin') return json({ error: 'forbidden' }, 403);

    const body = await req.json();
    const interventionId = body.intervention_id;
    if (!interventionId) return json({ error: 'missing_intervention_id' }, 400);

    const { data: iv } = await supabase
      .from('interventions')
      .select(`
        id, report_status, report_number, email_status, observations, recommendations, ended_at, completion_status, auto_summary,
        reserves_status, reserves_detail,
        client_signature_name, technician_signature_name,
        bookings(reference, date, start_time, customer_user_id, guest_name, guest_email,
          customer_addresses(address, postal_code, city), services(name)),
        customer_equipment(brand, model, equipment_type),
        intervention_items(name, status, observation, measured_value, visibility, sort_order, field_type, field_meta),
        intervention_parts(designation, brand, reference, quantity),
        intervention_anomalies(equipment_label, description, severity),
        intervention_attestations(attestation_number, generated_at)
      `)
      .eq('id', interventionId)
      .maybeSingle();

    if (!iv) return json({ error: 'not_found' }, 404);
    if (iv.report_status !== 'FINALIZED') return json({ error: 'not_finalized' }, 422);
    // Idempotence : un double-clic sur "Terminer l'intervention", un retry
    // réseau ou un second appel à admIvSendReportEmail ne doit JAMAIS
    // renvoyer un second e-mail pour la même intervention. Un envoi déjà
    // réussi ('SENT') est un succès silencieux ici, pas une erreur.
    if (iv.email_status === 'SENT') return json({ ok: true, already_sent: true });

    // Verrou atomique côté serveur (compare-and-swap sur la valeur lue
    // ci-dessus) : si deux requêtes concurrentes (deux onglets, double-tap)
    // arrivent avec le même état de départ, une seule gagne la course sur
    // cette ligne — l'autre trouve 0 ligne affectée et s'arrête ici, sans
    // jamais envoyer un second e-mail.
    const { data: claimed } = await supabase
      .from('interventions')
      .update({ email_status: 'PENDING' })
      .eq('id', interventionId)
      .eq('email_status', iv.email_status)
      .select('id')
      .maybeSingle();
    if (!claimed) return json({ ok: true, already_sent: true });

    const booking = iv.bookings as any;
    let contactEmail: string | null = booking?.guest_email || null;
    let contactName = booking?.guest_name || 'Client';
    if (booking?.customer_user_id) {
      const [{ data: cp }, { data: prof }] = await Promise.all([
        supabase.from('customer_profiles').select('first_name,last_name').eq('user_id', booking.customer_user_id).maybeSingle(),
        supabase.from('profiles').select('email').eq('user_id', booking.customer_user_id).maybeSingle(),
      ]);
      if (prof?.email) contactEmail = prof.email;
      if (cp) contactName = [cp.first_name, cp.last_name].filter(Boolean).join(' ') || contactName;
    }

    if (!contactEmail) {
      await supabase.from('interventions').update({ email_status: 'FAILED' }).eq('id', interventionId);
      return json({ error: 'no_contact_email' }, 422);
    }
    if (!RESEND_API_KEY) {
      await supabase.from('interventions').update({ email_status: 'FAILED' }).eq('id', interventionId);
      return json({ error: 'missing_resend_key' }, 500);
    }

    const svcName = booking?.services?.name || 'votre intervention';
    const address = booking?.customer_addresses
      ? [booking.customer_addresses.address, booking.customer_addresses.postal_code, booking.customer_addresses.city].filter(Boolean).join(', ')
      : '';
    const equipment = iv.customer_equipment as any;
    const equipmentLabel = equipment
      ? [equipment.brand, equipment.model].filter(Boolean).join(' ')
      : '';
    // Une fiche chaudière compte ~90 contrôles : n'afficher dans le compte
    // rendu client QUE ceux réellement renseignés par le technicien (jamais
    // un mur de "—" pour les contrôles non pertinents/non effectués) — même
    // principe que l'auto_summary : rien d'inventé, rien de non coché.
    const items = ((iv.intervention_items as any[]) || [])
      .filter((it) => it.visibility === 'customer_visible')
      .filter((it) => {
        const ft = it.field_type || 'status';
        if (ft === 'status') return it.status && it.status !== 'NOT_APPLICABLE' && it.status !== 'NOT_CHECKED';
        return !!(it.measured_value && String(it.measured_value).trim());
      })
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));

    const itemsHtml = items.length
      ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:12px 0;font-size:13px;">
          ${items.map((it) => `
            <tr>
              <td style="padding:5px 0;border-bottom:1px solid #EFE9DB;">${escapeHtml(it.name)}</td>
              <td style="padding:5px 0;border-bottom:1px solid #EFE9DB;text-align:right;white-space:nowrap;">${escapeHtml(itemDisplayValue(it))}</td>
            </tr>`).join('')}
        </table>`
      : '';

    const parts = (iv.intervention_parts as any[]) || [];
    const partsHtml = parts.length
      ? `<p><strong>Pièces / consommables utilisés :</strong></p>
         <ul style="margin:4px 0 12px;padding-left:18px;font-size:13px;">
           ${parts.map((p) => `<li>${escapeHtml([p.designation, p.brand, p.reference ? `réf. ${p.reference}` : null].filter(Boolean).join(' — '))}${p.quantity > 1 ? ` × ${p.quantity}` : ''}</li>`).join('')}
         </ul>`
      : '';

    const completionHtml = iv.completion_status && COMPLETION_STATUS_LABEL[iv.completion_status]
      ? `<p><strong>Résultat :</strong> ${escapeHtml(COMPLETION_STATUS_LABEL[iv.completion_status])}</p>`
      : '';

    const anomalies = (iv.intervention_anomalies as any[]) || [];
    const anomaliesHtml = anomalies.length
      ? `<p><strong>Anomalies relevées :</strong></p>
         <ul style="margin:4px 0 12px;padding-left:18px;font-size:13px;">
           ${anomalies.map((a) => `<li>${escapeHtml([a.equipment_label, a.description].filter(Boolean).join(' — '))} (${escapeHtml(ANOMALY_SEVERITY_LABEL[a.severity] || a.severity)})</li>`).join('')}
         </ul>`
      : '';

    const summaryHtml = iv.auto_summary
      ? `<p><strong>Résumé de l'intervention :</strong><br>${escapeHtml(iv.auto_summary)}</p>`
      : '';

    // Réserves (section 3) : mises en valeur distinctement, jamais fondues
    // dans le résumé automatique ni dans la liste libre d'anomalies — même
    // quand reserves_status vaut 'AUCUNE', l'absence de réserve est
    // affichée explicitement (traçabilité : prouve que la question a été
    // posée et répondue, pas simplement omise).
    const reservesHtml = iv.reserves_status
      ? `<div style="margin:16px 0;padding:14px 16px;border-radius:10px;background:#F7F5EE;">
           <p style="margin:0 0 4px;font-weight:700;font-size:13px;">Réserves / autres anomalies constatées</p>
           <p style="margin:0;font-size:13px;">${escapeHtml(RESERVES_STATUS_LABEL[iv.reserves_status] || iv.reserves_status)}${iv.reserves_detail ? ` — ${escapeHtml(iv.reserves_detail)}` : ''}</p>
         </div>`
      : '';

    // Attestation réglementaire : section visuellement et textuellement
    // DISTINCTE du compte rendu commercial ci-dessus — jamais confondue
    // avec une facture, un devis ou le contrat (section 13 du cahier des
    // charges chaudière). N'existe que pour un entretien chaudière gaz/fioul
    // (voir admIvFinalize, index.html).
    const attestation = (iv.intervention_attestations as any[])?.[0];
    const attestationHtml = attestation
      ? `<div style="margin:24px 0;padding:16px;border:2px solid #101B24;border-radius:10px;">
           <p style="margin:0 0 6px;font-weight:800;letter-spacing:0.04em;text-transform:uppercase;font-size:13px;">Attestation d'entretien — document réglementaire distinct</p>
           <p style="margin:0;font-size:13px;">N° ${escapeHtml(attestation.attestation_number)} — générée le ${escapeHtml(new Date(attestation.generated_at).toLocaleDateString('fr-FR'))}.<br>
           Cette attestation certifie la réalisation de l'entretien décrit ci-dessus, conformément aux contrôles réglementaires applicables. Elle ne constitue ni une facture, ni un devis, ni un engagement contractuel commercial.</p>
         </div>`
      : '';

    const bodyHtml = `
      ${statusBadgeHtml('Compte rendu d\'intervention', 'confirmed')}
      <h2 style="color:#101B24;margin:0 0 14px;">Bonjour ${escapeHtml(contactName)},</h2>
      <p>Voici le compte rendu de votre intervention <strong>${escapeHtml(svcName)}</strong>${iv.report_number ? ` (réf. ${escapeHtml(iv.report_number)})` : ''}${address ? ` au ${escapeHtml(address)}` : ''}, réalisée le ${booking?.date ? escapeHtml(booking.date.split('-').reverse().join('/')) : ''}.</p>
      ${equipmentLabel ? `<p><strong>Équipement :</strong> ${escapeHtml(equipmentLabel)}</p>` : ''}
      ${summaryHtml}
      ${itemsHtml}
      ${partsHtml}
      ${anomaliesHtml}
      ${completionHtml}
      ${reservesHtml}
      ${iv.observations ? `<p><strong>Observations du technicien :</strong><br>${escapeHtml(iv.observations)}</p>` : ''}
      ${iv.recommendations ? `<p><strong>Recommandations :</strong><br>${escapeHtml(iv.recommendations)}</p>` : ''}
      <p style="margin-top:20px;color:#5B6B78;font-size:13px;">
        Signé par ${escapeHtml(iv.client_signature_name || contactName)} (client) et ${escapeHtml(iv.technician_signature_name || 'notre technicien')} (HAYEVA).
      </p>
      ${attestationHtml}
      <p style="margin-top:20px;padding:12px 14px;background:#FAF8F2;border-radius:8px;font-size:11px;line-height:1.5;color:#5B6B78;">${escapeHtml(LEGAL_SCOPE_MENTION)}</p>
      <p style="margin-top:24px;">Pour toute question sur cette intervention, répondez à cet e-mail ou appelez-nous au <strong>06 71 26 23 02</strong>.</p>
    `;

    const html = renderEmailShell(bodyHtml, booking?.reference);
    const subject = 'Compte rendu de votre intervention HAYEVA';

    await supabase.from('interventions').update({ email_status: 'PENDING' }).eq('id', interventionId);

    const emailRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM_EMAIL, to: [contactEmail], reply_to: REPLY_TO_EMAIL, subject, html }),
    });

    if (!emailRes.ok) {
      console.error('send-intervention-report: échec envoi Resend', emailRes.status, await emailRes.text());
      await supabase.from('interventions').update({ email_status: 'FAILED' }).eq('id', interventionId);
      return json({ error: 'email_failed' }, 502);
    }

    await supabase.from('interventions').update({
      email_status: 'SENT', email_sent_at: new Date().toISOString(),
    }).eq('id', interventionId);

    return json({ ok: true });
  } catch (err) {
    console.error('send-intervention-report: erreur inattendue', err);
    return json({ error: 'unexpected' }, 500);
  }
});
