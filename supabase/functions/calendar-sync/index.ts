// Supabase Edge Function — synchronisation Apple Calendar (iCloud / CalDAV)
// bidirectionnelle pour HAYEVA.
//
// DÉCLENCHEMENT :
//  - action='upsert' / 'delete' : trigger Postgres sync_booking_to_calendar()
//    (0063_apple_calendar_sync.sql), best-effort, jamais bloquant pour la
//    réservation elle-même.
//  - action='pull' : pg_cron toutes les 15 min (job hayeva-calendar-pull-cycle)
//    + bouton admin "Synchroniser maintenant" (admin_trigger_calendar_sync).
//  - action='setup' : bouton admin après saisie de l'identifiant Apple
//    (admin_trigger_calendar_setup) — découvre le compte CalDAV, crée/
//    retrouve le calendrier dédié "HAYEVA" et liste les calendriers
//    disponibles comme sources de blocage.
//  - action='diag' : vérifications réelles côté Apple (voir runDiag).
//
// AUTHENTIFICATION DE CET APPEL : secret partagé WEBHOOK_SECRET (même
// mécanisme pg_net que les autres triggers du projet) — jamais un JWT
// utilisateur, aucun admin n'est nécessairement connecté quand le cron ou
// le trigger se déclenchent.
//
// AUTHENTIFICATION CALDAV (Apple) : Basic Auth avec l'identifiant Apple
// (calendar_connections.apple_id_email) + un mot de passe d'application
// lu EXCLUSIVEMENT depuis Supabase Vault (secret apple_caldav_app_password,
// jamais dans le frontend, jamais dans les logs — voir redactError ci-
// dessous qui retire systématiquement les en-têtes Authorization avant
// toute trace).
//
// ANTI-BOUCLE (section 15 du cahier des charges) : tout événement créé par
// HAYEVA porte l'UID 'hayeva-<booking_id>'. Le pull ignore strictement tout
// UID commençant par 'hayeva-', qu'il revienne ou non dans la réponse
// CalDAV — jamais de doublon ni de ré-import de nos propres événements.
//
// CONFIDENTIALITÉ (section 20) : le pull ne stocke jamais le titre ni la
// description d'un événement Apple personnel — uniquement la plage
// horaire (starts_at/ends_at) dans external_busy_blocks, table sans aucune
// policy RLS pour anon/authenticated.
//
// PANNE ICLOUD : toute erreur réseau/CalDAV est capturée, journalisée
// (calendar_sync_log) et reportée sur calendar_connections.last_sync_error
// / bookings.calendar_sync_error — ne casse jamais HAYEVA (le système de
// réservation reste pleinement fonctionnel sans Apple Calendar).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET');

const CALDAV_ROOT = 'https://caldav.icloud.com';
const UID_PREFIX = 'hayeva-';
const HAYEVA_CALENDAR_DISPLAY_NAME = 'HAYEVA';
// Ancien nom prévu avant la mise en service réelle — reconnu pour ne jamais
// créer un second calendrier si celui-ci existe déjà côté Apple.
const LEGACY_HAYEVA_CALENDAR_NAMES = ['HAYEVA — Rendez-vous'];
// UID réservés aux tests contrôlés (action 'diag') — jamais un vrai événement.
const SELFTEST_UID_PREFIX = 'selftest-hayeva-';
const PULL_WINDOW_DAYS_PAST = 1;
const PULL_WINDOW_DAYS_FUTURE = 180;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

function redactError(err: unknown): string {
  const msg = err instanceof Error ? err.message : String(err);
  // Ne jamais laisser fuiter un en-tête Authorization/Basic dans un log/erreur.
  return msg.replace(/Basic\s+[A-Za-z0-9+/=]+/g, 'Basic [redacted]').slice(0, 2000);
}

async function logSync(direction: 'push' | 'pull', status: 'ok' | 'error', detail: string, bookingId?: string) {
  try {
    await supabase.from('calendar_sync_log').insert({ direction, status, detail: detail.slice(0, 4000), booking_id: bookingId || null });
  } catch (_e) {
    // best-effort uniquement
  }
}

// ------------------------------------------------------------
// Fuseau horaire — toutes les réservations HAYEVA sont en heure de Paris.
// ------------------------------------------------------------
function parisWallTimeToUtc(dateStr: string, timeStr: string): Date {
  return wallTimeToUtc(dateStr, timeStr, 'Europe/Paris');
}

function wallTimeToUtc(dateStr: string, timeStr: string, timeZone: string): Date {
  const [y, m, d] = dateStr.slice(0, 10).split('-').map(Number);
  const [hh, mm, ss] = timeStr.split(':').map((n) => Number(n || 0));
  let guess = new Date(Date.UTC(y, m - 1, d, hh, mm, ss || 0));
  for (let i = 0; i < 2; i++) {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone, hour12: false,
      year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
    }).formatToParts(guess).reduce((acc: Record<string, string>, p) => { acc[p.type] = p.value; return acc; }, {});
    const asIfParis = Date.UTC(+parts.year, +parts.month - 1, +parts.day, parts.hour === '24' ? 0 : +parts.hour, +parts.minute, +parts.second);
    const diff = Date.UTC(y, m - 1, d, hh, mm, ss || 0) - asIfParis;
    guess = new Date(guess.getTime() + diff);
  }
  return guess;
}

function parisMidnightToUtc(dateStr: string): Date {
  return parisWallTimeToUtc(dateStr, '00:00:00');
}

function icsUtc(d: Date): string {
  return d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

function icsEscape(s: string): string {
  return String(s || '').replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/,/g, '\\,').replace(/;/g, '\\;');
}

