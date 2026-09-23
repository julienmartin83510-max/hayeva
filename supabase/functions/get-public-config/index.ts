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

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve((req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  return new Response(JSON.stringify({ mapboxPublicToken: MAPBOX_PUBLIC_TOKEN, vapidPublicKey: VAPID_PUBLIC_KEY }), {
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
});
