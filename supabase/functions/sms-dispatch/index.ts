// Supabase Edge Function — envoi des SMS préparés (centre de communication).
//
// DÉCLENCHEMENT : sms_kick_dispatch() dès qu'un message est mis en file
// (0129_sms_center.sql), filet de sécurité pg_cron toutes les 10 min
// ('hayeva-sms-dispatch'), ou bouton admin.
//
// GARDE-FOUS (aucun SMS réel sans autorisation explicite du propriétaire) :
//  - sms_settings.enabled = false (défaut) → aucun appel fournisseur ; les
//    messages en file passent en 'not_activated'.
//  - Clé d'API absente → aucun envoi ('failed' avec motif explicite).
//  - Mode test (défaut) → envoi UNIQUEMENT au numéro de test du
//    propriétaire, jamais au client ; sans numéro de test, rien ne part.
//  - Heures calmes 21 h – 8 h (Paris) pour les envois automatiques.
//  - Désinscription revérifiée juste avant l'envoi.
//
// Fournisseurs : Brevo (clé BREVO_API_KEY) ou Twilio (TWILIO_ACCOUNT_SID +
// TWILIO_AUTH_TOKEN), secrets Supabase uniquement — jamais dans le site.
// Le secret SMS_PROVIDER doit rester VIDE : il activerait l'ancien envoi
// direct de notify-on-the-way, en doublon de ce centre.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CRON_SHARED_SECRET = Deno.env.get('CRON_SHARED_SECRET');
const BREVO_API_KEY = Deno.env.get('BREVO_API_KEY');
const TWILIO_ACCOUNT_SID = Deno.env.get('TWILIO_ACCOUNT_SID');
const TWILIO_AUTH_TOKEN = Deno.env.get('TWILIO_AUTH_TOKEN');

const corsHeaders = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type, x-cron-secret' };

// Jeu de caractères GSM-7 : un SMS = 160 caractères (153 par segment au-delà).
// Les caractères hors GSM-7 basculeraient tout le message en Unicode (70
// caractères par SMS) : ils sont remplacés par leur équivalent le plus proche.
const GSM_REPLACE: Record<string, string> = {
  '’': "'", '‘': "'", '«': '"', '»': '"', '“': '"', '”': '"', '–': '-', '—': '-', '…': '...',
  'ê': 'e', 'ë': 'e', 'â': 'a', 'î': 'i', 'ï': 'i', 'ô': 'o', 'û': 'u', 'ç': 'c', 'œ': 'oe',
  'Ê': 'E', 'Â': 'A', 'Î': 'I', 'Ô': 'O', 'Û': 'U', 'È': 'E', 'À': 'A', 'Ù': 'U', ' ': ' ',
};
export function toGsm(text: string): string {
  return Array.from(String(text)).map((c) => GSM_REPLACE[c] ?? c).join('');
}
export function segments(text: string): number {
  const n = Array.from(text).length;
  return n <= 160 ? 1 : Math.ceil(n / 153);
}

function quietHoursParis(): boolean {
  const h = Number(new Date().toLocaleString('en-GB', { timeZone: 'Europe/Paris', hour: '2-digit', hour12: false }));
  return h >= 21 || h < 8;
}

type SendResult = { ok: true; id: string | null } | { ok: false; error: string };

async function sendBrevo(sender: string, to: string, content: string): Promise<SendResult> {
  if (!BREVO_API_KEY) return { ok: false, error: 'Clé BREVO_API_KEY absente des secrets Supabase.' };
  const res = await fetch('https://api.brevo.com/v3/transactionalSMS/sms', {
    method: 'POST',
    headers: { 'api-key': BREVO_API_KEY, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ sender, recipient: to.replace(/^\+/, ''), content, type: 'transactional' }),
  });
  const payload = await res.json().catch(() => ({}));
  if (!res.ok) return { ok: false, error: `Brevo ${res.status}: ${String(payload?.message || '').slice(0, 300)}` };
  return { ok: true, id: payload?.messageId != null ? String(payload.messageId) : (payload?.reference || null) };
}