function foldLine(line: string): string {
  if (line.length <= 73) return line;
  let out = line.slice(0, 73);
  let rest = line.slice(73);
  while (rest.length > 0) {
    out += '\r\n ' + rest.slice(0, 72);
    rest = rest.slice(72);
  }
  return out;
}

// ------------------------------------------------------------
// CalDAV — requêtes HTTP de base avec Basic Auth.
// ------------------------------------------------------------
// iCloud renvoie parfois des 503/429 passagers (observé en test réel lors
// d'écritures rapprochées sur le même événement) : nouvelles tentatives
// avec attente croissante avant de considérer l'opération en échec. Toutes
// les opérations CalDAV utilisées ici (PUT à UID fixe, DELETE, PROPFIND,
// REPORT) sont idempotentes, donc rejouables sans risque de doublon.
const RETRYABLE_STATUSES = new Set([429, 500, 502, 503, 504]);
const RETRY_DELAYS_MS = [500, 1500, 4000];

async function caldavFetch(appleEmail: string, appPassword: string, url: string, method: string, body?: string, extraHeaders?: Record<string, string>) {
  const auth = 'Basic ' + btoa(`${appleEmail}:${appPassword}`);
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetch(url, {
        method,
        headers: { Authorization: auth, 'Content-Type': 'application/xml; charset=utf-8', Depth: '0', ...extraHeaders },
        body,
      });
      const text = await res.text();
      if (RETRYABLE_STATUSES.has(res.status) && attempt < RETRY_DELAYS_MS.length) {
        const retryAfter = Number(res.headers.get('retry-after'));
        const wait = Number.isFinite(retryAfter) && retryAfter > 0 ? Math.min(retryAfter * 1000, 8000) : RETRY_DELAYS_MS[attempt];
        await new Promise((r) => setTimeout(r, wait));
        continue;
      }
      return { ok: res.ok, status: res.status, text, headers: res.headers };
    } catch (netErr) {
      if (attempt < RETRY_DELAYS_MS.length) {
        await new Promise((r) => setTimeout(r, RETRY_DELAYS_MS[attempt]));
        continue;
      }
      throw new Error('caldav_network_error: ' + redactError(netErr));
    }
  }
}

// iCloud répond souvent avec des href absolus vers un serveur partitionné
// (https://pXX-caldav.icloud.com:443/...) : toujours résoudre un href par
// rapport à l'URL qui l'a renvoyé, jamais par simple concaténation.
function resolveHref(baseUrl: string, href: string): string {
  const u = new URL(href.trim(), baseUrl);
  if (u.port === '443') u.port = '';
  return u.toString();
}

function xmlUnescape(s: string): string {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
}

function extractAll(xml: string, tagRegex: RegExp): string[] {
  const out: string[] = [];
  let m: RegExpExecArray | null;
  const re = new RegExp(tagRegex, 'g');
  while ((m = re.exec(xml))) out.push(m[1]);
  return out;
}

function extractOne(xml: string, tagRegex: RegExp): string | null {
  const m = tagRegex.exec(xml);
  return m ? m[1] : null;
}

async function getAppPassword(): Promise<string> {
  const { data, error } = await supabase.rpc('get_apple_caldav_app_password');
  if (error) throw new Error('vault_read_failed: ' + error.message);
  if (!data) throw new Error('apple_caldav_app_password_not_set');
  return data as string;
}

// ------------------------------------------------------------
// Découverte CalDAV : principal -> calendar-home-set -> calendriers.
// Retourne des URL absolues (le serveur iCloud partitionné pXX-caldav est
// conservé tel que renvoyé par Apple).
// ------------------------------------------------------------
type DiscoveredCalendar = { url: string; displayName: string; supportsEvents: boolean };

