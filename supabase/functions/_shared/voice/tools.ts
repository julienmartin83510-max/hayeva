// HAYEVA Voice — outils serveur (function-calling)
//
// RÈGLE ABSOLUE : le modèle ne voit jamais que ces SCHÉMAS (nom + JSON
// Schema des paramètres, voir TOOL_SCHEMAS ci-dessous). Il ne peut jamais
// écrire de SQL, jamais toucher directement à Supabase. Chaque handler
// valide lui-même ses arguments avant d'agir — jamais confiance dans ce que
// le LLM a produit (paramètres manquants, mal typés ou hors limites sont
// systématiquement rejetés avant toute lecture/écriture).
//
// PHASE 1 (simulateur) : create_booking/reschedule_booking/cancel_booking
// n'écrivent JAMAIS dans `bookings` (table de production) — uniquement
// dans `voice_test_bookings`, une table entièrement séparée (voir
// 0035_voice_assistant_core.sql). get_available_slots, lui, interroge les
// VRAIES disponibilités (lecture seule de `services` et `bookings`) : les
// créneaux proposés en simulation sont donc réels, jamais inventés — seule
// l'écriture finale est isolée en mode test.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import type { ToolSchema } from './llm-provider.ts';
import { canTransition, type CallState } from './state-machine.ts';

export interface SessionInfo {
  call_state: CallState;
  customer_type: string | null;
  service_category: string | null;
  customer_name: string | null;
  customer_phone: string | null;
  customer_address: string | null;
  customer_city: string | null;
  problem_description: string | null;
  urgency_level: string | null;
  desired_date: string | null;
  desired_slot_label: string | null;
}

export interface ToolContext {
  supabase: SupabaseClient;
  sessionId: string;
  session: SessionInfo;
}

export type SessionPatch = Partial<Omit<SessionInfo, 'call_state'>> & Partial<{ call_state: CallState; test_booking_id: string }>;

export interface ToolResult {
  ok: boolean;
  data?: Record<string, unknown>;
  error?: string;
  // Effets de bord que l'appelant (index.ts) doit appliquer à la session
  // après un outil réussi (ex. mémoriser une information client comprise).
  sessionPatch?: SessionPatch;
}

function genTestReference(): string {
  const rand = Math.random().toString(36).slice(2, 8).toUpperCase();
  return `TEST-VOICE-${rand}`;
}

