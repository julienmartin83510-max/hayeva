// Supabase Edge Function — sert au frontend les valeurs de configuration
// PUBLIQUES qui doivent néanmoins rester hors du code source HTML/JS et de
// Git (choix explicite du client), en particulier MAPBOX_PUBLIC_TOKEN et
// VAPID_PUBLIC_KEY.
//
// Un token public Mapbox ou une clé publique VAPID ne sont pas des secrets
// au sens strict (tous deux conçus pour être utilisés côté navigateur : la
// clé VAPID publique est l'"applicationServerKey" passée à
// pushManager.subscribe(), voir le module Notifications push de
// sudmaintenance.html), mais ils ne transitent jamais par cette fonction
// autrement qu'en sortie : stockés uniquement comme secrets Edge Function
// (`supabase secrets set MAPBOX_PUBLIC_TOKEN=...` / `VAPID_PUBLIC_KEY=...`),
// jamais commités. La clé VAPID PRIVÉE, elle, n'est lue que côté serveur par
// notify-admin-booking — jamais renvoyée ici.
//
// --no-verify-jwt au déploiement : cette fonction ne renvoie rien de
// sensible (elle n'expose jamais MAPBOX_SECRET_TOKEN, VAPID_PRIVATE_KEY,
// RESEND_API_KEY, etc., volontairement absents de la réponse) et doit être
// appelable par un visiteur non connecté dès le chargement de la page.

const MAPBOX_PUBLIC_TOKEN = Deno.env.get('MAPBOX_PUBLIC_TOKEN') || '';
const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY') || '';
// Clé de SITE Cloudflare Turnstile (publique, ~24 caractères). La clé
// SECRÈTE (TURNSTILE_SECRET_KEY) n'est lue que par verify-turnstile.
// Garde-fou : une clé secrète (35 caractères) saisie par erreur dans
// TURNSTILE_SITE_KEY n'est JAMAIS renvoyée au navigateur.
const RAW_TURNSTILE_SITE_KEY = (Deno.env.get('TURNSTILE_SITE_KEY') || '').trim();
const TURNSTILE_SITE_KEY = /^[0-3]x[0-9A-Za-z_-]{10,28}$/.test(RAW_TURNSTILE_SITE_KEY) ? RAW_TURNSTILE_SITE_KEY : '';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve((req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  return new Response(JSON.stringify({ mapboxPublicToken: MAPBOX_PUBLIC_TOKEN, vapidPublicKey: VAPID_PUBLIC_KEY, turnstileSiteKey: TURNSTILE_SITE_KEY }), {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...corsHeaders },
  });
});