async function sendTwilio(sender: string, to: string, content: string): Promise<SendResult> {
  if (!TWILIO_ACCOUNT_SID || !TWILIO_AUTH_TOKEN) return { ok: false, error: 'Identifiants Twilio absents des secrets Supabase.' };
  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json`, {
    method: 'POST',
    headers: { Authorization: 'Basic ' + btoa(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`), 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ To: to, From: sender, Body: content }).toString(),
  });
  const payload = await res.json().catch(() => ({}));
  if (!res.ok) return { ok: false, error: `Twilio ${res.status}: ${String(payload?.message || '').slice(0, 300)}` };
  return { ok: true, id: payload?.sid || null };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    let viaCron = !!CRON_SHARED_SECRET && req.headers.get('x-cron-secret') === CRON_SHARED_SECRET;
    let isAdmin = false;
    const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!viaCron && jwt) {
      const { data: userRes } = await supabase.auth.getUser(jwt);
      if (userRes?.user) {
        const { data: profile } = await supabase.from('profiles').select('global_role').eq('user_id', userRes.user.id).maybeSingle();
        isAdmin = profile?.global_role === 'admin';
      }
    }
    if (!viaCron && !isAdmin) return json({ error: 'unauthorized' }, 401);

    const body = await req.json().catch(() => ({}));
    const { data: s } = await supabase.from('sms_settings').select('*').eq('id', 1).maybeSingle();

    // État des secrets (présence uniquement, jamais leur valeur) pour l'admin.
    if (body?.action === 'status') {
      if (!isAdmin) return json({ error: 'forbidden' }, 403);
      return json({ ok: true, brevo_key: !!BREVO_API_KEY, twilio_keys: !!(TWILIO_ACCOUNT_SID && TWILIO_AUTH_TOKEN), legacy_sms_provider_set: !!Deno.env.get('SMS_PROVIDER') });
    }

    // Service inactif : rien n'est envoyé, la file est marquée comme telle.
    if (!s?.enabled || !s?.provider) {
      await supabase.from('sms_messages').update({ status: 'not_activated' }).eq('status', 'queued');
      return json({ ok: true, sent: 0, reason: 'not_activated' });
    }

    const { data: queued } = await supabase.from('sms_messages').select('id, kind').eq('status', 'queued').order('created_at', { ascending: true }).limit(50);
    const quiet = quietHoursParis();
    const results: Array<{ id: string; status: string }> = [];

    for (const q of queued || []) {
      if (quiet && q.kind !== 'manual' && q.kind !== 'on_the_way') continue; // repris à 8 h
      const { data: m } = await supabase.from('sms_messages').update({ status: 'sending' })
        .eq('id', q.id).eq('status', 'queued').select('*').maybeSingle();
      if (!m) continue; // déjà pris par un autre passage : jamais de doublon

      const { data: optOut } = await supabase.from('sms_opt_outs').select('phone').eq('phone', m.to_phone).eq('active', true).maybeSingle();
      if (optOut) { await supabase.from('sms_messages').update({ status: 'skipped_opt_out' }).eq('id', m.id); results.push({ id: m.id, status: 'skipped_opt_out' }); continue; }

      let to = m.to_phone as string;
      let text = toGsm(m.body);
      let testRedirect = false;
      if (s.test_mode) {
        if (!s.test_phone) {
          await supabase.from('sms_messages').update({ status: 'test_blocked', error: 'Mode test sans numéro de test : aucun envoi.' }).eq('id', m.id);
          results.push({ id: m.id, status: 'test_blocked' });
          continue;
        }
        to = s.test_phone;
        text = toGsm('[TEST] ' + m.body);
        testRedirect = true;
      }

      const r = s.provider === 'twilio' ? await sendTwilio(s.sender_name, to, text) : await sendBrevo(s.sender_name, to, text);
      if (r.ok) {
        await supabase.from('sms_messages').update({ status: 'sent', sent_at: new Date().toISOString(), provider: s.provider, provider_message_id: r.id, test_redirect: testRedirect, error: null }).eq('id', m.id);
        results.push({ id: m.id, status: 'sent' });
      } else {
        await supabase.from('sms_messages').update({ status: 'failed', provider: s.provider, test_redirect: testRedirect, error: r.error.slice(0, 500) }).eq('id', m.id);
        console.error('sms-dispatch: échec', m.id, r.error);
        results.push({ id: m.id, status: 'failed' });
      }
    }
    return json({ ok: true, processed: results.length, quiet_hours: quiet, results });
  } catch (err) {
    console.error('sms-dispatch: erreur inattendue', err instanceof Error ? err.message : String(err));
    return json({ error: 'unexpected' }, 500);
  }
});