// ------------------------------------------------------------
// Schémas exposés au modèle — JSON Schema standard (format OpenAI/OpenRouter
// "function calling", voir llm-provider.ts).
export const TOOL_SCHEMAS: ToolSchema[] = [
  {
    name: 'set_call_state',
    description: "Fait avancer l'état interne de l'appel. À appeler à chaque étape franchie (ex. après avoir identifié le besoin, passer à collect_information). Le serveur refuse toute transition non autorisée.",
    parameters: {
      type: 'object',
      properties: {
        state: {
          type: 'string',
          enum: ['greeting', 'identify_need', 'collect_information', 'check_availability', 'propose_slots', 'confirmation', 'create_booking', 'completed', 'human_transfer', 'callback_required', 'failed', 'cancelled'],
        },
      },
      required: ['state'],
    },
  },
  {
    name: 'get_available_slots',
    description: "Consulte les VRAIS créneaux disponibles pour une prestation HAYEVA à une date donnée. N'invente jamais de créneau : renvoie uniquement ce que cet outil retourne.",
    parameters: {
      type: 'object',
      properties: {
        service_slug: { type: 'string', description: "Identifiant exact de la prestation (ex. 'plomberie-depannage', 'chauffage-entretien'). Si inconnu, utilise get_service_information d'abord." },
        date: { type: 'string', description: 'Date au format AAAA-MM-JJ' },
      },
      required: ['service_slug', 'date'],
    },
  },
  {
    name: 'get_service_information',
    description: 'Recherche une prestation HAYEVA active par mots-clés (ex. "fuite évier", "entretien chaudière") pour retrouver son identifiant exact (slug), son nom et sa durée.',
    parameters: {
      type: 'object',
      properties: { query: { type: 'string', description: 'Mots-clés décrivant le besoin du client' } },
      required: ['query'],
    },
  },
  {
    name: 'create_booking',
    description: "Crée le rendez-vous UNIQUEMENT après confirmation explicite et claire du client (oui). Revérifie la disponibilité juste avant d'écrire.",
    parameters: {
      type: 'object',
      properties: {
        service_slug: { type: 'string' },
        date: { type: 'string', description: 'AAAA-MM-JJ' },
        start_time: { type: 'string', description: 'HH:MM' },
        customer_type: { type: 'string', enum: ['particulier', 'professionnel'] },
        customer_name: { type: 'string' },
        customer_phone: { type: 'string' },
        customer_address: { type: 'string' },
        notes: { type: 'string' },
      },
      required: ['service_slug', 'date', 'start_time', 'customer_type', 'customer_name', 'customer_phone'],
    },
  },
  {
    name: 'get_booking',
    description: 'Retrouve un rendez-vous existant (créé pendant cette même simulation) par sa référence.',
    parameters: { type: 'object', properties: { reference: { type: 'string' } }, required: ['reference'] },
  },
  {
    name: 'reschedule_booking',
    description: 'Déplace un rendez-vous existant vers une nouvelle date/heure, après revérification de la disponibilité.',
    parameters: {
      type: 'object',
      properties: { reference: { type: 'string' }, new_date: { type: 'string' }, new_start_time: { type: 'string' } },
      required: ['reference', 'new_date', 'new_start_time'],
    },
  },
  {
    name: 'cancel_booking',
    description: 'Annule un rendez-vous existant, après confirmation du client.',
    parameters: { type: 'object', properties: { reference: { type: 'string' } }, required: ['reference'] },
  },
  {
    name: 'create_callback_request',
    description: "Enregistre une demande de rappel par un membre de l'équipe HAYEVA (transfert humain différé).",
    parameters: {
      type: 'object',
      properties: { reason: { type: 'string' }, customer_phone: { type: 'string' } },
      required: ['reason'],
    },
  },
  {
    name: 'get_customer',
    description: "Recherche un client existant par téléphone. En simulation (Phase 1), aucune vraie fiche client n'est consultée — répond toujours qu'aucune correspondance n'est trouvée.",
    parameters: { type: 'object', properties: { phone: { type: 'string' } }, required: ['phone'] },
  },
  {
    name: 'record_customer_info',
    description: "Enregistre ou met à jour, au fur et à mesure, les informations déjà données par le client (même une seule à la fois, ou plusieurs en même temps si le client les a toutes données dans la même phrase). N'invente JAMAIS une valeur non dite explicitement — ne renseigne que ce que le client a réellement communiqué.",
    parameters: {
      type: 'object',
      properties: {
        customer_name: { type: 'string' },
        customer_phone: { type: 'string' },
        customer_address: { type: 'string' },
        customer_city: { type: 'string' },
        customer_type: { type: 'string', enum: ['particulier', 'professionnel'] },
        service_category: { type: 'string', enum: ['plomberie', 'chauffage', 'climatisation', 'autre'] },
        problem_description: { type: 'string', description: 'Description courte du problème, dans les mots du client' },
        urgency_level: { type: 'string', enum: ['normale', 'elevee', 'urgence'] },
        desired_date: { type: 'string', description: "Date souhaitée si connue précisément, AAAA-MM-JJ" },
        desired_slot_label: { type: 'string', description: "Moment souhaité tel que dit par le client, ex. 'demain après-midi' (texte libre, avant vérification réelle via get_available_slots)" },
      },
      required: [],
    },
  },
  {
    name: 'get_service_price',
    description: "Consulte le VRAI tarif d'une prestation HAYEVA. N'invente jamais un prix : si le tarif est \"sur devis\", dis-le clairement au lieu de proposer un chiffre.",
    parameters: {
      type: 'object',
      properties: { service_slug: { type: 'string' } },
      required: ['service_slug'],
    },
  },
  {
    name: 'get_travel_information',
    description: "Donne la règle HAYEVA de frais de déplacement (rayon inclus gratuitement autour de Fréjus, tarif au km au-delà). Ne calcule PAS une distance précise pour une adresse donnée en Phase 1 — indique que le montant exact sera confirmé lors de la réservation.",
    parameters: { type: 'object', properties: {}, required: [] },
  },
];

// ------------------------------------------------------------
// Handlers — chacun valide ses propres arguments avant toute action.

async function toolSetCallState(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const state = typeof args.state === 'string' ? (args.state as CallState) : null;
  if (!state) return { ok: false, error: 'Paramètre state manquant ou invalide.' };
  if (!canTransition(ctx.session.call_state, state)) {
    return { ok: false, error: `Transition refusée : ${ctx.session.call_state} → ${state} n'est pas autorisée.` };
  }
  return { ok: true, data: { state }, sessionPatch: { call_state: state } };
}