async function discoverCalendars(email: string, appPassword: string) {
  const principalBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:"><D:prop><D:current-user-principal/></D:prop></D:propfind>`;
  const rootUrl = CALDAV_ROOT + '/';
  const principalRes = await caldavFetch(email, appPassword, rootUrl, 'PROPFIND', principalBody, { Depth: '0' });
  if (principalRes.status === 401) throw new Error('apple_auth_refused_401');
  if (!principalRes.ok) throw new Error(`propfind_principal_failed_${principalRes.status}`);
  const principalHref = extractOne(principalRes.text, /<[^:>]*:?current-user-principal[^>]*>\s*<[^:>]*:?href[^>]*>([^<]+)<\/[^:>]*:?href>/i);
  if (!principalHref) throw new Error('principal_href_not_found');
  const principalUrl = resolveHref(rootUrl, xmlUnescape(principalHref));

  const homeSetBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><C:calendar-home-set/></D:prop></D:propfind>`;
  const homeSetRes = await caldavFetch(email, appPassword, principalUrl, 'PROPFIND', homeSetBody, { Depth: '0' });
  if (!homeSetRes.ok) throw new Error(`propfind_homeset_failed_${homeSetRes.status}`);
  const homeHref = extractOne(homeSetRes.text, /<[^:>]*:?calendar-home-set[^>]*>\s*<[^:>]*:?href[^>]*>([^<]+)<\/[^:>]*:?href>/i);
  if (!homeHref) throw new Error('calendar_home_href_not_found');
  let homeUrl = resolveHref(principalUrl, xmlUnescape(homeHref));
  if (!homeUrl.endsWith('/')) homeUrl += '/';

  const listBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<D:prop><D:resourcetype/><D:displayname/><C:supported-calendar-component-set/></D:prop>
</D:propfind>`;
  const listRes = await caldavFetch(email, appPassword, homeUrl, 'PROPFIND', listBody, { Depth: '1' });
  if (!listRes.ok) throw new Error(`propfind_list_failed_${listRes.status}`);

  const responseBlocks = extractAll(listRes.text, /<[^:>]*:?response[^>]*>([\s\S]*?)<\/[^:>]*:?response>/i);
  const calendars: DiscoveredCalendar[] = [];
  for (const block of responseBlocks) {
    if (!/<[^:>]*:?resourcetype[^>]*>[\s\S]*?<[^:>]*:?calendar[\s/>]/i.test(block)) continue;
    const href = extractOne(block, /<[^:>]*:?href[^>]*>([^<]+)<\/[^:>]*:?href>/i);
    if (!href) continue;
    const url = resolveHref(homeUrl, xmlUnescape(href));
    const rawName = extractOne(block, /<[^:>]*:?displayname[^>]*>([^<]*)<\/[^:>]*:?displayname>/i);
    const displayName = rawName ? xmlUnescape(rawName).trim() : url;
    const compSet = extractOne(block, /<[^:>]*:?supported-calendar-component-set[^>]*>([\s\S]*?)<\/[^:>]*:?supported-calendar-component-set>/i);
    // Absence de l'information = on suppose des événements (prudence).
    const supportsEvents = !compSet || /name=["']VEVENT["']/i.test(compSet);
    calendars.push({ url, displayName, supportsEvents });
  }
  return { principalUrl, homeUrl, calendars };
}

// ------------------------------------------------------------
// Action: setup — vrai test d'authentification iCloud + découverte des
// calendriers + calendrier dédié "HAYEVA" (retrouvé s'il existe, créé UNE
// seule fois sinon).
// ------------------------------------------------------------
async function runSetup() {
  const { data: conn, error: connErr } = await supabase.from('calendar_connections').select('*').order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (connErr) throw connErr;
  if (!conn?.apple_id_email) throw new Error('apple_id_email_missing');
  const appPassword = await getAppPassword();
  const email = conn.apple_id_email as string;

  const { principalUrl, homeUrl, calendars } = await discoverCalendars(email, appPassword);

  // 1) URL déjà enregistrée toujours présente côté Apple, 2) nom exact
  // "HAYEVA", 3) ancien nom — jamais un second calendrier HAYEVA.
  let hayevaCal = calendars.find((c) => conn.target_calendar_url && c.url === conn.target_calendar_url)
    || calendars.find((c) => c.displayName === HAYEVA_CALENDAR_DISPLAY_NAME)
    || calendars.find((c) => LEGACY_HAYEVA_CALENDAR_NAMES.includes(c.displayName));
  let created = false;
  if (!hayevaCal) {
    const newUrl = homeUrl + 'hayeva-' + crypto.randomUUID() + '/';
    const mkcalBody = `<?xml version="1.0" encoding="utf-8"?>
<C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<D:set><D:prop><D:displayname>${HAYEVA_CALENDAR_DISPLAY_NAME}</D:displayname>
<C:supported-calendar-component-set><C:comp name="VEVENT"/></C:supported-calendar-component-set>
</D:prop></D:set>
</C:mkcalendar>`;
    const mkcalRes = await caldavFetch(email, appPassword, newUrl, 'MKCALENDAR', mkcalBody, { Depth: '0' });
    if (!mkcalRes.ok) throw new Error(`mkcalendar_failed_${mkcalRes.status}`);
    hayevaCal = { url: newUrl, displayName: HAYEVA_CALENDAR_DISPLAY_NAME, supportsEvents: true };
    created = true;
  }

  await supabase.from('calendar_connections').update({
    connected: true,
    caldav_principal_url: principalUrl,
    target_calendar_url: hayevaCal.url,
    target_calendar_display_name: hayevaCal.displayName,
    last_sync_error: null,
    updated_at: new Date().toISOString(),
  }).eq('id', conn.id);

  // Sources de blocage : uniquement les calendriers d'événements autres que
  // HAYEVA. Un calendrier nouvellement détecté est bloquant par défaut
  // (prudence anti double réservation) ; un choix déjà fait par
  // l'administrateur n'est JAMAIS écrasé (ignoreDuplicates).
  const sourceCals = calendars.filter((c) => c.url !== hayevaCal!.url && c.supportsEvents);
  if (sourceCals.length > 0) {
    await supabase.from('calendar_blocking_sources').upsert(
      sourceCals.map((c) => ({ connection_id: conn.id, calendar_url: c.url, display_name: c.displayName, is_blocking: true })),
      { onConflict: 'connection_id,calendar_url', ignoreDuplicates: true },
    );
    for (const c of sourceCals) {
      await supabase.from('calendar_blocking_sources').update({ display_name: c.displayName }).eq('connection_id', conn.id).eq('calendar_url', c.url);
    }
  }
  // Calendriers qui n'existent plus côté Apple (ou entrées de test) : retirés.
  const keepUrls = new Set(sourceCals.map((c) => c.url));
  const { data: existingSources } = await supabase.from('calendar_blocking_sources').select('id, calendar_url').eq('connection_id', conn.id);
  const staleSourceIds = (existingSources || []).filter((s) => !keepUrls.has(s.calendar_url)).map((s) => s.id);
  if (staleSourceIds.length > 0) await supabase.from('calendar_blocking_sources').delete().in('id', staleSourceIds);

  await logSync('pull', 'ok', `setup_ok: calendrier ${hayevaCal.displayName}${created ? ' (créé)' : ' (existant)'}, ${sourceCals.length} calendrier(s) source`);
  return {
    authenticated: true,
    hayeva_calendar: { name: hayevaCal.displayName, created },
    calendars: calendars.map((c) => ({ name: c.displayName, events: c.supportsEvents, is_hayeva: c.url === hayevaCal!.url })),
  };
}

// ------------------------------------------------------------
// Action: upsert — push création/mise à jour (confirmation, déplacement).
// L'UID déterministe (hayeva-<booking_id>) rend le PUT idempotent : un
// déplacement ré-envoie le même UID à la même URL, Apple remplace
// l'événement existant — jamais de doublon.
// ------------------------------------------------------------
async function runUpsert(bookingId: string) {
  const { data: conn } = await supabase.from('calendar_connections').select('*').order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (!conn?.connected || !conn.target_calendar_url) {
    await supabase.from('bookings').update({ calendar_sync_status: 'NOT_SYNCED', calendar_sync_error: 'Agenda Apple non connecté.' }).eq('id', bookingId);
    return;
  }

  const { data: booking, error: bErr } = await supabase
    .from('bookings')
    .select(`
      id, reference, date, start_time, service_duration_minutes, notes,
      guest_name, guest_email, guest_phone, guest_address,
      customer_user_id, customer_address_id, client_id,
      services(name, category, description),
      customer_addresses(address, postal_code, city)
    `)
    .eq('id', bookingId).maybeSingle();
  if (bErr) throw bErr;
  if (!booking) throw new Error('booking_not_found');

  let clientName = booking.guest_name || '';
  let clientPhone = booking.guest_phone || '';
  let clientEmail = booking.guest_email || '';
  let clientAddress = booking.guest_address || '';
  // Fiche client CRM (réservations rattachées à un compte / nouveau parcours).
  if ((booking as any).client_id) {
    const { data: cl } = await supabase.from('clients')
      .select('first_name,last_name,email,phone,address,postal_code,city')
      .eq('id', (booking as any).client_id).maybeSingle();
    if (cl) {
      clientName = [cl.first_name, cl.last_name].filter(Boolean).join(' ') || clientName;
      clientPhone = cl.phone || clientPhone;
      clientEmail = cl.email || clientEmail;
      if (!clientAddress) clientAddress = [cl.address, cl.postal_code, cl.city].filter(Boolean).join(', ');
    }
  }
  if (booking.customer_user_id) {
    const { data: cp } = await supabase.from('customer_profiles').select('first_name,last_name,phone').eq('user_id', booking.customer_user_id).maybeSingle();
    if (cp) {
      clientName = [cp.first_name, cp.last_name].filter(Boolean).join(' ') || clientName;
      clientPhone = cp.phone || clientPhone;
    }
  }
  const addr = (booking as any).customer_addresses;
  if (addr) clientAddress = [addr.address, addr.postal_code, addr.city].filter(Boolean).join(', ') || clientAddress;

  const service = (booking as any).services;
  const serviceName = service?.name || 'Intervention';
  const category = service?.category || '';
  const duration = booking.service_duration_minutes || 60;

  const dtStart = parisWallTimeToUtc(booking.date as string, booking.start_time as string);
  const dtEnd = new Date(dtStart.getTime() + duration * 60000);
  const uid = UID_PREFIX + booking.id;

  const descriptionLines = [
    `Client : ${clientName || 'non renseigné'}`,
    `Téléphone : ${clientPhone || 'non renseigné'}`,
    `Email : ${clientEmail || 'non renseigné'}`,
    `Type : ${serviceName}`,
    category ? `Catégorie : ${category}` : null,
    service?.description ? `Description : ${service.description}` : null,
    booking.notes ? `Notes : ${booking.notes}` : null,
    `Référence HAYEVA : ${booking.reference || booking.id}`,
  ].filter(Boolean).join('\n'); // vrai saut de ligne : icsEscape le convertit en \n ICS

  const summary = `HAYEVA — ${serviceName} — ${clientName || 'Client'}`;

  const vevent = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//HAYEVA//Calendar Sync//FR',
    'BEGIN:VEVENT',
    `UID:${uid}`,
    `DTSTAMP:${icsUtc(new Date())}`,
    `DTSTART:${icsUtc(dtStart)}`,
    `DTEND:${icsUtc(dtEnd)}`,
    foldLine(`SUMMARY:${icsEscape(summary)}`),
    foldLine(`DESCRIPTION:${icsEscape(descriptionLines)}`),
    clientAddress ? foldLine(`LOCATION:${icsEscape(clientAddress)}`) : null,
    'END:VEVENT',
    'END:VCALENDAR',
  ].filter(Boolean).join('\r\n');

  const eventUrl = conn.target_calendar_url.replace(/\/$/, '') + '/' + uid + '.ics';
  const putRes = await caldavFetch(conn.apple_id_email, await getAppPassword(), eventUrl, 'PUT', vevent, {
    'Content-Type': 'text/calendar; charset=utf-8',
  });
  if (!putRes.ok) throw new Error(`caldav_put_failed_${putRes.status}`);

  await supabase.from('bookings').update({
    calendar_event_uid: uid, calendar_sync_status: 'SYNCED', calendar_last_sync_at: new Date().toISOString(), calendar_sync_error: null,
  }).eq('id', bookingId);
  await supabase.from('calendar_connections').update({ last_push_sync_at: new Date().toISOString(), last_sync_error: null }).eq('id', conn.id);
  await logSync('push', 'ok', `upsert_ok uid=${uid}`, bookingId);
}

