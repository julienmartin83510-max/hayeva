// Supabase Edge Function — génère un code de récompense pour le jeu
// "La Maison HAYEVA", UNIQUEMENT côté serveur (service_role).
//
// Pourquoi côté serveur et jamais côté navigateur : le code a une vraie
// valeur commerciale (voir game_reward_codes, 0041_hayeva_game_rewards.sql).
// Un code généré en JavaScript client pourrait être fabriqué/rejoué à
// l'infini en rechargeant la page — même principe de sécurité que le reste
// du projet (le client propose une intention, le serveur décide).
//
// Anti-abus : client_session_id est UNIQUE en base. Un même appareil/
// navigateur (même sessionId que window.sudGetSessionId(), déjà utilisé
// pour l'audience anonyme) ne peut obtenir qu'un seul code — un appel
// répété avec le même client_session_id renvoie toujours le code déjà
// existant, jamais un nouveau.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function generateCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // sans 0/O/1/I ambigus
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  let suffix = '';
  for (const b of bytes) suffix += alphabet[b % alphabet.length];
  return `HAYEVA-${suffix}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const body = await req.json().catch(() => ({}));
    const clientSessionId = typeof body.client_session_id === 'string' ? body.client_session_id.trim() : '';
    const score = typeof body.score === 'number' && Number.isFinite(body.score) ? Math.max(0, Math.min(1000, Math.round(body.score))) : null;
    const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!clientSessionId || !uuidRe.test(clientSessionId)) return json({ status: 'invalid_input' }, 400);

    const { data: existing } = await supabase
      .from('game_reward_codes')
      .select('code, status, created_at, expires_at')
      .eq('client_session_id', clientSessionId)
      .maybeSingle();

    if (existing) {
      return json({ status: 'ok', code: existing.code, code_status: existing.status, already_existed: true });
    }

    // Boucle courte pour l'extrême improbabilité d'une collision de code
    // (contrainte unique en base) plutôt qu'une erreur brute au client.
    let created: { code: string } | null = null;
    for (let attempt = 0; attempt < 5 && !created; attempt++) {
      const code = generateCode();
      const { data, error } = await supabase
        .from('game_reward_codes')
        .insert({ code, client_session_id: clientSessionId, score })
        .select('code')
        .single();
      if (!error && data) created = data;
      else if (error && error.code !== '23505') break; // erreur autre qu'une collision d'unicité : on arrête
    }
    if (!created) return json({ status: 'unavailable' }, 200);

    return json({ status: 'ok', code: created.code, code_status: 'created', already_existed: false });
  } catch (e) {
    console.error('game-generate-code: erreur inattendue', e);
    return json({ status: 'unavailable' }, 200);
  }
});
