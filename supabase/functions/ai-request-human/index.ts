// Supabase Edge Function — "Parler à un humain" depuis l'Assistant IA
// (widget public ET Espace Client/Pro connecté).
//
// DÉCLENCHEMENT : appelée UNIQUEMENT par le frontend (sb.client.functions.
// invoke('ai-request-human', ...)), jamais automatiquement à chaque message —
// seulement quand le widget affiche le bouton "Demander à être rappelé(e)",
// c'est-à-dire quand l'IA a donné une réponse de sécurité (gaz/incendie) ou
// est indisponible/saturée (voir ai-assistant/index.ts). Un clic = un appel =
// une seule ligne insérée = une seule alerte admin envoyée dans la foulée,
// dans cette même fonction (pas de trigger AFTER INSERT + pg_net ici,
// contrairement aux réservations) : aucun risque de double notification par
// plusieurs listeners.
//
// SÉCURITÉ : écriture dans ai_human_requests UNIQUEMENT via service_role
// (RLS de la table n'autorise ni anon ni authenticated en insert, voir
// 0043_ai_human_requests.sql) — même patron que ai_conversations/ai_messages.
// RESEND_API_KEY, VAPID_PRIVATE_KEY, ADMIN_NOTIFICATION_EMAIL restent
// exclusivement lus côté serveur ici, jamais transmis au frontend.
//
// FIABILITÉ : la demande est enregistrée en base AVANT toute tentative de
// notification — un échec d'envoi (Resend down, push expiré...) ne fait
// jamais échouer la confirmation renvoyée au visiteur, il journalise
// simplement l'erreur côté serveur (Logs Supabase).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';
import { renderEmailShell, statusBadgeHtml } from '../_shared/email-template.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const ADMIN_EMAIL = Deno.env.get('ADMIN_NOTIFICATION_EMAIL');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const ADMIN_PANEL_URL = Deno.env.get('ADMIN_PANEL_URL') || 'https://hayeva.netlify.app/#espacePro';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const REASON_LABELS: Record<string, string> = {
  safety: '⚠️ Sujet sécurité évoqué (gaz/incendie)',
  unavailable: 'Assistant IA indisponible',
  rate_limited: 'Assistant IA momentanément saturé',
  session_cap_reached: "Limite d'échanges de la session atteinte",
  daily_cap_reached: 'Quota journalier de l\'assistant atteint',
};

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string
  ));
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const body = await req.json().catch(() => ({}));

    const sessionId = typeof body.session_id === 'string' ? body.session_id : null;
    const conversationId = typeof body.conversation_id === 'string' ? body.conversation_id : null;
    const customerType = body.customer_type === 'professionnel' ? 'professionnel' : 'particulier';
    const reasonKey = typeof body.reason === 'string' ? body.reason : '';
    const reasonLabel = REASON_LABELS[reasonKey] || 'Demande de rappel depuis l\'assistant';
    const contactPhone = typeof body.contact_phone === 'string' ? body.contact_phone.trim().slice(0, 40) : '';
    const contactName = typeof body.contact_name === 'string' ? body.contact_name.trim().slice(0, 120) : '';

    if (!sessionId) return json({ error: 'invalid_input' }, 400);

    // Conversation : reprend l'existante si fournie ET appartenant bien à
    // cette session_id (même vérification que ai-assistant/index.ts) —
    // jamais de confiance aveugle dans un id fourni par le client.
    let conversation: { id: string; customer_user_id: string | null } | null = null;
    if (conversationId) {
      const { data } = await supabase.from('ai_conversations')
        .select('id, customer_user_id').eq('id', conversationId).eq('session_id', sessionId).maybeSingle();
      conversation = data;
    }

    // Dernier message du visiteur (pour donner du contexte à l'admin), et
    // identité connue si le visiteur est authentifié — même résolution que
    // knownCustomerFact dans ai-assistant/index.ts.
    let lastMessage = '';
    let contactEmail = '';
    let resolvedName = contactName;
    let resolvedPhone = contactPhone;
    if (conversation) {
      const { data: lastRow } = await supabase.from('ai_messages')
        .select('content').eq('conversation_id', conversation.id).eq('role', 'user')
        .order('created_at', { ascending: false }).limit(1).maybeSingle();
      if (lastRow) lastMessage = lastRow.content;
    }
    const authHeader = req.headers.get('authorization') || '';
    const jwt = authHeader.replace(/^Bearer\s+/i, '').trim();
    if (jwt) {
      try {
        const { data: userRes } = await supabase.auth.getUser(jwt);
        const authUser = userRes?.user;
        if (authUser) {
          const [{ data: cp }, { data: prof }] = await Promise.all([
            supabase.from('customer_profiles').select('first_name,last_name,phone').eq('user_id', authUser.id).maybeSingle(),
            supabase.from('profiles').select('email').eq('user_id', authUser.id).maybeSingle(),
          ]);
          if (cp) {
            resolvedName = resolvedName || [cp.first_name, cp.last_name].filter(Boolean).join(' ');
            resolvedPhone = resolvedPhone || cp.phone || '';
          }
          if (prof) contactEmail = prof.email || '';
        }
      } catch (_e) {
        // Best-effort : jeton absent/invalide → pas d'identité connue, jamais bloquant.
      }
    }

    // Anti-spam minimal : une demande déjà envoyée pour cette même
    // conversation dans les 10 dernières minutes n'en recrée pas une seconde
    // (double-clic, onglet dupliqué) — pas de nouvelle alerte, mais la
    // confirmation reste renvoyée normalement au visiteur.
    if (conversation) {
      const tenMinAgo = new Date(Date.now() - 10 * 60 * 1000).toISOString();
      const { data: recent } = await supabase.from('ai_human_requests')
        .select('id').eq('conversation_id', conversation.id).gte('created_at', tenMinAgo).limit(1);
      if (recent && recent.length) {
        return json({ status: 'ok', already_sent: true }, 200);
      }
    }

    const { data: inserted, error: insertErr } = await supabase.from('ai_human_requests').insert({
      conversation_id: conversation ? conversation.id : null,
      session_id: sessionId,
      customer_type: customerType,
      reason: reasonLabel,
      last_message: lastMessage || null,
      contact_name: resolvedName || null,
      contact_phone: resolvedPhone || null,
      contact_email: contactEmail || null,
    }).select('id').single();

    if (insertErr || !inserted) {
      console.error('ai-request-human: échec insertion', insertErr);
      return json({ status: 'unavailable' }, 200);
    }

    // ---- Alerte admin (e-mail) ----
    try {
      if (RESEND_API_KEY && ADMIN_EMAIL) {
        const html = renderEmailShell(`
          <h2 style="margin:0 0 16px; font-size:20px; color:#101B24;">Demande de rappel — Assistant IA</h2>
          ${statusBadgeHtml('🆘 Intervention humaine demandée', 'received')}
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">
            <tr><td style="padding:7px 0;color:#5B6B78;width:130px;">Motif</td><td style="padding:7px 0;font-weight:600;text-align:right;">${escapeHtml(reasonLabel)}</td></tr>
            <tr><td style="padding:7px 0;color:#5B6B78;">Type</td><td style="padding:7px 0;text-align:right;">${customerType === 'professionnel' ? 'Professionnel' : 'Particulier'}</td></tr>
            <tr><td style="padding:7px 0;color:#5B6B78;">Nom</td><td style="padding:7px 0;text-align:right;">${resolvedName ? escapeHtml(resolvedName) : '—'}</td></tr>
            <tr><td style="padding:7px 0;color:#5B6B78;">Téléphone</td><td style="padding:7px 0;text-align:right;font-weight:700;">${resolvedPhone ? escapeHtml(resolvedPhone) : '—'}</td></tr>
            <tr><td style="padding:7px 0;color:#5B6B78;">E-mail</td><td style="padding:7px 0;text-align:right;">${contactEmail ? escapeHtml(contactEmail) : '—'}</td></tr>
            ${lastMessage ? `<tr><td style="padding:7px 0;color:#5B6B78;vertical-align:top;">Dernier message</td><td style="padding:7px 0;text-align:right;">${escapeHtml(lastMessage)}</td></tr>` : ''}
          </table>
          <p style="margin:24px 0 0;">
            <a href="${ADMIN_PANEL_URL}" style="display:inline-block;background:#1AA6EE;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-weight:600;font-size:14px;">Ouvrir l'Espace Administration</a>
          </p>
        `);
        const emailRes = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            from: FROM_EMAIL,
            to: [ADMIN_EMAIL],
            subject: `🔔 Nouvelle demande HAYEVA — Assistant IA${resolvedName ? ' — ' + resolvedName : ''}`,
            html,
          }),
        });
        if (!emailRes.ok) console.error('ai-request-human: échec envoi Resend', emailRes.status, await emailRes.text());
      } else {
        console.error('ai-request-human: RESEND_API_KEY ou ADMIN_NOTIFICATION_EMAIL manquant — e-mail admin ignoré.');
      }
    } catch (emailErr) {
      console.error('ai-request-human: bloc e-mail — erreur inattendue', emailErr);
    }

    // ---- Alerte admin (push) — même patron que notify-admin-booking/
    // notify-booking-change, best-effort, jamais bloquant. ----
    try {
      const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY');
      const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY');
      const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') || 'mailto:contact@hayeva.fr';
      if (VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY) {
        const { data: subs } = await supabase.from('admin_push_subscriptions')
          .select('id, endpoint, p256dh, auth_key').eq('enabled', true);
        if (subs && subs.length) {
          webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
          const pushBody = [reasonLabel, resolvedName || 'Visiteur anonyme', resolvedPhone || null].filter(Boolean).join('\n');
          const hashIdx = ADMIN_PANEL_URL.indexOf('#');
          const panelBase = hashIdx === -1 ? ADMIN_PANEL_URL : ADMIN_PANEL_URL.slice(0, hashIdx);
          const panelHash = hashIdx === -1 ? 'espacePro' : ADMIN_PANEL_URL.slice(hashIdx + 1);
          const pushPayload = JSON.stringify({
            title: '🆘 Demande de rappel — Assistant IA',
            body: pushBody,
            url: `${panelBase}#${panelHash}`,
          });
          await Promise.all(subs.map(async (sub: { id: string; endpoint: string; p256dh: string; auth_key: string }) => {
            try {
              await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth_key } }, pushPayload);
            } catch (pushErr: unknown) {
              const statusCode = (pushErr as { statusCode?: number })?.statusCode;
              console.error('ai-request-human: échec envoi push', sub.id, statusCode);
              if (statusCode === 404 || statusCode === 410) {
                await supabase.from('admin_push_subscriptions').update({ enabled: false }).eq('id', sub.id);
              }
            }
          }));
        }
      }
    } catch (pushErr) {
      console.error('ai-request-human: bloc push — erreur inattendue', pushErr);
    }

    return json({ status: 'ok', request_id: inserted.id }, 200);
  } catch (err) {
    console.error('ai-request-human: erreur inattendue', err);
    return json({ status: 'unavailable' }, 200);
  }
});
