// Supabase Edge Function — calcule la VRAIE distance routière (Mapbox
// Directions API) entre le point de départ HAYEVA (travel_settings) et une
// adresse d'intervention, et renvoie un "devis de distance" SIGNÉ que le
// client transmettra tel quel à create_booking()/create_guest_or_quote_
// booking() (voir supabase/migrations/0009_mapbox_signed_distance.sql).
//
// SÉCURITÉ : MAPBOX_SECRET_TOKEN (Directions API) n'est utilisé que côté
// serveur, jamais transmis au navigateur. Le secret de signature du devis
// (quote_signing_secret) vit uniquement dans Supabase Vault, lu ici via
// get_quote_signing_secret() — accessible uniquement à service_role — plutôt
// que dupliqué comme secret Edge Function séparé (évite le problème de
// désynchronisation déjà rencontré avec WEBHOOK_SECRET). Un client ne peut
// donc jamais forger un devis valide : il ne connaît ni ce secret ni la
// distance réelle avant l'appel.
//
// Ne fabrique JAMAIS de distance : toute erreur (géocodage impossible,
// itinéraire introuvable, API indisponible) renvoie une erreur explicite,
// jamais une valeur par défaut.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MAPBOX_SECRET_TOKEN = Deno.env.get('MAPBOX_SECRET_TOKEN');

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  // Appelée via supabase-js (sb.client.functions.invoke), qui ajoute
  // automatiquement apikey/x-client-info en plus de authorization/
  // content-type — les omettre ici fait échouer le préflight CORS du
  // navigateur (aucune requête n'atteint alors la fonction du tout).
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

async function hmacSha256Hex(message: string, secret: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(message));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function base64Encode(input: string): string {
  const bytes = new TextEncoder().encode(input);
  let binary = '';
  bytes.forEach((b) => { binary += String.fromCharCode(b); });
  return btoa(binary);
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    if (!MAPBOX_SECRET_TOKEN) {
      console.error('calculate-travel-distance: MAPBOX_SECRET_TOKEN manquant.');
      return json({ status: 'unavailable', reason: 'config' }, 200);
    }

    const body = await req.json().catch(() => ({}));
    const lat = Number(body.lat);
    const lng = Number(body.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      return json({ status: 'unavailable', reason: 'invalid_coordinates' }, 200);
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: settings } = await supabase
      .from('travel_settings')
      .select('origin_lat, origin_lng')
      .eq('id', true)
      .maybeSingle();
    if (!settings) {
      console.error('calculate-travel-distance: travel_settings introuvable.');
      return json({ status: 'unavailable', reason: 'config' }, 200);
    }

    const originLng = settings.origin_lng;
    const originLat = settings.origin_lat;

    const directionsUrl =
      `https://api.mapbox.com/directions/v5/mapbox/driving/` +
      `${originLng},${originLat};${lng},${lat}` +
      `?access_token=${encodeURIComponent(MAPBOX_SECRET_TOKEN)}&overview=false&geometries=geojson`;

    const mapboxRes = await fetch(directionsUrl);
    if (!mapboxRes.ok) {
      console.error('calculate-travel-distance: échec Mapbox Directions', mapboxRes.status, await mapboxRes.text());
      return json({ status: 'unavailable', reason: 'routing_failed' }, 200);
    }
    const mapboxData = await mapboxRes.json();
    if (mapboxData.code !== 'Ok' || !Array.isArray(mapboxData.routes) || !mapboxData.routes[0]) {
      console.error('calculate-travel-distance: pas d\'itinéraire', mapboxData.code);
      return json({ status: 'unavailable', reason: 'no_route' }, 200);
    }

    const distanceMeters = mapboxData.routes[0].distance;
    if (!Number.isFinite(distanceMeters) || distanceMeters < 0) {
      return json({ status: 'unavailable', reason: 'invalid_response' }, 200);
    }
    const distanceKm = Math.round((distanceMeters / 1000) * 10) / 10;

    const { data: secretData, error: secretErr } = await supabase.rpc('get_quote_signing_secret');
    if (secretErr || !secretData) {
      console.error('calculate-travel-distance: secret de signature indisponible', secretErr);
      return json({ status: 'unavailable', reason: 'config' }, 200);
    }

    const payload = {
      lat, lng,
      distance_km: distanceKm,
      issued_at: Date.now(),
    };
    const payloadB64 = base64Encode(JSON.stringify(payload));
    const signature = await hmacSha256Hex(payloadB64, secretData as string);
    const quote = `${payloadB64}.${signature}`;

    return json({ status: 'ok', distanceKm, quote });
  } catch (err) {
    console.error('calculate-travel-distance: erreur inattendue', err);
    return json({ status: 'unavailable', reason: 'unexpected' }, 200);
  }
});
