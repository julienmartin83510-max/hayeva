// Supabase Edge Function — vérification anti-robot Cloudflare Turnstile des
// formulaires publics sans compte (réservation invitée, candidature parrain,
// candidature apporteur d'affaires).
//
// 1. reçoit le jeton Turnstile produit par le navigateur ;
// 2. le vérifie auprès de Cloudflare (Siteverify) avec TURNSTILE_SECRET_KEY,
//    secret de fonction lu uniquement ici, jamais renvoyé ni journalisé ;
// 3. si Cloudflare confirme, délivre un laissez-passer à usage unique
//    (captcha_passes, 10 minutes, propre au formulaire) que la fonction SQL
//    correspondante consomme (voir 0100_turnstile_captcha_passes.sql).
//
// Anti-abus : corps limité à 4 Ko, formulaire sur liste blanche, jeton
// borné, 20 laissez-passer maximum par adresse IP sur 10 minutes (adresse
// stockée uniquement sous forme d'empreinte SHA-256, jamais en clair).
// Erreurs renvoyées : codes neutres uniquement, aucune donnée interne.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TURNSTILE_SECRET_KEY = Deno.env.get('TURNSTILE_SECRET_KEY');

const PURPOSES = ['booking', 'referrer_application', 'business_application'];
const MAX_BODY_BYTES = 4096;
const MAX_TOKEN_LENGTH = 2048;
const RATE_LIMIT_WINDOW_MIN = 10;
const RATE_LIMIT_MAX = 20;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d)).map((x) => x.toString(16).padStart(2, '0')).join('');
}

function clientIp(req: Request): string {
  return (req.headers.get('cf-connecting-ip') || req.headers.get('x-forwarded-for') || '').split(',')[0].trim();
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ success: false, error: 'method_not_allowed' }, 405);

  try {
    const declared = Number(req.headers.get('content-length') || '0');
    if (declared > MAX_BODY_BYTES) return json({ success: false, error: 'payload_too_large' }, 413);
    const raw = await req.text();
    if (raw.length > MAX_BODY_BYTES) return json({ success: false, error: 'payload_too_large' }, 413);

    let body: { token?: unknown; purpose?: unknown } = {};
    try { body = JSON.parse(raw || '{}'); } catch (_e) { return json({ success: false, error: 'invalid_request' }, 400); }

    const purpose = typeof body.purpose === 'string' ? body.purpose : '';
    if (!PURPOSES.includes(purpose)) return json({ success: false, error: 'invalid_request' }, 400);

    const token = typeof body.token === 'string' ? body.token.trim() : '';
    if (!token) return json({ success: false, error: 'missing_token' }, 400);
    if (token.length > MAX_TOKEN_LENGTH) return json({ success: false, error: 'invalid_token' }, 400);

    if (!TURNSTILE_SECRET_KEY) {
      console.error('verify-turnstile: TURNSTILE_SECRET_KEY non configuré');
      return json({ success: false, error: 'not_configured' }, 503);
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const ip = clientIp(req);
    const ipHash = ip ? await sha256Hex(`hayeva-turnstile:${ip}`) : null;

    if (ipHash) {
      const since = new Date(Date.now() - RATE_LIMIT_WINDOW_MIN * 60000).toISOString();
      const { count } = await supabase
        .from('captcha_passes').select('id', { count: 'exact', head: true })
        .eq('ip_hash', ipHash).gte('created_at', since);
      if ((count || 0) >= RATE_LIMIT_MAX) return json({ success: false, error: 'rate_limited' }, 429);
    }

    const form = new URLSearchParams();
    form.set('secret', TURNSTILE_SECRET_KEY);
    form.set('response', token);
    if (ip) form.set('remoteip', ip);
    form.set('idempotency_key', crypto.randomUUID());

    let outcome: { success?: boolean; 'error-codes'?: string[] } = {};
    try {
      const cf = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form.toString(),
      });
      outcome = await cf.json();
    } catch (err) {
      console.error('verify-turnstile: Cloudflare injoignable', err instanceof Error ? err.message : String(err));
      return json({ success: false, error: 'verification_unavailable' }, 502);
    }

    if (!outcome.success) {
      const codes = outcome['error-codes'] || [];
      if (codes.includes('invalid-input-secret') || codes.includes('missing-input-secret')) {
        console.error('verify-turnstile: secret refusé par Cloudflare', codes.join(','));
        return json({ success: false, error: 'not_configured' }, 503);
      }
      const error = codes.includes('timeout-or-duplicate') ? 'expired_token'
        : codes.includes('missing-input-response') ? 'missing_token' : 'invalid_token';
      return json({ success: false, error }, 403);
    }

    const { data: pass, error: insErr } = await supabase
      .from('captcha_passes').insert({ purpose, ip_hash: ipHash }).select('id').single();
    if (insErr || !pass) {
      console.error('verify-turnstile: enregistrement du laissez-passer impossible', insErr?.message);
      return json({ success: false, error: 'verification_unavailable' }, 500);
    }

    // Première vérification réussie : la chaîne complète fonctionne (clé de
    // site servie au navigateur + secret serveur), la protection devient
    // obligatoire côté SQL pour les visiteurs non connectés.
    await supabase.from('security_settings')
      .update({ turnstile_enforced: true, turnstile_activated_at: new Date().toISOString(), updated_at: new Date().toISOString() })
      .eq('id', 1).eq('turnstile_enforced', false);

    // Ménage occasionnel des laissez-passer de plus de 24 h.
    if (Math.random() < 0.05) {
      await supabase.from('captcha_passes').delete().lt('created_at', new Date(Date.now() - 86400000).toISOString());
    }

    return json({ success: true, pass: pass.id, expires_in: 600 });
  } catch (err) {
    console.error('verify-turnstile: erreur inattendue', err instanceof Error ? err.message : String(err));
    return json({ success: false, error: 'verification_unavailable' }, 500);
  }
});
