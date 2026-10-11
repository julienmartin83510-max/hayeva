// Supabase Edge Function — « Dis Siri, EVA » : passerelle Raccourcis iPhone → EVA.
//
// Le raccourci iPhone « EVA » dicte une question et l'envoie ici (POST) avec
// le jeton d'appareil créé dans EVA (en-tête x-eva-token). La fonction :
//  1. comprend la phrase avec le MÊME interprète que l'application
//     (_shared/eva-intents.js, règles locales, aucune IA, aucun service payant) ;
//  2. appelle eva_siri_run (clé de service) qui vérifie le jeton (empreinte
//     SHA-256, révocable, expirable), l'activation de Siri, et n'autorise que
//     des LECTURES, au nom de l'administrateur, avec le journal d'EVA ;
//  3. renvoie une phrase courte que le raccourci lit à voix haute.
// Aucune action (création, envoi, annulation…) n'est possible par cette voie :
// EVA répond qu'il faut ouvrir l'application, où chaque action se confirme.
//
// Déploiement (NON effectué, sur validation uniquement) :
//   supabase functions deploy eva-siri --no-verify-jwt
// --no-verify-jwt : l'appelant est un raccourci iPhone sans session ; la seule
// clé acceptée est le jeton d'appareil, vérifié en base.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import '../_shared/eva-intents.js';

// deno-lint-ignore no-explicit-any
const I = (globalThis as any).EVAIntents;
const SITE_URL = Deno.env.get('PUBLIC_SITE_URL') || 'https://hayeva.fr';
const QUERY_INTENTS = new Set(['agenda_range', 'stats', 'catalog', 'client_detail', 'maintenance_due', 'invoices_list']);
const READ_INTENTS = new Set(['agenda', 'brief', 'free_slots', 'conflicts', 'find_client', 'quotes_pending', 'invoices_todo', 'attention', 'finance',
  'client_quotes', 'awaiting', 'capabilities', ...QUERY_INTENTS]);
const TOKEN_RE = /^eva_[0-9a-f]{48}$/;

// ------------------------------------------------------------ mise en mots
const MONTHS = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
const DAYS = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];
function parseIso(d: string){ const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d || '')); return m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])) : null; }
export function sayDate(d: string){ const x = parseIso(d); return x ? DAYS[x.getUTCDay()] + ' ' + (x.getUTCDate() === 1 ? '1er' : x.getUTCDate()) + ' ' + MONTHS[x.getUTCMonth()] : ''; }
export function sayTime(t: string){ const m = /^(\d{1,2}):(\d{2})/.exec(String(t || '')); if (!m) return ''; const h = Number(m[1]), mi = Number(m[2]); return h + ' h' + (mi ? ' ' + String(mi).padStart(2, '0') : ''); }
export function sayEur(c: number | null | undefined){
  if (c == null) return 'montant non renseigné';
  const v = Math.abs(Number(c)) / 100, e = Math.floor(v), ct = Math.round((v - e) * 100);
  return (c < 0 ? 'moins ' : '') + e.toLocaleString('fr-FR').replace(/\s/g, ' ') + (ct ? ' euros ' + ct : (e > 1 ? ' euros' : ' euro'));
}
const plural = (n: number, one: string, many?: string) => n + ' ' + (n > 1 ? (many || one + 's') : one);
function list(items: string[], max = 4){ const a = items.slice(0, max); const rest = items.length - a.length; return a.join(' ; ') + (rest > 0 ? ' ; et ' + plural(rest, 'autre') : ''); }
function relDay(d: string, today: string){
  const a = parseIso(d), b = parseIso(today); if (!a || !b) return '';
  const diff = Math.round((a.getTime() - b.getTime()) / 86400000);
  return diff === 0 ? "aujourd'hui" : diff === 1 ? 'demain' : diff === -1 ? 'hier' : sayDate(d);
}

