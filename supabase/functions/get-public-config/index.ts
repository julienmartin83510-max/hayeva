// Supabase Edge Function — sert au frontend les valeurs de configuration
// PUBLIQUES qui doivent néanmoins rester hors du code source HTML/JS et de
// Git (choix explicite du client), en particulier MAPBOX_PUBLIC_TOKEN.
//
// Un token public Mapbox n'est pas un secret au sens strict (il est conçu
// pour être utilisé côté navigateur), mais il ne transite jamais par cette
// fonction autrement qu'en sortie : stocké uniquement comme secret Edge
// Function (`supabase secrets set MAPBOX_PUBLIC_TOKEN=...`), jamais commité.
//
// --no-verify-jwt au déploiement : cette fonction ne renvoie rien de
// sensible (elle n'expose jamais MAPBOX_SECRET_TOKEN, RESEND_API_KEY, etc.,
// volontairement absents de la réponse) et doit être appelable par un
// visiteur non connecté dès le chargement de la page.

const MAPBOX_PUBLIC_TOKEN = Deno.env.get('MAPBOX_PUBLIC_TOKEN') || '';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve((req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  return new Response(JSON.stringify({ mapboxPublicToken: MAPBOX_PUBLIC_TOKEN }), {
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
});