// ------------------------------------------------------------
// Action: delete — push annulation. Idempotent : un 404 (déjà absent) est
// traité comme un succès.
// ------------------------------------------------------------
async function runDelete(bookingId: string, payloadUid?: string) {
  const { data: conn } = await supabase.from('calendar_connections').select('*').order('created_at', { ascending: false }).limit(1).maybeSingle();
  const { data: booking } = await supabase.from('bookings').select('calendar_event_uid').eq('id', bookingId).maybeSingle();
  // Réservation supprimée de la base : l'UID est transmis par le trigger
  // AFTER DELETE. On n'accepte que l'UID déterministe de CETTE réservation.
  const expectedUid = UID_PREFIX + bookingId;
  const uid = booking?.calendar_event_uid || (!booking && payloadUid === expectedUid ? payloadUid : null);
  if (!booking && uid) {
    if (!conn?.connected || !conn.target_calendar_url) throw new Error('not_connected');
    const url = conn.target_calendar_url.replace(/\/$/, '') + '/' + uid + '.ics';
    const r = await caldavFetch(conn.apple_id_email, await getAppPassword(), url, 'DELETE', undefined, {});
    if (!r.ok && r.status !== 404) throw new Error(`caldav_delete_failed_${r.status}`);
    await logSync('push', 'ok', `delete_ok (booking supprimée) uid=${uid}`);
    return;
  }
  if (!conn?.connected || !conn.target_calendar_url || !uid) {
    await supabase.from('bookings').update({ calendar_sync_status: 'NOT_SYNCED', calendar_event_uid: null }).eq('id', bookingId);
    return;
  }

  const eventUrl = conn.target_calendar_url.replace(/\/$/, '') + '/' + uid + '.ics';
  const delRes = await caldavFetch(conn.apple_id_email, await getAppPassword(), eventUrl, 'DELETE', undefined, {});
  if (!delRes.ok && delRes.status !== 404) throw new Error(`caldav_delete_failed_${delRes.status}`);

  await supabase.from('bookings').update({
    calendar_sync_status: 'NOT_SYNCED', calendar_event_uid: null, calendar_last_sync_at: new Date().toISOString(), calendar_sync_error: null,
  }).eq('id', bookingId);
  await supabase.from('calendar_connections').update({ last_push_sync_at: new Date().toISOString(), last_sync_error: null }).eq('id', conn.id);
  await logSync('push', 'ok', `delete_ok uid=${uid}`, bookingId);
}