// deno-lint-ignore no-explicit-any
export function speech(intent: string, d: any, today: string, args: any = {}): string {
  switch (intent){
    case 'agenda': {
      const it = d.interventions || [], day = relDay(d.date, today);
      const head = day.charAt(0).toUpperCase() + day.slice(1);
      if (!it.length) return head + ', aucune intervention dans votre planning.';
      // deno-lint-ignore no-explicit-any
      return head + ', ' + plural(it.length, 'intervention') + '. ' + list(it.map((x: any) => 'À ' + sayTime(x.start) + ', ' + x.client + ', ' + x.service + (x.status === 'PENDING' ? ', à confirmer' : '')), 5) + '.';
    }
    case 'brief': {
      const parts: string[] = [];
      if (d.agenda) parts.push(speech('agenda', d.agenda, today));
      if (d.quotes) parts.push(plural(d.quotes.drafts.length, 'devis en brouillon', 'devis en brouillon') + ', ' + plural(d.quotes.sent.length, 'devis envoyé sans réponse', 'devis envoyés sans réponse') + '.');
      if (d.invoices){ const n = d.invoices.completed_without_invoice.length + d.invoices.accepted_quotes_without_invoice.length; parts.push(plural(n, 'facture') + ' à préparer.'); }
      const att = (d.attention && d.attention.items) || [];
      // deno-lint-ignore no-explicit-any
      if (att.length) parts.push('À surveiller : ' + list(att.map((x: any) => x.message), 2));
      return parts.join(' ');
    }
    case 'free_slots': {
      const s = d.slots || [];
      if (!s.length) return 'Aucun créneau libre de ' + d.duration_minutes + ' minutes sur cette période.';
      // deno-lint-ignore no-explicit-any
      return plural(s.length, 'créneau libre', 'créneaux libres') + ' de ' + d.duration_minutes + ' minutes. Par exemple : ' + list(s.map((x: any) => sayDate(x.date) + ' à ' + sayTime(x.start)), 4) + '.';
    }
    case 'conflicts': {
      const c = d.conflicts || [];
      // deno-lint-ignore no-explicit-any
      return c.length ? plural(c.length, 'point') + ' à vérifier dans votre planning. ' + list(c.map((x: any) => x.message), 2) : 'Aucun conflit de planning sur la période.';
    }
    case 'find_client': {
      const c = d.clients || [];
      if (!c.length) return 'Aucun client ne correspond à ' + (d.query || 'cette recherche') + '.';
      // deno-lint-ignore no-explicit-any
      return plural(c.length, 'client trouvé', 'clients trouvés') + '. ' + list(c.map((x: any) => x.name + (x.city ? ', ' + x.city : '') + (x.phone ? ', téléphone ' + String(x.phone).replace(/(\d{2})(?=\d)/g, '$1 ') : '')), 3) + '.';
    }
    case 'quotes_pending':
      return plural(d.drafts.length, 'brouillon') + ', ' + plural(d.sent.length, 'devis envoyé', 'devis envoyés') + ' en attente de réponse, ' + plural(d.accepted_not_invoiced.length, 'devis accepté', 'devis acceptés') + ' à facturer.';
    case 'invoices_todo': {
      const n = d.completed_without_invoice.length + d.accepted_quotes_without_invoice.length;
      return (n ? plural(n, 'facture') + ' à préparer' : 'Aucune facture à préparer') + ', ' + plural(d.unpaid.length, 'facture émise', 'factures émises') + ' en attente de règlement.';
    }
    case 'attention': {
      const it = d.items || [];
      // deno-lint-ignore no-explicit-any
      return it.length ? plural(it.length, 'point') + ' à traiter. ' + list(it.map((x: any) => x.message), 3) : 'Rien ne nécessite votre attention pour le moment.';
    }
    case 'finance':
      return 'Du ' + sayDate(d.from) + ' au ' + sayDate(d.to) + ' : facturé ' + sayEur(d.invoiced_cents) + ', encaissé ' + sayEur(d.collected_cents) + '. Reste à encaisser : ' + sayEur(d.outstanding_cents) + '.';
    case 'client_quotes': {
      const cl = d.clients || [], q = d.quotes || [];
      if (cl.length !== 1) return cl.length ? 'Plusieurs clients correspondent : précisez le prénom.' : 'Client introuvable.';
      if (!q.length) return cl[0].name + " n'a aucun devis.";
      return 'Dernier devis de ' + cl[0].name + ' : ' + (q[0].title || q[0].reference) + ', ' + sayEur(q[0].total_cents) + '.';
    }
    case 'awaiting': {
      const b = d.booking_requests || [], c = d.callbacks || [];
      if (!b.length && !c.length) return "Aucun client n'attend de réponse.";
      // deno-lint-ignore no-explicit-any
      return [b.length ? plural(b.length, 'demande') + ' de rendez-vous à confirmer : ' + list(b.map((x: any) => x.client), 3) + '.' : '', c.length ? plural(c.length, 'demande') + ' de rappel.' : ''].join(' ').trim();
    }
    case 'capabilities':
      return "Par Siri, je réponds à vos questions : planning, créneaux libres, devis, factures, clients, entretiens et statistiques. Pour créer, envoyer ou annuler, ouvrez EVA dans l'application : chaque action s'y confirme.";
    case 'agenda_range': {
      const n = d.count || 0;
      return 'Du ' + sayDate(d.from) + ' au ' + sayDate(d.to) + ' : ' + (n ? plural(n, 'rendez-vous', 'rendez-vous') : 'aucun rendez-vous') + '.' +
        // deno-lint-ignore no-explicit-any
        (n ? ' ' + list((d.days || []).map((x: any) => sayDate(x.date) + ', ' + x.items.length), 6) + '.' : '');
    }
    case 'stats':
      return 'Du ' + sayDate(d.from) + ' au ' + sayDate(d.to) + ' : ' + plural(d.requests_received || 0, 'demande reçue', 'demandes reçues') + ', ' + plural(d.confirmed || 0, 'rendez-vous confirmé', 'rendez-vous confirmés') + ', ' + plural(d.completed || 0, 'intervention terminée', 'interventions terminées') + ', ' + (d.cancelled_client || 0) + ' annulés par les clients.';
    case 'catalog': {
      const it = d.items || [];
      if (!it.length) return 'Aucune prestation de votre catalogue ne correspond.';
      // deno-lint-ignore no-explicit-any
      const p = (x: any) => x.mode === 'QUOTE' ? 'sur devis' : x.price_cents == null ? 'prix non renseigné' : (x.mode === 'FROM' ? 'à partir de ' : '') + sayEur(x.price_cents);
      return list(it.map((x: any) => x.label + ' : ' + p(x)), 4) + '.';
    }
    case 'client_detail': {
      if (!d.client) return (d.clients || []).length > 1 ? 'Plusieurs clients correspondent : précisez le prénom.' : 'Client introuvable.';
      const c = d.client, iv = (d.interventions || [])[0], next = (d.bookings || []).filter((x: { date: string; status: string }) => x.date >= today && (x.status === 'PENDING' || x.status === 'CONFIRMED')).slice(-1)[0];
      return c.name + (c.city ? ', ' + c.city : '') + '. ' + (iv ? 'Dernière intervention le ' + sayDate(String(iv.date).slice(0, 10)) + ' : ' + iv.service + '. ' : 'Aucune intervention enregistrée. ') +
        (next ? 'Prochain rendez-vous ' + sayDate(next.date) + ' à ' + sayTime(next.start) + '.' : 'Aucun rendez-vous à venir.');
    }
    case 'maintenance_due': {
      const it = d.items || [];
      // deno-lint-ignore no-explicit-any
      return it.length ? plural(it.length, 'entretien') + ' à renouveler : ' + list(it.map((x: any) => x.client + (x.overdue ? ', en retard' : ', avant le ' + sayDate(x.next_due))), 4) + '.' : 'Aucun entretien à renouveler prochainement.';
    }
    case 'invoices_list': {
      if ((d.clients || []).length > 1) return 'Plusieurs clients correspondent : précisez le prénom.';
      if (args && args.last){ const l = (d.invoices || [])[0]; return l ? 'Dernière facture : ' + (l.reference || 'brouillon') + ', ' + l.client + ', ' + sayEur(l.total_cents) + '.' : 'Aucune facture.'; }
      const inv = d.invoices || [], pay = d.payments || [];
      return plural(inv.length, 'facture') + ' et ' + plural(pay.length, 'paiement') + ' enregistrés' + (pay.length ? ', pour ' + sayEur(pay.reduce((s: number, x: { amount_cents: number }) => s + x.amount_cents, 0)) : '') + '.';
    }
  }
  return 'Réponse prête dans EVA.';
}