async function toolGetServiceInformation(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const query = typeof args.query === 'string' ? args.query.trim() : '';
  if (!query) return { ok: false, error: 'query manquant.' };
  // Recherche par MOT plutôt que par phrase exacte : "fuite évier" doit
  // trouver un service dont le nom contient seulement "fuite" (ex. "Forfait
  // recherche de fuite") — un filtre sur la phrase entière échouait dès que
  // le client formulait sa demande différemment du nom exact de la
  // prestation (constaté en test). Chaque mot (nettoyé des caractères qui
  // casseraient la mini-syntaxe .or() de PostgREST) élargit la recherche.
  const words = query.split(/\s+/).map((w) => w.replace(/[(),%]/g, '')).filter((w) => w.length >= 3).slice(0, 6);
  const terms = words.length ? words : [query.replace(/[(),%]/g, '')];
  const orFilter = terms.map((w) => `name.ilike.%${w}%,description.ilike.%${w}%`).join(',');
  const { data, error } = await ctx.supabase
    .from('services')
    .select('slug, name, category, description, duration_minutes, booking_type, customer_type')
    .eq('is_active', true)
    .or(orFilter)
    .limit(5);
  if (error) return { ok: false, error: 'Recherche indisponible.' };
  return { ok: true, data: { results: data || [] } };
}

async function toolGetAvailableSlots(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const serviceSlug = typeof args.service_slug === 'string' ? args.service_slug.trim() : '';
  const date = typeof args.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(args.date) ? args.date : '';
  if (!serviceSlug || !date) return { ok: false, error: 'service_slug et date (AAAA-MM-JJ) sont requis.' };

  const { data: service } = await ctx.supabase.from('services').select('slug, name, duration_minutes, is_active').eq('slug', serviceSlug).maybeSingle();
  if (!service || !service.is_active) return { ok: false, error: "Cette prestation n'existe pas ou n'est plus active." };

  const { data, error } = await ctx.supabase.rpc('get_available_slots_for_service', { p_service_slug: serviceSlug, p_date: date, p_max_slots: 5 });
  if (error) return { ok: false, error: 'Disponibilités indisponibles pour le moment.' };
  return { ok: true, data: { service: service.name, date, slots: data || [] } };
}

// Accepte HH:MM ou HH:MM:SS — get_available_slots renvoie ses horaires avec
// les secondes (ex. "09:15:00"), et le modèle les réutilise souvent tels
// quels lors de create_booking/reschedule_booking plutôt que de les
// retronquer ; sans cette tolérance, un horaire pourtant valide échouait
// silencieusement la validation stricte HH:MM et retombait sur le message
// générique "informations manquantes".
function normalizeTimeArg(value: unknown): string {
  if (typeof value !== 'string') return '';
  const m = /^(\d{2}:\d{2})(?::\d{2})?$/.exec(value.trim());
  return m ? m[1] + ':00' : '';
}