// ------------------------------------------------------------
// RRULE — expansion minimale (DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL,
// COUNT, UNTIL, BYDAY pour WEEKLY), bornée à la fenêtre de pull. Une règle
// non reconnue ne bloque jamais tout le pull : l'occurrence de base
// (DTSTART) est conservée par prudence (mieux bloquer un créneau en trop
// que manquer un vrai conflit).
// ------------------------------------------------------------
const BYDAY_MAP: Record<string, number> = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

function wallParts(d: Date, timeZone: string) {
  const p = new Intl.DateTimeFormat('en-US', {
    timeZone, hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(d).reduce((acc: Record<string, string>, x) => { acc[x.type] = x.value; return acc; }, {});
  return { y: +p.year, m: +p.month, d: +p.day, time: `${p.hour === '24' ? '00' : p.hour}:${p.minute}:${p.second}` };
}

// L'expansion se fait en heure "murale" du fuseau de l'événement : un
// rendez-vous hebdomadaire à 10:00 reste à 10:00 de part et d'autre d'un
// changement d'heure (jamais décalé d'une heure).
function expandRrule(dtStart: Date, durationMs: number, rrule: string, windowStart: Date, windowEnd: Date, timeZone: string): Date[] {
  const parts: Record<string, string> = {};
  for (const kv of rrule.split(';')) {
    const [k, v] = kv.split('=');
    if (k) parts[k.toUpperCase()] = v;
  }
  const freq = parts.FREQ;
  const interval = Math.max(1, parseInt(parts.INTERVAL || '1', 10) || 1);
  const count = parts.COUNT ? parseInt(parts.COUNT, 10) : null;
  let until: Date | null = null;
  if (parts.UNTIL) {
    const u = parts.UNTIL;
    until = u.length <= 8
      ? new Date(Date.UTC(+u.slice(0, 4), +u.slice(4, 6) - 1, +u.slice(6, 8), 23, 59, 59))
      : new Date(`${u.slice(0, 4)}-${u.slice(4, 6)}-${u.slice(6, 8)}T${u.slice(9, 11)}:${u.slice(11, 13)}:${u.slice(13, 15)}Z`);
  }
  const byday = parts.BYDAY ? parts.BYDAY.split(',').map((d) => BYDAY_MAP[d.slice(-2)]).filter((n) => n !== undefined) : null;

  const w = wallParts(dtStart, timeZone);
  const toUtc = (day: Date) => wallTimeToUtc(day.toISOString().slice(0, 10), w.time, timeZone);
  const startDay = new Date(Date.UTC(w.y, w.m - 1, w.d));

  const occurrences: Date[] = [];
  let cursor = new Date(startDay);
  let n = 0;
  const hardCap = 1500;
  const inWindow = (t: Date) => t.getTime() + durationMs >= windowStart.getTime() && t.getTime() <= windowEnd.getTime();

  for (let guard = 0; guard < 5000 && occurrences.length < hardCap; guard++) {
    const cursorUtc = toUtc(cursor);
    if (cursorUtc.getTime() > windowEnd.getTime()) break;
    if (count !== null && n >= count) break;
    if (until && cursorUtc.getTime() > until.getTime()) break;

    if (!byday || freq !== 'WEEKLY') {
      if (inWindow(cursorUtc)) occurrences.push(cursorUtc);
      n++;
    } else {
      for (const wd of byday) {
        const day = new Date(cursor);
        day.setUTCDate(day.getUTCDate() + ((wd - day.getUTCDay() + 7) % 7));
        const occ = toUtc(day);
        if (occ.getTime() < dtStart.getTime()) continue;
        if (until && occ.getTime() > until.getTime()) continue;
        if (count !== null && n >= count) break;
        n++;
        if (inWindow(occ)) occurrences.push(occ);
      }
    }

    if (freq === 'DAILY') cursor.setUTCDate(cursor.getUTCDate() + interval);
    else if (freq === 'WEEKLY') cursor.setUTCDate(cursor.getUTCDate() + interval * 7);
    else if (freq === 'MONTHLY') cursor.setUTCMonth(cursor.getUTCMonth() + interval);
    else if (freq === 'YEARLY') cursor.setUTCFullYear(cursor.getUTCFullYear() + interval);
    else break; // FREQ non supportée : seule l'occurrence de base est conservée
  }
  return occurrences;
}

function parseIcsDate(raw: string, valueIsDate: boolean, tzid?: string | null): Date {
  if (valueIsDate) {
    const y = +raw.slice(0, 4), m = +raw.slice(4, 6), d = +raw.slice(6, 8);
    return parisMidnightToUtc(`${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`);
  }
  if (/Z$/.test(raw)) {
    const y = raw.slice(0, 4), m = raw.slice(4, 6), d = raw.slice(6, 8), hh = raw.slice(9, 11), mm = raw.slice(11, 13), ss = raw.slice(13, 15);
    return new Date(`${y}-${m}-${d}T${hh}:${mm}:${ss}Z`);
  }
  // Heure locale : TZID de la ligne si Intl le connaît, sinon Europe/Paris
  // (cohérent avec le reste de HAYEVA).
  const y = raw.slice(0, 4), m = raw.slice(4, 6), d = raw.slice(6, 8), hh = raw.slice(9, 11) || '00', mm = raw.slice(11, 13) || '00', ss = raw.slice(13, 15) || '00';
  let zone = 'Europe/Paris';
  if (tzid) {
    try { new Intl.DateTimeFormat('en-US', { timeZone: tzid }); zone = tzid; } catch (_e) { /* TZID non standard */ }
  }
  return wallTimeToUtc(`${y}-${m}-${d}`, `${hh}:${mm}:${ss}`, zone);
}

// Déplie les lignes ICS repliées (RFC 5545 §3.1) avant toute analyse.
function unfoldIcs(text: string): string {
  return text.replace(/\r?\n[ \t]/g, '');
}

function parseVeventLine(block: string, name: string): { raw: string; isDate: boolean; tzid: string | null } | null {
  const re = new RegExp(`(?:^|\\r?\\n)${name}(;[^:\\r\\n]*)?:([^\\r\\n]+)`, 'i');
  const m = re.exec(block);
  if (!m) return null;
  const params = m[1] || '';
  const tz = /TZID=("?)([^;:"]+)\1/i.exec(params);
  return { raw: m[2].trim(), isDate: /VALUE=DATE(?!-TIME)/i.test(params), tzid: tz ? tz[2] : null };
}

// ------------------------------------------------------------
// Action: pull — importe les créneaux occupés depuis chaque calendrier
// Apple marqué comme bloquant.
// ------------------------------------------------------------
async function runPull() {
  const { data: conn } = await supabase.from('calendar_connections').select('*').order('created_at', { ascending: false }).limit(1).maybeSingle();
  // Non connecté : rien à importer, et surtout pas une "erreur" répétée
  // toutes les 15 minutes dans le journal.
  if (!conn?.connected) return { skipped: 'not_connected' };

  const appPassword = await getAppPassword();
  const retried = await retryFailedPushes();
  const { data: sources } = await supabase.from('calendar_blocking_sources').select('*').eq('connection_id', conn.id).eq('is_blocking', true);

  const now = new Date();
  const windowStart = new Date(now.getTime() - PULL_WINDOW_DAYS_PAST * 86400000);
  const windowEnd = new Date(now.getTime() + PULL_WINDOW_DAYS_FUTURE * 86400000);
  const wStartIcs = icsUtc(windowStart);
  const wEndIcs = icsUtc(windowEnd);

  let anyError: string | null = null;
  const summary: Array<{ source: string; events: number; error?: string }> = [];

  for (const source of sources || []) {
    try {
      const reportBody = `<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<D:prop><D:getetag/><C:calendar-data/></D:prop>
<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
<C:time-range start="${wStartIcs}" end="${wEndIcs}"/>
</C:comp-filter></C:comp-filter></C:filter>
</C:calendar-query>`;
      const res = await caldavFetch(conn.apple_id_email, appPassword, source.calendar_url, 'REPORT', reportBody, { Depth: '1' });
      if (!res.ok) throw new Error(`caldav_report_failed_${res.status}`);

      const seenUids = new Set<string>();
      const eventBlocks = extractAll(unfoldIcs(xmlUnescape(res.text)), /BEGIN:VEVENT([\s\S]*?)END:VEVENT/i);
      const rows: Array<{ source_id: string; external_uid: string; starts_at: string; ends_at: string; is_all_day: boolean }> = [];

      for (const block of eventBlocks) {
        const uidMatch = /(?:^|\r?\n)UID:([^\r\n]+)/i.exec(block);
        const uid = uidMatch ? uidMatch[1].trim() : null;
        if (!uid || uid.startsWith(UID_PREFIX)) continue; // anti-boucle : jamais nos propres événements

        const dtStartLine = parseVeventLine(block, 'DTSTART');
        if (!dtStartLine) continue;
        // Événement "disponible" (TRANSP:TRANSPARENT) : ne bloque pas.
        if (/(?:^|\r?\n)TRANSP:TRANSPARENT/i.test(block)) continue;
        if (/(?:^|\r?\n)STATUS:CANCELLED/i.test(block)) continue;
        const dtStart = parseIcsDate(dtStartLine.raw, dtStartLine.isDate, dtStartLine.tzid);

        const dtEndLine = parseVeventLine(block, 'DTEND');
        const durationLine = parseVeventLine(block, 'DURATION');
        let dtEnd: Date;
        if (dtEndLine) dtEnd = parseIcsDate(dtEndLine.raw, dtEndLine.isDate, dtEndLine.tzid);
        else if (durationLine) {
          const dm = /P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?/.exec(durationLine.raw);
          const days = dm ? +(dm[1] || 0) : 0, hrs = dm ? +(dm[2] || 0) : 0, mins = dm ? +(dm[3] || 0) : 0;
          dtEnd = new Date(dtStart.getTime() + (days * 86400 + hrs * 3600 + mins * 60) * 1000);
        } else dtEnd = new Date(dtStart.getTime() + 3600000);

        const durationMs = dtEnd.getTime() - dtStart.getTime();
        const rruleLine = parseVeventLine(block, 'RRULE');

        if (rruleLine) {
          const zone = dtStartLine.isDate ? 'Europe/Paris' : (dtStartLine.tzid && (() => { try { new Intl.DateTimeFormat('en-US', { timeZone: dtStartLine.tzid! }); return true; } catch (_e) { return false; } })() ? dtStartLine.tzid : 'Europe/Paris');
          // EXDATE : occurrences supprimées côté Apple.
          const exdates = new Set<number>();
          for (const m of block.matchAll(/(?:^|\r?\n)EXDATE(;[^:\r\n]*)?:([^\r\n]+)/gi)) {
            const tz = /TZID=("?)([^;:"]+)\1/i.exec(m[1] || '');
            for (const v of m[2].split(',')) exdates.add(parseIcsDate(v.trim(), /VALUE=DATE(?!-TIME)/i.test(m[1] || ''), tz ? tz[2] : dtStartLine.tzid).getTime());
          }
          const occStarts = expandRrule(dtStart, durationMs, rruleLine.raw, windowStart, windowEnd, zone).filter((o) => !exdates.has(o.getTime()));
          for (const occStart of occStarts) {
            const occUid = `${uid}_${occStart.getTime()}`;
            if (seenUids.has(occUid)) continue;
            seenUids.add(occUid);
            rows.push({ source_id: source.id, external_uid: occUid, starts_at: occStart.toISOString(), ends_at: new Date(occStart.getTime() + durationMs).toISOString(), is_all_day: !!dtStartLine.isDate });
          }
        } else {
          // Occurrence modifiée d'une série (RECURRENCE-ID) : clé distincte.
          const recId = parseVeventLine(block, 'RECURRENCE-ID');
          const key = recId ? `${uid}_rid_${recId.raw}` : uid;
          if (seenUids.has(key)) continue;
          seenUids.add(key);
          if (dtEnd.getTime() < windowStart.getTime() || dtStart.getTime() > windowEnd.getTime()) continue;
          rows.push({ source_id: source.id, external_uid: key, starts_at: dtStart.toISOString(), ends_at: dtEnd.toISOString(), is_all_day: !!dtStartLine.isDate });
        }
      }

      if (rows.length > 0) {
        const { error: upErr } = await supabase.from('external_busy_blocks').upsert(
          rows.map((r) => ({ ...r, synced_at: new Date().toISOString() })),
          { onConflict: 'source_id,external_uid' },
        );
        if (upErr) throw upErr;
      }

      // Nettoie les blocages de cette source qui ne sont plus présents côté
      // Apple (événement supprimé/déplacé hors fenêtre) — DELETE direct via
      // supabase-js (PostgREST), sans rapport avec la confirmation
      // destructive propre aux outils d'administration interactifs.
      const keepUids = rows.map((r) => r.external_uid);
      const { data: existing } = await supabase.from('external_busy_blocks').select('id, external_uid').eq('source_id', source.id);
      const staleIds = (existing || []).filter((e) => !keepUids.includes(e.external_uid)).map((e) => e.id);
      if (staleIds.length > 0) await supabase.from('external_busy_blocks').delete().in('id', staleIds);

      await logSync('pull', 'ok', `source=${source.display_name || source.calendar_url} events=${rows.length}`);
      summary.push({ source: source.display_name || 'calendrier', events: rows.length });
    } catch (sourceErr) {
      anyError = redactError(sourceErr);
      await logSync('pull', 'error', `source=${source.display_name || source.calendar_url}: ${anyError}`);
      summary.push({ source: source.display_name || 'calendrier', events: 0, error: anyError });
    }
  }

  await supabase.from('calendar_connections').update({
    last_pull_sync_at: new Date().toISOString(),
    last_sync_error: anyError,
  }).eq('id', conn.id);
  return { sources: summary, retried };
}