const ERRORS: Record<string, [number, string]> = {
  APPAREIL_NON_AUTORISE: [401, "Cet iPhone n'est pas autorisé. Créez un accès Siri dans les réglages d'EVA."],
  SIRI_DESACTIVE: [403, "L'accès par Siri est désactivé dans les réglages d'EVA."],
  EVA_DESACTIVEE: [403, 'EVA est désactivée dans les réglages.'],
  LECTURE_SEULE: [403, "Par Siri, je ne fais que répondre. Ouvrez EVA pour agir."],
  TROP_DE_DEMANDES: [429, 'Trop de demandes en une minute. Réessayez dans un instant.'],
  LIMITE_JOURNALIERE: [429, 'Limite quotidienne de demandes atteinte.'],
  AGENT_DESACTIVE: [403, 'Cet agent est désactivé dans les réglages d’EVA.'],
  PERIODE_INVALIDE: [400, 'Période trop longue : limitez-la à un mois.'],
  DATE_INVALIDE: [400, 'Date non reconnue.'],
};
function errorOf(msg: string): [number, string] {
  for (const k in ERRORS) if (msg.includes(k)) return ERRORS[k];
  if (/réservée|42501/.test(msg)) return [403, "Ce compte n'est plus administrateur : accès refusé."];
  return [500, "EVA n'a pas pu répondre. Réessayez dans un instant."];
}

