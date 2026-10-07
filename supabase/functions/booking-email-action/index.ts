// Supabase Edge Function — boutons "CONFIRMER" / "REFUSER" de l'e-mail
// admin "Nouvelle demande de rendez-vous HAYEVA".
//
// Appelée UNIQUEMENT par la page rdv-action.html du site (POST JSON) :
//   { a: 'confirm' | 'refuse', t: '<jeton>', execute: boolean }
//   { a: 'move', t: '<jeton>', d?: 'AAAA-MM-JJ', h?: 'HH:MM', execute: boolean }
//     (DÉPLACER : sans d => infos ; d seul => créneaux libres ; d+h+execute
//     => déplacement, voir process_booking_email_move, 0119)
// - execute=false : renvoie l'état de la demande (affichage avant validation).
// - execute=true  : exécute l'action (une seule fois).
//
// SÉCURITÉ : aucune session admin requise — l'autorisation EST le jeton :
// 256 bits aléatoires, lié à UNE réservation et UNE action, à usage unique,
// avec expiration ; seul son hash SHA-256 est stocké (booking_action_tokens,
// table sans policy RLS). Tout le contrôle (jeton valide, non utilisé, non
// expiré, réservation encore PENDING) et la mise à jour sont faits
// atomiquement côté base (process_booking_email_action, verrou FOR UPDATE)
// — deux clics simultanés ne peuvent pas agir deux fois. Aucune clé
// Supabase ne transite jamais par le lien ni par la page.
//
// La confirmation (status CONFIRMED) déclenche ensuite, via les triggers déjà
// en place : l'e-mail client "Rendez-vous confirmé" et la création de
// l'événement Apple Calendar. Le refus (CANCELLED + cancellation_type
// 'refused') déclenche l'e-mail client de refus ; aucun événement Apple
// n'est créé (une demande PENDING n'en a jamais), le créneau est libéré
// (la contrainte d'exclusion ne couvre pas CANCELLED).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ALLOWED_ORIGINS = new Set(
  (Deno.env.get('ACTION_ALLOWED_ORIGINS') || 'https://hayeva.fr,https://www.hayeva.fr,https://hayeva.netlify.app')
    .split(',').map((s) => s.trim()).filter(Boolean),
);

function corsHeaders(origin: string | null): Record<string, string> {
  const h: Record<string, string> = {
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'content-type',
    'Cache-Control': 'no-store',
    Vary: 'Origin',
  };
  if (origin && ALLOWED_ORIGINS.has(origin)) h['Access-Control-Allow-Origin'] = origin;
  return h;
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d)).map((x) => x.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin');
  const headers = { ...corsHeaders(origin), 'Content-Type': 'application/json' };
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return new Response(JSON.stringify({ result: 'invalid' }), { status: 405, headers });

  try {
    const body = await req.json().catch(() => ({}));
    const action = body?.a === 'confirm' || body?.a === 'refuse' || body?.a === 'move' ? body.a : null;
    const token = typeof body?.t === 'string' ? body.t : '';
    if (!action || !/^[A-Za-z0-9_-]{40,64}$/.test(token)) {
      return new Response(JSON.stringify({ result: 'invalid' }), { status: 200, headers });
    }
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    let rpc;
    if (action === 'move') {
      const d = typeof body?.d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(body.d) ? body.d : null;
      const h = typeof body?.h === 'string' && /^\d{2}:\d{2}$/.test(body.h) ? body.h : null;
      rpc = await supabase.rpc('process_booking_email_move', {
        p_token_hash: await sha256Hex(token),
        p_date: d,
        p_start_time: h,
        p_execute: body?.execute === true && !!d && !!h,
      });
    } else {
      rpc = await supabase.rpc('process_booking_email_action', {
        p_token_hash: await sha256Hex(token),
        p_action: action,
        p_execute: body?.execute === true,
      });
    }
    const { data, error } = rpc;
    if (error) {
      console.error('booking-email-action: erreur RPC', error.message);
      return new Response(JSON.stringify({ result: 'error' }), { status: 200, headers });
    }
    return new Response(JSON.stringify(data), { status: 200, headers });
  } catch (err) {
    console.error('booking-email-action: erreur inattendue', err);
    return new Response(JSON.stringify({ result: 'error' }), { status: 200, headers });
  }
});