// Rattrapage des envois vers Apple restés en échec (iCloud indisponible au
// moment de la confirmation / du déplacement / de l'annulation) : rejoués
// à chaque cycle de 15 minutes, sans action manuelle. Bornée pour ne jamais
// allonger excessivement un cycle.
async function retryFailedPushes() {
  const today = new Date().toISOString().slice(0, 10);
  const { data: failed } = await supabase.from('bookings')
    .select('id, status, calendar_event_uid')
    .in('calendar_sync_status', ['ERROR', 'PENDING'])
    .gte('date', today)
    .order('date', { ascending: true })
    .limit(20);
  let ok = 0, ko = 0;
  for (const b of failed || []) {
    try {
      if (b.status === 'CANCELLED' || b.status === 'NO_SHOW') {
        if (b.calendar_event_uid) await runDelete(b.id);
        else await supabase.from('bookings').update({ calendar_sync_status: 'NOT_SYNCED', calendar_sync_error: null }).eq('id', b.id);
      } else if (b.status === 'CONFIRMED' || b.status === 'IN_PROGRESS' || b.status === 'COMPLETED') {
        await runUpsert(b.id);
      } else {
        continue;
      }
      ok++;
    } catch (e) {
      ko++;
      const detail = redactError(e);
      await supabase.from('bookings').update({ calendar_sync_status: 'ERROR', calendar_sync_error: detail }).eq('id', b.id);
      await logSync('push', 'error', `retry_failed: ${detail}`, b.id);
    }
  }
  return { ok, ko };
}