// Date et heure de Paris, quelle que soit l'horloge du serveur.
export function parisNow(): Date {
  const p = Object.fromEntries(new Intl.DateTimeFormat('fr-FR', { timeZone: 'Europe/Paris', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    .formatToParts(new Date()).map((x) => [x.type, x.value]));
  return new Date(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour), Number(p.minute));
}
async function sha256(s: string){
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))), (b) => b.toString(16).padStart(2, '0')).join('');
}

// deno-lint-ignore no-explicit-any
type Rpc = (name: string, args: Record<string, unknown>) => Promise<{ data: any; error: any }>;
export async function handle(req: Request, rpc: Rpc, now: Date = parisNow()): Promise<Response> {
  const wantsJson = /application\/json/.test(req.headers.get('accept') || '') || new URL(req.url).searchParams.get('format') === 'json';
  const reply = (status: number, text: string, extra: Record<string, unknown> = {}) => wantsJson
    ? new Response(JSON.stringify({ speech: text, ...extra }), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' } })
    // Mode texte (raccourci simple) : toujours 200 pour que l'app Raccourcis LISE le message
    // d'erreur au lieu d'échouer en silence ; le vrai code reste dans l'en-tête X-Eva-Status.
    : new Response(text, { status: 200, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'X-Eva-Status': String(status) } });
  if (req.method !== 'POST') return reply(405, 'Méthode non autorisée.');
  const token = (req.headers.get('x-eva-token') || '').trim();
  if (!TOKEN_RE.test(token)) return reply(401, ERRORS.APPAREIL_NON_AUTORISE[1]);
  let text = '';
  try {
    const raw = await req.text();
    if (raw.length > 4000) return reply(413, 'Demande trop longue.');
    const ct = req.headers.get('content-type') || '';
    text = /json/.test(ct) ? String((JSON.parse(raw || '{}') || {}).text || '') : raw;
  } catch { return reply(400, 'Demande illisible.'); }
  text = text.replace(/\s+/g, ' ').trim().slice(0, 300);
  if (!text) return reply(400, "Je n'ai rien entendu. Que puis-je faire pour vous ?");

  const hash = await sha256(token);
  const today = I.iso(now);
  const plan = I.parse(text, now).slice(0, 2);
  const out: string[] = [];
  let openUrl: string | null = null;
  for (const p of plan){
    if (p.intent === 'empty') continue;
    if (p.intent === 'unknown'){ out.push("Je n'ai pas compris. Essayez par exemple : qu'est-ce que j'ai demain ?"); continue; }
    if (p.args && (p.args.client === '@ctx')){ out.push('Précisez le nom du client.'); continue; }
    if (!READ_INTENTS.has(p.intent)){
      // Action : jamais exécutée par la voix. Le raccourci peut ouvrir EVA avec la demande pré-remplie.
      openUrl = SITE_URL + '/?eva=' + encodeURIComponent(p.text || text);
      out.push(p.intent === 'bulk_refused' ? 'Je ne fais jamais d’action groupée.' : p.intent === 'delete_refused' ? 'EVA ne supprime aucune donnée.'
        : (p.label || 'Cette action') + " : ouvrez EVA dans l'application, l'action s'y vérifie et s'y confirme.");
      continue;
    }
    const { data, error } = await rpc('eva_siri_run', { p_token_hash: hash, p_intent: p.intent, p_args: p.args || {}, p_command: p.text || text });
    if (error){
      const [status, msg] = errorOf(String(error.message || ''));
      if (status === 401 || status === 403 || status === 429) return reply(status, msg);
      out.push(msg); continue;
    }
    out.push(speech(p.intent, (data && data.data) || {}, today, p.args || {}));
  }
  return reply(200, out.join(' ') || "Je n'ai rien entendu.", openUrl ? { open_url: openUrl } : {});
}

const admin = createClient(Deno.env.get('SUPABASE_URL') || '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '', { auth: { persistSession: false } });
Deno.serve((req: Request) => handle(req, (name, args) => admin.rpc(name, args)));
