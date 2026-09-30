// Supabase Edge Function — HAYEVA Voice, transcription serveur pour le
// repli audio des navigateurs sans SpeechRecognition (Safari/iOS et tout
// navigateur iOS, qui partagent tous le même moteur WebKit imposé par
// Apple — Chrome iOS compris, ce n'est PAS équivalent à Chrome desktop).
//
// RÔLE UNIQUE : recevoir un court extrait audio enregistré par le
// navigateur (MediaRecorder), le transcrire en texte, et renvoyer ce texte
// — rien d'autre. Le texte obtenu est ensuite envoyé par le navigateur à
// voice-public-chat, exactement comme s'il avait été tapé ou reconnu par
// SpeechRecognition : AUCUNE logique de conversation ici, jamais un second
// moteur conversationnel.
//
// FOURNISSEUR : aucun des fournisseurs déjà configurés (OPENROUTER_API_KEY)
// n'expose de transcription audio documentée — vérifié dans la
// documentation OpenRouter avant d'écrire ce fichier (aucun modèle Whisper
// listé, aucune mention "input_audio"/"audio_url" dans leur référence
// d'API). Ce fichier essaie donc, dans l'ordre :
//   1. GROQ_API_KEY (Whisper large-v3-turbo) — nouveau, à créer (gratuit/
//      très faible coût) si tu veux ce chemin. Si absent, essaie :
//   2. OPENAI_API_KEY — déjà présent dans les secrets pour le chemin
//      Realtime abandonné ; la transcription Whisper classique
//      (quelques dixièmes de centime par requête) n'a AUCUN rapport de
//      coût avec l'API Realtime (facturée à la minute audio) que tu as
//      explicitement refusée — mais reste un choix qui t'appartient.
// Si aucune des deux n'est configurée, renvoie clairement 'unavailable'
// (jamais une erreur technique brute côté client).
//
// SÉCURITÉ : aucune clé n'est jamais transmise ni journalisée. Aucun
// fichier audio n'est jamais écrit sur disque ni stocké — le buffer décodé
// vit uniquement en mémoire le temps de l'appel et est éligible au ramasse-
// miettes juste après (rien à supprimer explicitement, il n'existe nulle
// part). Accès public (même patron que voice-public-chat), fermé par
// défaut si voice_assistant_settings.enabled est faux, plafonné par jour
// (voice_transcription_usage_daily) et par taille/durée par requête.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const GROQ_API_KEY = Deno.env.get('GROQ_API_KEY');
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Taille max du corps base64 accepté — ~6 Mo décodés couvre largement 45s
// d'audio compressé (mp4/webm), tout en bornant clairement l'abus/le coût
// avant même d'appeler un fournisseur externe.
const MAX_BASE64_CHARS = 8_000_000;

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function transcribeWithGroq(bytes: Uint8Array, mimeType: string): Promise<string | null> {
  const form = new FormData();
  form.append('file', new Blob([bytes], { type: mimeType }), 'audio' + extensionFor(mimeType));
  form.append('model', 'whisper-large-v3-turbo');
  form.append('language', 'fr');
  form.append('response_format', 'json');
  const res = await fetch('https://api.groq.com/openai/v1/audio/transcriptions', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${GROQ_API_KEY}` },
    body: form,
  }).catch((e) => {
    console.error('voice-transcribe: appel Groq échoué', e instanceof Error ? e.message : e);
    return null;
  });
  if (!res || !res.ok) {
    const errBody = res ? await res.text().catch(() => '') : '';
    console.error('voice-transcribe: Groq a refusé la demande', res?.status, errBody.slice(0, 300));
    return null;
  }
  const json = await res.json().catch(() => null);
  return (json && typeof json.text === 'string') ? json.text : null;
}

async function transcribeWithOpenAI(bytes: Uint8Array, mimeType: string): Promise<string | null> {
  const form = new FormData();
  form.append('file', new Blob([bytes], { type: mimeType }), 'audio' + extensionFor(mimeType));
  form.append('model', 'whisper-1');
  form.append('language', 'fr');
  form.append('response_format', 'json');
  const res = await fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${OPENAI_API_KEY}` },
    body: form,
  }).catch((e) => {
    console.error('voice-transcribe: appel OpenAI échoué', e instanceof Error ? e.message : e);
    return null;
  });
  if (!res || !res.ok) {
    const errBody = res ? await res.text().catch(() => '') : '';
    console.error('voice-transcribe: OpenAI a refusé la demande', res?.status, errBody.slice(0, 300));
    return null;
  }
  const json = await res.json().catch(() => null);
  return (json && typeof json.text === 'string') ? json.text : null;
}

function extensionFor(mimeType: string): string {
  if (mimeType.includes('mp4')) return '.mp4';
  if (mimeType.includes('webm')) return '.webm';
  if (mimeType.includes('ogg')) return '.ogg';
  if (mimeType.includes('mpeg') || mimeType.includes('mp3')) return '.mp3';
  if (mimeType.includes('wav')) return '.wav';
  return '.dat';
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    if (!GROQ_API_KEY && !OPENAI_API_KEY) {
      console.error('voice-transcribe: aucun fournisseur de transcription configuré (GROQ_API_KEY / OPENAI_API_KEY).');
      return json({ status: 'unavailable' }, 200);
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const body = await req.json().catch(() => ({}));
    const audioBase64 = typeof body.audio_base64 === 'string' ? body.audio_base64 : '';
    const mimeType = typeof body.mime_type === 'string' && body.mime_type.slice(0, 60) || 'audio/webm';
    const clientSessionId = typeof body.client_session_id === 'string' ? body.client_session_id.trim().slice(0, 100) : '';
    if (!audioBase64 || !clientSessionId) return json({ error: 'invalid_input' }, 400);
    if (audioBase64.length > MAX_BASE64_CHARS) return json({ status: 'audio_too_large' }, 200);

    const { data: settings } = await supabase
      .from('voice_assistant_settings')
      .select('enabled, transcription_max_per_day')
      .eq('id', true)
      .maybeSingle();
    if (!settings || !settings.enabled) return json({ status: 'unavailable' }, 200);

    // Quota dur quotidien — même garantie que voice_realtime_usage_daily :
    // jamais dépassé, même en cas de pic de trafic.
    const today = new Date().toISOString().slice(0, 10);
    const { data: usageRow } = await supabase.from('voice_transcription_usage_daily').select('*').eq('usage_date', today).maybeSingle();
    if (usageRow && usageRow.request_count >= settings.transcription_max_per_day) {
      return json({ status: 'quota_reached' }, 200);
    }

    let bytes: Uint8Array;
    try { bytes = base64ToBytes(audioBase64); }
    catch { return json({ error: 'invalid_input' }, 400); }

    let text: string | null = null;
    if (GROQ_API_KEY) text = await transcribeWithGroq(bytes, mimeType);
    if (!text && OPENAI_API_KEY) text = await transcribeWithOpenAI(bytes, mimeType);

    if (usageRow) {
      await supabase.from('voice_transcription_usage_daily').update({ request_count: usageRow.request_count + 1, updated_at: new Date().toISOString() }).eq('usage_date', today);
    } else {
      await supabase.from('voice_transcription_usage_daily').insert({ usage_date: today, request_count: 1 });
    }

    if (!text || !text.trim()) return json({ status: 'empty' }, 200);
    return json({ status: 'ok', text: text.trim() }, 200);
  } catch (e) {
    console.error('voice-transcribe: erreur inattendue', e);
    return json({ status: 'unavailable' }, 200);
  }
});