async function toolCreateBooking(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const serviceSlug = typeof args.service_slug === 'string' ? args.service_slug.trim() : '';
  const date = typeof args.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(args.date) ? args.date : '';
  const startTime = normalizeTimeArg(args.start_time);
  const customerType = args.customer_type === 'professionnel' ? 'professionnel' : args.customer_type === 'particulier' ? 'particulier' : '';
  const customerName = typeof args.customer_name === 'string' ? args.customer_name.trim().slice(0, 120) : '';
  const customerPhone = typeof args.customer_phone === 'string' ? args.customer_phone.trim().slice(0, 30) : '';
  const customerAddress = typeof args.customer_address === 'string' ? args.customer_address.trim().slice(0, 300) : null;
  const notes = typeof args.notes === 'string' ? args.notes.trim().slice(0, 500) : null;

  if (!serviceSlug || !date || !startTime || !customerType || !customerName || !customerPhone) {
    return { ok: false, error: 'Informations manquantes pour créer le rendez-vous (prestation, date, heure, type de client, nom, téléphone).' };
  }

  const { data: service } = await ctx.supabase.from('services').select('id, name, duration_minutes, is_active').eq('slug', serviceSlug).maybeSingle();
  if (!service || !service.is_active) return { ok: false, error: "Cette prestation n'existe pas ou n'est plus active." };

  // Revérification IMMÉDIATE de la disponibilité avant écriture — jamais de
  // confiance dans une proposition faite plus tôt dans la conversation
  // (elle peut être périmée). Contre une double réservation : voir
  // commentaire de get_available_slots_for_service (lecture des VRAIES
  // bookings) — en Phase 1, l'écriture elle-même va dans une table de test
  // isolée, donc sans contrainte d'exclusion propre ; la garantie
  // "jamais deux clients réels sur le même créneau" reste entièrement celle
  // de la contrainte bookings_no_overlapping_slots existante sur la table
  // de production, non affectée par le simulateur.
  const { data: slots, error: slotsErr } = await ctx.supabase.rpc('get_available_slots_for_service', { p_service_slug: serviceSlug, p_date: date, p_max_slots: 50 });
  if (slotsErr) return { ok: false, error: 'Impossible de revérifier la disponibilité.' };
  const stillFree = (slots || []).some((s: { start_time: string }) => s.start_time.slice(0, 5) === startTime.slice(0, 5));
  if (!stillFree) return { ok: false, error: 'Ce créneau ne semble plus disponible — proposez-en un autre via get_available_slots.' };

  const reference = genTestReference();
  const { data: inserted, error: insertErr } = await ctx.supabase
    .from('voice_test_bookings')
    .insert({
      session_id: ctx.sessionId,
      reference,
      service_id: service.id,
      customer_type: customerType,
      customer_name: customerName,
      customer_phone: customerPhone,
      customer_address: customerAddress,
      date,
      start_time: startTime,
      duration_minutes: service.duration_minutes || 60,
      notes,
    })
    .select('id, reference')
    .single();
  if (insertErr) {
    // 23P01 = exclusion_violation (voir voice_test_bookings_no_overlap,
    // 0036) : filet de sécurité ATOMIQUE contre une double réservation même
    // en cas de deux create_booking quasi simultanés sur le même créneau —
    // jamais uniquement la revérification applicative ci-dessus, qui reste
    // sujette à une minuscule fenêtre de course entre la lecture et
    // l'écriture. Message clair au modèle pour qu'il propose autre chose.
    if ((insertErr as { code?: string }).code === '23P01') {
      return { ok: false, error: 'Ce créneau vient tout juste être pris par une autre demande — proposez immédiatement un autre créneau via get_available_slots.' };
    }
    return { ok: false, error: 'Échec de la création du rendez-vous de test.' };
  }
  if (!inserted) return { ok: false, error: 'Échec de la création du rendez-vous de test.' };

  return {
    ok: true,
    data: { reference: inserted.reference, service: service.name, date, start_time: startTime.slice(0, 5), is_test: true },
    sessionPatch: { customer_type: customerType, test_booking_id: inserted.id },
  };
}

async function toolGetBooking(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const reference = typeof args.reference === 'string' ? args.reference.trim() : '';
  if (!reference) return { ok: false, error: 'reference manquante.' };
  // Portée par référence seule — voir commentaire dans toolCancelBooking.
  const { data, error } = await ctx.supabase
    .from('voice_test_bookings')
    .select('reference, date, start_time, status, customer_name, services(name)')
    .eq('reference', reference)
    .maybeSingle();
  if (error) return { ok: false, error: 'Recherche indisponible.' };
  if (!data) return { ok: false, error: 'Aucun rendez-vous trouvé avec cette référence.' };
  return { ok: true, data: { ...data } };
}

async function toolRescheduleBooking(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const reference = typeof args.reference === 'string' ? args.reference.trim() : '';
  const newDate = typeof args.new_date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(args.new_date) ? args.new_date : '';
  const newStartTime = normalizeTimeArg(args.new_start_time);
  if (!reference || !newDate || !newStartTime) return { ok: false, error: 'reference, new_date et new_start_time sont requis.' };

  // Portée par référence seule — voir commentaire équivalent dans
  // toolCancelBooking : un déplacement se demande nécessairement depuis un
  // nouvel appel puisque l'appel de création s'est déjà terminé.
  const { data: booking } = await ctx.supabase
    .from('voice_test_bookings')
    .select('id, status, service_id, services(slug)')
    .eq('reference', reference)
    .maybeSingle();
  if (!booking) return { ok: false, error: 'Aucun rendez-vous trouvé avec cette référence.' };
  if (booking.status !== 'CONFIRMED') return { ok: false, error: 'Ce rendez-vous ne peut plus être modifié (déjà annulé).' };

  const slug = (booking.services as { slug: string } | null)?.slug;
  if (slug) {
    const { data: slots } = await ctx.supabase.rpc('get_available_slots_for_service', { p_service_slug: slug, p_date: newDate, p_max_slots: 50 });
    const stillFree = (slots || []).some((s: { start_time: string }) => s.start_time.slice(0, 5) === newStartTime.slice(0, 5));
    if (!stillFree) return { ok: false, error: 'Ce nouveau créneau ne semble plus disponible.' };
  }

  const { error: updErr } = await ctx.supabase.from('voice_test_bookings').update({ date: newDate, start_time: newStartTime }).eq('id', booking.id);
  if (updErr) {
    if ((updErr as { code?: string }).code === '23P01') {
      return { ok: false, error: 'Ce nouveau créneau vient tout juste être pris — proposez-en un autre.' };
    }
    return { ok: false, error: 'Échec du déplacement du rendez-vous.' };
  }
  return { ok: true, data: { reference, new_date: newDate, new_start_time: newStartTime.slice(0, 5) } };
}