// ------------------------------------------------------------
// Action: diag — vérification réelle côté Apple, réservée au secret
// serveur (jamais appelable depuis le frontend) :
//  - target_events : lit le calendrier HAYEVA et renvoie UNIQUEMENT les
//    événements créés par HAYEVA (UID hayeva-*), jamais d'autre contenu.
//  - selftest_put / selftest_delete : crée/supprime un événement de test
//    contrôlé (UID selftest-hayeva-*) dans un calendrier source, pour tester
//    réellement Apple -> HAYEVA. Aucun autre UID n'est jamais modifiable.
// ------------------------------------------------------------
async function runDiag(payload: Record<string, any>) {
  const { data: conn } = await supabase.from('calendar_connections').select('*').order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (!conn?.connected || !conn.target_calendar_url) throw new Error('not_connected');
  const appPassword = await getAppPassword();

  if (payload.op === 'target_events') {
    const body = `<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<D:prop><D:getetag/><C:calendar-data/></D:prop>
<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"/></C:comp-filter></C:filter>
</C:calendar-query>`;
    const res = await caldavFetch(conn.apple_id_email, appPassword, conn.target_calendar_url, 'REPORT', body, { Depth: '1' });
    if (!res.ok) throw new Error(`caldav_report_failed_${res.status}`);
    const text = unfoldIcs(xmlUnescape(res.text));
    const events = extractAll(text, /BEGIN:VEVENT([\s\S]*?)END:VEVENT/i).map((b) => {
      const get = (n: string) => { const m = new RegExp(`(?:^|\\r?\\n)${n}(?:;[^:\\r\\n]*)?:([^\\r\\n]*)`, 'i').exec(b); return m ? m[1] : null; };
      return { uid: get('UID'), dtstart: get('DTSTART'), dtend: get('DTEND'), summary: get('SUMMARY'), description: get('DESCRIPTION'), location: get('LOCATION') };
    }).filter((e) => e.uid && e.uid.startsWith(UID_PREFIX));
    return { calendar: conn.target_calendar_display_name, hayeva_events: events };
  }

  if (payload.op === 'selftest_put' || payload.op === 'selftest_delete') {
    const { data: source } = await supabase.from('calendar_blocking_sources').select('*').eq('id', payload.source_id).maybeSingle();
    if (!source) throw new Error('source_not_found');
    const uid = String(payload.uid || '');
    if (!uid.startsWith(SELFTEST_UID_PREFIX) || !/^[a-z0-9-]+$/.test(uid)) throw new Error('selftest_uid_refused');
    const url = source.calendar_url.replace(/\/$/, '') + '/' + uid + '.ics';
    if (payload.op === 'selftest_delete') {
      const r = await caldavFetch(conn.apple_id_email, appPassword, url, 'DELETE', undefined, {});
      return { deleted: r.ok || r.status === 404, status: r.status };
    }
    const start = new Date(payload.starts_at), end = new Date(payload.ends_at);
    if (isNaN(start.getTime()) || isNaN(end.getTime()) || end <= start) throw new Error('selftest_invalid_range');
    const ics = [
      'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//HAYEVA//Selftest//FR', 'BEGIN:VEVENT',
      `UID:${uid}`, `DTSTAMP:${icsUtc(new Date())}`, `DTSTART:${icsUtc(start)}`, `DTEND:${icsUtc(end)}`,
      'SUMMARY:TEST PRIVE HAYEVA - titre confidentiel', 'DESCRIPTION:Note privee de test - ne doit jamais etre visible par un client',
      'END:VEVENT', 'END:VCALENDAR',
    ].join('\r\n');
    const r = await caldavFetch(conn.apple_id_email, appPassword, url, 'PUT', ics, { 'Content-Type': 'text/calendar; charset=utf-8' });
    if (!r.ok) throw new Error(`selftest_put_failed_${r.status}`);
    return { created: true, status: r.status };
  }
  throw new Error('invalid_diag_op');
}

