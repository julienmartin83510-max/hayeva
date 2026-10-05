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
//    retrouve le calendrier dédié "HAYEVA — Rendez-vous" et liste les
//    calendriers disponibles comme sources de blocage.
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
const HAYEVA_CALENDAR_DISPLAY_NAME = 'HAYEVA — Rendez-vous';
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
  const [y, m, d] = dateStr.slice(0, 10).split('-').map(Number);
  const [hh, mm, ss] = timeStr.split(':').map((n) => Number(n || 0));
  let guess = new Date(Date.UTC(y, m - 1, d, hh, mm, ss || 0));
  for (let i = 0; i < 2; i++) {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: 'Europe/Paris', hour12: false,
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
async function caldavFetch(appleEmail: string, appPassword: string, url: string, method: string, body?: string, extraHeaders?: Record<string, string>) {
  const auth = 'Basic ' + btoa(`${appleEmail}:${appPassword}`);
  const res = await fetch(url, {
    method,
    headers: { Authorization: auth, 'Content-Type': 'application/xml; charset=utf-8', Depth: '0', ...extraHeaders },
    body,
  });
  const text = await res.text();
  return { ok: res.ok, status: res.status, text, headers: res.headers };
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
// Action: setup — découverte CalDAV (principal, calendar-home-set,
// calendriers disponibles) + création du calendrier dédié HAYEVA.
// ------------------------------------------------------------
async function runSetup() {
  const { data: conn, error: connErr } = await supabase.from('calendar_connections').select('*').order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (connErr) throw connErr;
  if (!conn?.apple_id_email) throw new Error('apple_id_email_missing');
  const appPassword = await getAppPassword();
  const email = conn.apple_id_email as string;

  const principalBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:"><D:prop><D:current-user-principal/></D:prop></D:propfind>`;
  const principalRes = await caldavFetch(email, appPassword, CALDAV_ROOT + '/', 'PROPFIND', principalBody, { Depth: '0' });
  if (!principalRes.ok) throw new Error(`propfind_principal_failed_${principalRes.status}`);
  const principalHref = extractOne(principalRes.text, /<[^:>]*:?current-user-principal[^>]*>\s*<[^:>]*:?href[^>]*>([^<]+)<\/[^:>]*:?href>/i);
  if (!principalHref) throw new Error('principal_href_not_found');

  const homeSetBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><C:calendar-home-set/></D:prop></D:propfind>`;
  const homeSetRes = await caldavFetch(email, appPassword, CALDAV_ROOT + principalHref, 'PROPFIND', homeSetBody, { Depth: '0' });
  if (!homeSetRes.ok) throw new Error(`propfind_homeset_failed_${homeSetRes.status}`);
  const homeHref = extractOne(homeSetRes.text, /<[^:>]*:?calendar-home-set[^>]*>\s*<[^:>]*:?href[^>]*>([^<]+)<\/[^:>]*:?href>/i);
  if (!homeHref) throw new Error('calendar_home_href_not_found');

  const listBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<D:prop><D:resourcetype/><D:displayname/><C:supported-calendar-component-set/></D:prop>
</D:propfind>`;
  const listRes = await caldavFetch(email, appPassword, CALDAV_ROOT + homeHref, 'PROPFIND', listBody, { Depth: '1' });
  if (!listRes.ok) throw new Error(`propfind_list_failed_${listRes.status}`);

  const responseBlocks = extractAll(listRes.text, /<[^:>]*:?response[^>]*>([\s\S]*?)<\/[^:>]*:?response>/i);
  const calendars: Array<{ href: string; displayName: string }> = [];
  for (const block of responseBlocks) {
    if (!/<[^:>]*:?resourcetype[^>]*>[\s\S]*?<[^:>]*:?calendar\b/i.test(block)) continue;
    const href = extractOne(block, /<[^:>]*:?href[^>]*>([^<]+)<\/[^:>]*:?href>/i);
    if (!href) continue;
    const displayName = extractOne(block, /<[^:>]*:?displayname[^>]*>([^<]*)<\/[^:>]*:?displayname>/i) || href;
    calendars.push({ href, displayName });
  }

  let hayevaCal = calendars.find((c) => c.displayName === HAYEVA_CALENDAR_DISPLAY_NAME);
  if (!hayevaCal) {
    const slug = 'hayeva-rendezvous-' + Date.now().toString(36);
    const newHref = homeHref.endsWith('/') ? `${homeHref}${slug}/` : `${homeHref}/${slug}/`;
    const mkcalBody = `<?xml version="1.0" encoding="utf-8"?>
<C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<D:set><D:prop><D:displayname>${icsEscape(HAYEVA_CALENDAR_DISPLAY_NAME)}</D:displayname></D:prop></D:set>
</C:mkcalendar>`;
    const mkcalRes = await caldavFetch(email, appPassword, CALDAV_ROOT + newHref, 'MKCALENDAR', mkcalBody, { Depth: '0' });
    if (!mkcalRes.ok) throw new Error(`mkcalendar_failed_${mkcalRes.status}`);
    hayevaCal = { href: newHref, displayName: HAYEVA_CALENDAR_DISPLAY_NAME };
  }

  await supabase.from('calendar_connections').update({
    connected: true,
    caldav_principal_url: CALDAV_ROOT + principalHref,
    target_calendar_url: CALDAV_ROOT + hayevaCal.href,
    target_calendar_display_name: HAYEVA_CALENDAR_DISPLAY_NAME,
    last_sync_error: null,
    updated_at: new Date().toISOString(),
  }).eq('id', conn.id);

  const otherCalendars = calendars.filter((c) => c.href !== hayevaCal!.href);
  for (const cal of otherCalendars) {
    await supabase.from('calendar_blocking_sources').upsert({
      connection_id: conn.id,
      calendar_url: CALDAV_ROOT + cal.href,
      display_name: cal.displayName,
      is_blocking: true,
    }, { onConflict: 'connection_id,calendar_url' });
  }

  await logSync('pull', 'ok', `setup_ok: calendrier HAYEVA=${hayevaCal.href}, ${otherCalendars.length} calendrier(s) source détecté(s)`);
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
      customer_user_id, customer_address_id,
      services(name, category, description),
      customer_addresses(address, postal_code, city)
    `)
    .eq('id', bookingId).maybeSingle();
  if (bErr) throw bErr;
  if (!booking) throw new Error('booking_not_found');

  let clientName = booking.guest_name || '';
  let clientPhone = booking.guest_phone || '';
  let clientAddress = booking.guest_address || '';
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
    `Type : ${serviceName}`,
    category ? `Catégorie : ${category}` : null,
    service?.description ? `Description : ${service.description}` : null,
    booking.notes ? `Notes : ${booking.notes}` : null,
    `Référence HAYEVA : ${booking.reference || booking.id}`,
  ].filter(Boolean).join('\\n');

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
async function runDelete(bookingId: string) {
  const { data: conn } = await supabase.from('calendar_connections').select('*').order('created_at', { ascending: false }).limit(1).maybeSingle();
  const { data: booking } = await supabase.from('bookings').select('calendar_event_uid').eq('id', bookingId).maybeSingle();
  const uid = booking?.calendar_event_uid;
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

function expandRrule(dtStart: Date, durationMs: number, rrule: string, windowStart: Date, windowEnd: Date): Date[] {
  const parts: Record<string, string> = {};
  for (const kv of rrule.split(';')) {
    const [k, v] = kv.split('=');
    if (k) parts[k.toUpperCase()] = v;
  }
  const freq = parts.FREQ;
  const interval = Math.max(1, parseInt(parts.INTERVAL || '1', 10) || 1);
  const count = parts.COUNT ? parseInt(parts.COUNT, 10) : null;
  const until = parts.UNTIL ? new Date(parts.UNTIL.replace(/Z?$/, 'Z').replace(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2}).*/, '$1-$2-$3T$4:$5:$6Z')) : null;
  const byday = parts.BYDAY ? parts.BYDAY.split(',').map((d) => BYDAY_MAP[d.slice(-2)]).filter((n) => n !== undefined) : null;

  const occurrences: Date[] = [];
  let cursor = new Date(dtStart);
  let n = 0;
  const hardCap = 1500;

  while (cursor.getTime() <= windowEnd.getTime() && occurrences.length < hardCap) {
    if (count !== null && n >= count) break;
    if (until && cursor.getTime() > until.getTime()) break;

    if (!byday || freq !== 'WEEKLY') {
      if (cursor.getTime() + durationMs >= windowStart.getTime() && cursor.getTime() <= windowEnd.getTime()) occurrences.push(new Date(cursor));
      n++;
    } else {
      for (const wd of byday) {
        const d = new Date(cursor);
        const diff = (wd - d.getUTCDay() + 7) % 7;
        d.setUTCDate(d.getUTCDate() + diff);
        if (d.getTime() >= dtStart.getTime() && d.getTime() <= windowEnd.getTime() && d.getTime() + durationMs >= windowStart.getTime()) {
          occurrences.push(d);
        }
      }
      n++;
    }

    if (freq === 'DAILY') cursor = new Date(cursor.getTime() + interval * 86400000);
    else if (freq === 'WEEKLY') cursor = new Date(cursor.getTime() + interval * 7 * 86400000);
    else if (freq === 'MONTHLY') { const d = new Date(cursor); d.setUTCMonth(d.getUTCMonth() + interval); cursor = d; }
    else if (freq === 'YEARLY') { const d = new Date(cursor); d.setUTCFullYear(d.getUTCFullYear() + interval); cursor = d; }
    else break; // FREQ non supportée (SECONDLY/MINUTELY/HOURLY — jamais utilisées pour des agendas Apple personnels)
  }
  return occurrences;
}

function parseIcsDate(raw: string, valueIsDate: boolean): Date {
  if (valueIsDate) {
    const y = +raw.slice(0, 4), m = +raw.slice(4, 6), d = +raw.slice(6, 8);
    return parisMidnightToUtc(`${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`);
  }
  if (/Z$/.test(raw)) {
    const y = raw.slice(0, 4), m = raw.slice(4, 6), d = raw.slice(6, 8), hh = raw.slice(9, 11), mm = raw.slice(11, 13), ss = raw.slice(13, 15);
    return new Date(`${y}-${m}-${d}T${hh}:${mm}:${ss}Z`);
  }
  // Heure locale sans TZID explicite dans la ligne (rare chez Apple) : on
  // suppose Europe/Paris, cohérent avec le reste de HAYEVA.
  const y = raw.slice(0, 4), m = raw.slice(4, 6), d = raw.slice(6, 8), hh = raw.slice(9, 11) || '00', mm = raw.slice(11, 13) || '00', ss = raw.slice(13, 15) || '00';
  return parisWallTimeToUtc(`${y}-${m}-${d}`, `${hh}:${mm}:${ss}`);
}

function parseVeventLine(block: string, name: string): { raw: string; isDate: boolean } | null {
  const re = new RegExp(`(?:^|\\r?\\n)${name}(;[^:\\r\\n]*)?:([^\\r\\n]+)`, 'i');
  const m = re.exec(block);
  if (!m) return null;
  const params = m[1] || '';
  return { raw: m[2].trim(), isDate: /VALUE=DATE(?!-TIME)/i.test(params) };
}

// ------------------------------------------------------------
// Action: pull — importe les créneaux occupés depuis chaque calendrier
// Apple marqué comme bloquant.
// ------------------------------------------------------------
async function runPull() {
  const { data: conn } = await supabase.from('calendar_connections').select('*').order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (!conn?.connected) { await logSync('pull', 'error', 'connexion_non_configuree'); return; }

  const appPassword = await getAppPassword();
  const { data: sources } = await supabase.from('calendar_blocking_sources').select('*').eq('connection_id', conn.id).eq('is_blocking', true);

  const now = new Date();
  const windowStart = new Date(now.getTime() - PULL_WINDOW_DAYS_PAST * 86400000);
  const windowEnd = new Date(now.getTime() + PULL_WINDOW_DAYS_FUTURE * 86400000);
  const wStartIcs = icsUtc(windowStart);
  const wEndIcs = icsUtc(windowEnd);

  let anyError: string | null = null;

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
      const eventBlocks = extractAll(res.text, /BEGIN:VEVENT([\s\S]*?)END:VEVENT/i);
      const rows: Array<{ source_id: string; external_uid: string; starts_at: string; ends_at: string; is_all_day: boolean }> = [];

      for (const block of eventBlocks) {
        const uidMatch = /(?:^|\r?\n)UID:([^\r\n]+)/i.exec(block);
        const uid = uidMatch ? uidMatch[1].trim() : null;
        if (!uid || uid.startsWith(UID_PREFIX)) continue; // anti-boucle : jamais nos propres événements

        const dtStartLine = parseVeventLine(block, 'DTSTART');
        if (!dtStartLine) continue;
        const dtStart = parseIcsDate(dtStartLine.raw, dtStartLine.isDate);

        const dtEndLine = parseVeventLine(block, 'DTEND');
        const durationLine = parseVeventLine(block, 'DURATION');
        let dtEnd: Date;
        if (dtEndLine) dtEnd = parseIcsDate(dtEndLine.raw, dtEndLine.isDate);
        else if (durationLine) {
          const dm = /P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?/.exec(durationLine.raw);
          const days = dm ? +(dm[1] || 0) : 0, hrs = dm ? +(dm[2] || 0) : 0, mins = dm ? +(dm[3] || 0) : 0;
          dtEnd = new Date(dtStart.getTime() + (days * 86400 + hrs * 3600 + mins * 60) * 1000);
        } else dtEnd = new Date(dtStart.getTime() + 3600000);

        const durationMs = dtEnd.getTime() - dtStart.getTime();
        const rruleLine = parseVeventLine(block, 'RRULE');

        if (rruleLine) {
          const occStarts = expandRrule(dtStart, durationMs, rruleLine.raw, windowStart, windowEnd);
          for (const occStart of occStarts) {
            const occUid = `${uid}_${occStart.getTime()}`;
            if (seenUids.has(occUid)) continue;
            seenUids.add(occUid);
            rows.push({ source_id: source.id, external_uid: occUid, starts_at: occStart.toISOString(), ends_at: new Date(occStart.getTime() + durationMs).toISOString(), is_all_day: !!dtStartLine.isDate });
          }
        } else {
          if (seenUids.has(uid)) continue;
          seenUids.add(uid);
          if (dtEnd.getTime() < windowStart.getTime() || dtStart.getTime() > windowEnd.getTime()) continue;
          rows.push({ source_id: source.id, external_uid: uid, starts_at: dtStart.toISOString(), ends_at: dtEnd.toISOString(), is_all_day: !!dtStartLine.isDate });
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
    } catch (sourceErr) {
      anyError = redactError(sourceErr);
      await logSync('pull', 'error', `source=${source.display_name || source.calendar_url}: ${anyError}`);
    }
  }

  await supabase.from('calendar_connections').update({
    last_pull_sync_at: new Date().toISOString(),
    last_sync_error: anyError,
  }).eq('id', conn.id);
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
      await runSetup();
      return json({ ok: true, action });
    }
    if (action === 'pull') {
      await runPull();
      return json({ ok: true, action });
    }
    if ((action === 'upsert' || action === 'delete') && payload.booking_id) {
      if (action === 'upsert') await runUpsert(payload.booking_id);
      else await runDelete(payload.booking_id);
      return json({ ok: true, action, booking_id: payload.booking_id });
    }
    return json({ error: 'invalid_action' }, 400);
  } catch (err) {
    const detail = redactError(err);
    console.error('calendar-sync: erreur', detail);
    try {
      if (payload?.booking_id) {
        await supabase.from('bookings').update({ calendar_sync_status: 'ERROR', calendar_sync_error: detail }).eq('id', payload.booking_id);
      }
      const { data: connRow } = await supabase.from('calendar_connections').select('id').order('created_at', { ascending: false }).limit(1).maybeSingle();
      if (connRow) await supabase.from('calendar_connections').update({ last_sync_error: detail }).eq('id', connRow.id);
      await logSync(payload?.action === 'pull' ? 'pull' : 'push', 'error', detail, payload?.booking_id);
    } catch (_e) { /* best-effort */ }
    // Toujours 200 : cet appel vient de pg_net/cron en best-effort, jamais
    // d'un client qui doit réagir à un code d'erreur HTTP.
    return json({ ok: false, error: detail }, 200);
  }
});