async function toolCancelBooking(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const reference = typeof args.reference === 'string' ? args.reference.trim() : '';
  if (!reference) return { ok: false, error: 'reference manquante.' };
  // Portée par référence seule (pas par session) : un rendez-vous de test
  // est nécessairement créé lors d'un appel qui se termine ensuite
  // (call_state passe à completed, terminal) — un client qui rappelle pour
  // annuler le fait forcément depuis un NOUVEL appel/session. La référence
  // aléatoire (TEST-VOICE-XXXXXX) reste l'identifiant fonctionnel, exactement
  // comme en production où reference+nom suffisent à retrouver un RDV.
  const { data: booking } = await ctx.supabase
    .from('voice_test_bookings')
    .select('id, status')
    .eq('reference', reference)
    .maybeSingle();
  if (!booking) return { ok: false, error: 'Aucun rendez-vous trouvé avec cette référence.' };
  if (booking.status !== 'CONFIRMED') return { ok: false, error: 'Ce rendez-vous est déjà annulé.' };
  const { error: updErr } = await ctx.supabase.from('voice_test_bookings').update({ status: 'CANCELLED', cancelled_at: new Date().toISOString() }).eq('id', booking.id);
  if (updErr) return { ok: false, error: "Échec de l'annulation." };
  return { ok: true, data: { reference, status: 'CANCELLED' } };
}

async function toolCreateCallbackRequest(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const reason = typeof args.reason === 'string' ? args.reason.trim().slice(0, 300) : '';
  // Repli sur le téléphone déjà enregistré via record_customer_info dans
  // cette même session — un rappel humain n'a de sens que si un numéro est
  // réellement joignable, et le modèle ne le repasse pas toujours en
  // argument même quand il l'a déjà obtenu du client (observé en test).
  const argPhone = typeof args.customer_phone === 'string' ? args.customer_phone.trim().slice(0, 30) : '';
  const phone = argPhone || ctx.session.customer_phone || null;
  if (!reason) return { ok: false, error: 'reason manquant.' };
  // Phase 1 : pas encore de table dédiée aux demandes de rappel réelles
  // (prévue en Phase 5, "Être rappelé par l'assistant"/appels sortants) —
  // la demande est simplement journalisée comme événement de la session,
  // visible dans le simulateur, jamais perdue silencieusement.
  return { ok: true, data: { reason, customer_phone: phone, logged: true } };
}

async function toolGetCustomer(_ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const phone = typeof args.phone === 'string' ? args.phone.trim() : '';
  if (!phone) return { ok: false, error: 'phone manquant.' };
  // Volontairement jamais implémenté sur de vraies données en simulation :
  // aucune fiche client réelle ne doit être consultable depuis un test.
  return { ok: true, data: { found: false, note: 'Recherche client réelle non disponible en mode simulateur (Phase 1).' } };
}

// Whitelist stricte des champs modifiables + validation individuelle —
// jamais un simple "...args" recopié tel quel (un champ mal orthographié
// ou d'un type inattendu envoyé par le modèle est silencieusement ignoré
// plutôt que de corrompre la session).
const URGENCY_VALUES = ['normale', 'elevee', 'urgence'];
const CUSTOMER_TYPE_VALUES = ['particulier', 'professionnel'];
const SERVICE_CATEGORY_VALUES = ['plomberie', 'chauffage', 'climatisation', 'autre'];