Deno.serve(async (req: Request) => {
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  let payload: Record<string, any> = {};
  try {
    if (!WEBHOOK_SECRET || req.headers.get('authorization') !== `Bearer ${WEBHOOK_SECRET}`) {
      return json({ error: 'unauthorized' }, 401);
    }
    payload = await req.json().catch(() => ({}));
    const action = payload.action;

    if (action === 'setup') {
      return json({ ok: true, action, result: await runSetup() });
    }
    if (action === 'pull') {
      return json({ ok: true, action, result: await runPull() });
    }
    if (action === 'diag') {
      return json({ ok: true, action, result: await runDiag(payload) });
    }
    if ((action === 'upsert' || action === 'delete') && payload.booking_id) {
      if (action === 'upsert') await runUpsert(payload.booking_id);
      else await runDelete(payload.booking_id, typeof payload.uid === 'string' ? payload.uid : undefined);
      return json({ ok: true, action, booking_id: payload.booking_id });
    }
    return json({ error: 'invalid_action' }, 400);
  } catch (err) {
    const detail = redactError(err);
    console.error('calendar-sync: erreur', detail);
    if (payload?.action === 'diag') return json({ ok: false, error: detail }, 200);
    try {
      if (payload?.booking_id) {
        await supabase.from('bookings').update({ calendar_sync_status: 'ERROR', calendar_sync_error: detail }).eq('id', payload.booking_id);
      }
      const { data: connRow } = await supabase.from('calendar_connections').select('id').order('created_at', { ascending: false }).limit(1).maybeSingle();
      if (connRow) await supabase.from('calendar_connections').update({ last_sync_error: detail }).eq('id', connRow.id);
      await logSync(payload?.action === 'pull' || payload?.action === 'setup' ? 'pull' : 'push', 'error', detail, payload?.booking_id);
    } catch (_e) { /* best-effort */ }
    // Toujours 200 : cet appel vient de pg_net/cron en best-effort, jamais
    // d'un client qui doit réagir à un code d'erreur HTTP.
    return json({ ok: false, error: detail }, 200);
  }
});
