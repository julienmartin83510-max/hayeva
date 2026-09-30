// Supabase Edge Function — vérifie la validité d'un code de récompense du
// jeu "La Maison HAYEVA" (statut, expiration), sans jamais exposer la table
// game_reward_codes directement au client (RLS la réserve aux comptes
// admin). Utilisée par l'écran de récompense pour réafficher le statut
// réel, et disponible pour une future intégration au tunnel de réservation
// (vérifier avant d'honorer une offre — jamais faire confiance au seul
// frontend, voir la consigne de sécurité du projet).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const body = await req.json().catch(() => ({}));
    const code = typeof body.code === 'string' ? body.code.trim().toUpperCase() : '';
    if (!code || !/^HAYEVA-[A-Z0-9]{6}$/.test(code)) return json({ status: 'invalid_input' }, 400);

    const { data } = await supabase
      .from('game_reward_codes')
      .select('status, expires_at, redeemed_at')
      .eq('code', code)
      .maybeSingle();

    if (!data) return json({ status: 'ok', valid: false, reason: 'not_found' });

    const expired = new Date(data.expires_at).getTime() < Date.now();
    let effectiveStatus = data.status;
    if (expired && effectiveStatus !== 'redeemed' && effectiveStatus !== 'cancelled') effectiveStatus = 'expired';

    return json({
      status: 'ok',
      valid: effectiveStatus === 'created' || effectiveStatus === 'claimed',
      code_status: effectiveStatus,
      redeemed_at: data.redeemed_at,
    });
  } catch (e) {
    console.error('game-check-code: erreur inattendue', e);
    return json({ status: 'unavailable' }, 200);
  }
});