async function toolRecordCustomerInfo(_ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const patch: SessionPatch = {};
  const recorded: string[] = [];

  function str(key: string, max: number) {
    const v = args[key];
    if (typeof v === 'string' && v.trim()) { (patch as Record<string, unknown>)[key] = v.trim().slice(0, max); recorded.push(key); }
  }
  function enumField(key: string, allowed: string[]) {
    const v = args[key];
    if (typeof v === 'string' && allowed.includes(v)) { (patch as Record<string, unknown>)[key] = v; recorded.push(key); }
  }

  str('customer_name', 120);
  str('customer_phone', 30);
  str('customer_address', 300);
  str('customer_city', 120);
  str('problem_description', 500);
  str('desired_slot_label', 120);
  enumField('customer_type', CUSTOMER_TYPE_VALUES);
  enumField('service_category', SERVICE_CATEGORY_VALUES);
  enumField('urgency_level', URGENCY_VALUES);
  const desiredDate = args.desired_date;
  if (typeof desiredDate === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(desiredDate)) { patch.desired_date = desiredDate; recorded.push('desired_date'); }

  if (!recorded.length) return { ok: false, error: 'Aucune information valide à enregistrer.' };
  return { ok: true, data: { recorded }, sessionPatch: patch };
}

async function toolGetServicePrice(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const serviceSlug = typeof args.service_slug === 'string' ? args.service_slug.trim() : '';
  if (!serviceSlug) return { ok: false, error: 'service_slug manquant.' };
  const { data: service } = await ctx.supabase
    .from('services')
    .select('id, name, base_price_cents, price_display_mode, is_active')
    .eq('slug', serviceSlug)
    .maybeSingle();
  if (!service || !service.is_active) return { ok: false, error: "Cette prestation n'existe pas ou n'est plus active." };

  if (service.base_price_cents == null) {
    // Service décliné en formules (service_packs) : jamais un prix unique.
    const { data: packs } = await ctx.supabase
      .from('service_packs')
      .select('name, price_cents, duration_minutes')
      .eq('service_id', service.id)
      .eq('is_active', true)
      .order('sort_order');
    return { ok: true, data: { service: service.name, packs: (packs || []).map((p) => ({ name: p.name, price_euros: p.price_cents / 100, duration_minutes: p.duration_minutes })) } };
  }
  if (service.price_display_mode === 'QUOTE') {
    return { ok: true, data: { service: service.name, mode: 'QUOTE', note: 'Sur devis — aucun tarif fixe communicable, un devis personnalisé gratuit est proposé.' } };
  }
  return {
    ok: true,
    data: {
      service: service.name,
      mode: service.price_display_mode,
      price_euros: service.base_price_cents / 100,
      note: service.price_display_mode === 'FROM' ? 'Tarif "à partir de" — le prix définitif dépend du diagnostic.' : 'Tarif ferme TTC.',
    },
  };
}

async function toolGetTravelInformation(ctx: ToolContext): Promise<ToolResult> {
  const { data, error } = await ctx.supabase.from('travel_settings_public').select('origin_label, included_radius_km, rate_per_km_cents').maybeSingle();
  if (error || !data) return { ok: false, error: 'Informations de déplacement indisponibles pour le moment.' };
  return {
    ok: true,
    data: {
      origin: data.origin_label,
      included_radius_km: data.included_radius_km,
      rate_per_km_euros: data.rate_per_km_cents / 100,
      note: "Distance exacte non calculée en simulation (Phase 1) — le montant réel sera confirmé automatiquement avant la validation d'un vrai rendez-vous.",
    },
  };
}

const HANDLERS: Record<string, (ctx: ToolContext, args: Record<string, unknown>) => Promise<ToolResult>> = {
  set_call_state: toolSetCallState,
  get_service_information: toolGetServiceInformation,
  get_available_slots: toolGetAvailableSlots,
  create_booking: toolCreateBooking,
  get_booking: toolGetBooking,
  reschedule_booking: toolRescheduleBooking,
  cancel_booking: toolCancelBooking,
  create_callback_request: toolCreateCallbackRequest,
  get_customer: toolGetCustomer,
  record_customer_info: toolRecordCustomerInfo,
  get_service_price: toolGetServicePrice,
  get_travel_information: toolGetTravelInformation,
};

export async function executeTool(name: string, ctx: ToolContext, args: Record<string, unknown>): Promise<ToolResult> {
  const handler = HANDLERS[name];
  if (!handler) return { ok: false, error: `Outil inconnu : ${name}` };
  try {
    return await handler(ctx, args || {});
  } catch (e) {
    console.error('voice tool error', name, e instanceof Error ? e.message : e);
    return { ok: false, error: 'Erreur technique lors de l\'exécution de cet outil.' };
  }
}
