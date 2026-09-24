// Supabase Edge Function — Assistant Hayeva Pro (admin uniquement).
//
// Prépare une pré-suggestion structurée pour l'outil Chiffrage déjà
// existant (0021_admin_quote_calculator.sql) à partir d'une description
// libre ("remplacement mitigeur cuisine + déplacement + environ 1h").
// N'écrit RIEN en base : renvoie seulement des champs suggérés, que
// l'admin voit apparaître dans le formulaire du calculateur et doit
// vérifier/modifier avant "Enregistrer dans l'historique" — jamais de
// validation ni d'envoi automatique.
//
// SÉCURITÉ : même pattern que propose-alternative-slot — jeton de session
// de l'admin revérifié côté serveur (is_admin), jamais de confiance dans le
// rôle affirmé par le frontend. OPENROUTER_API_KEY jamais exposée au
// client, jamais lue/affichée/journalisée (même en cas d'erreur, seul le
// message renvoyé par OpenRouter est loggé, jamais la clé).
//
// MODÈLE : openai/gpt-4o-mini (via OpenRouter) — même modèle que
// ai-assistant, piloté par ai_settings.model_name.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const OPENROUTER_API_KEY = Deno.env.get('OPENROUTER_API_KEY');
const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';
const SITE_URL = 'https://hayeva.fr';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const SYSTEM_PROMPT = `Tu aides un artisan plombier/chauffagiste/climaticien à préparer un chiffrage interne à partir d'une description libre qu'il te donne.

Réponds UNIQUEMENT par un objet JSON valide, sans aucun texte avant ou après, avec exactement ces champs :
{
  "intervention_label": string (nom court de l'intervention),
  "domain": "plomberie" | "chauffage" | "climatisation" | "autre",
  "labor_minutes": number (durée de main-d'œuvre estimée en minutes),
  "technician_count": number (par défaut 1 si non précisé),
  "supplies": [{"name": string, "qty": number}] (liste des fournitures/pièces mentionnées ou clairement nécessaires, tableau vide si aucune),
  "notes": string (précisions utiles, vide si rien à ajouter)
}

Ne donne AUCUN prix ni taux horaire : ce n'est pas ton rôle, l'artisan les définit lui-même dans son calculateur. Si une information manque, fais une estimation raisonnable et plausible pour un professionnel du bâtiment plutôt que de laisser un champ vide de sens.`;

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

    const { data: profile } = await supabase.from('profiles').select('global_role').eq('user_id', userRes.user.id).maybeSingle();
    if (!profile || profile.global_role !== 'admin') return json({ error: 'forbidden' }, 403);

    const { data: settings } = await supabase.from('ai_settings').select('enabled, model_name').eq('id', true).maybeSingle();
    if (!settings || !settings.enabled) return json({ status: 'unavailable' }, 200);
    if (!OPENROUTER_API_KEY) {
      console.error('ai-assistant-pro: OPENROUTER_API_KEY manquante.');
      return json({ status: 'unavailable' }, 200);
    }

    const body = await req.json().catch(() => ({}));
    const description = typeof body.description === 'string' ? body.description.trim().slice(0, 500) : '';
    if (!description) return json({ error: 'missing_description' }, 400);

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 20000);
    let openrouterRes: Response;
    try {
      openrouterRes = await fetch(OPENROUTER_URL, {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + OPENROUTER_API_KEY,
          'Content-Type': 'application/json',
          'HTTP-Referer': SITE_URL,
          'X-Title': 'HAYEVA Assistant Pro',
        },
        body: JSON.stringify({
          model: settings.model_name,
          max_tokens: 400,
          messages: [
            { role: 'system', content: SYSTEM_PROMPT },
            { role: 'user', content: description },
          ],
        }),
        signal: controller.signal,
      });
    } catch (e) {
      clearTimeout(timeout);
      console.error('ai-assistant-pro: appel OpenRouter échoué (réseau/timeout)', e instanceof Error ? e.message : e);
      return json({ status: 'unavailable' }, 200);
    }
    clearTimeout(timeout);

    if (!openrouterRes.ok) {
      const errBody = await openrouterRes.text().catch(() => '');
      console.error('ai-assistant-pro: OpenRouter HTTP', openrouterRes.status, errBody.slice(0, 300));
      return json({ status: openrouterRes.status === 429 ? 'rate_limited' : 'unavailable' }, 200);
    }
    const openrouterJson = await openrouterRes.json();
    const rawText = (openrouterJson.choices && openrouterJson.choices[0] && openrouterJson.choices[0].message && openrouterJson.choices[0].message.content) || '';
    let parsed: Record<string, unknown> | null = null;
    try {
      const match = rawText.match(/\{[\s\S]*\}/);
      parsed = JSON.parse(match ? match[0] : rawText);
    } catch (e) {
      console.error('ai-assistant-pro: JSON invalide reçu du modèle', rawText.slice(0, 300));
      return json({ status: 'unavailable' }, 200);
    }

    const today = new Date().toISOString().slice(0, 10);
    const { data: usageRow } = await supabase.from('ai_usage_daily').select('*').eq('usage_date', today).maybeSingle();
    const inputTokens = (openrouterJson.usage && openrouterJson.usage.prompt_tokens) || 0;
    const outputTokens = (openrouterJson.usage && openrouterJson.usage.completion_tokens) || 0;
    if (usageRow) {
      await supabase.from('ai_usage_daily').update({
        request_count: usageRow.request_count + 1,
        estimated_input_tokens: usageRow.estimated_input_tokens + inputTokens,
        estimated_output_tokens: usageRow.estimated_output_tokens + outputTokens,
      }).eq('usage_date', today);
    } else {
      await supabase.from('ai_usage_daily').insert({
        usage_date: today, request_count: 1,
        estimated_input_tokens: inputTokens, estimated_output_tokens: outputTokens,
      });
    }

    return json({ status: 'ok', suggestion: parsed }, 200);
  } catch (e) {
    console.error('ai-assistant-pro: erreur inattendue', e);
    return json({ status: 'unavailable' }, 200);
  }
});
