// Supabase Edge Function — HAYEVA Voice, canal navigateur : exécution
// SERVEUR d'un appel d'outil demandé par la session OpenAI Realtime.
//
// Pourquoi une fonction séparée de voice-realtime-session : la session
// audio WebRTC elle-même est une connexion DIRECTE navigateur↔OpenAI (voir
// voice-realtime-session/index.ts) — notre serveur n'est jamais dans le
// flux audio. Mais quand le modèle veut appeler un outil métier
// (get_available_slots, guide_to_booking...), OpenAI notifie le NAVIGATEUR
// via le data channel WebRTC ; le navigateur doit alors demander à NOTRE
// serveur d'exécuter réellement l'outil (jamais le navigateur lui-même :
// voir §"SÉCURITÉ GÉNÉRALE DES ACTIONS", le LLM propose, le serveur
// décide) puis renvoie le résultat validé dans la session via le data
// channel. Cette fonction est ce point d'exécution serveur.
//
// Mêmes garanties que le simulateur admin (tools.ts, state-machine.ts) :
// le modèle ne voit jamais de SQL, chaque outil valide ses propres
// arguments, aucune donnée secrète n'est jamais renvoyée. Différence
// clé : le sous-ensemble d'outils autorisés ici (REALTIME_ALLOWED_TOOLS)
// exclut explicitement create_booking/reschedule_booking/cancel_booking —
// ce canal public ne crée JAMAIS de réservation de production directement,
// il oriente le client vers le vrai tunnel de réservation (guide_to_booking).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { executeTool, REALTIME_ALLOWED_TOOLS, type ToolContext, type SessionInfo } from '../_shared/voice/tools.ts';
import { canTransition, isTerminal, shortestPathForward, type CallState } from '../_shared/voice/state-machine.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const AUTO_ADVANCE_TARGET: Partial<Record<string, CallState>> = {
  record_customer_info: 'collect_information',
  get_service_information: 'collect_information',
  get_available_slots: 'check_availability',
  guide_to_booking: 'confirmation',
  create_callback_request: 'callback_required',
};

const INFO_COLUMNS = [
  'customer_type', 'service_category', 'customer_name', 'customer_phone',
  'customer_address', 'customer_city', 'problem_description', 'urgency_level',
  'desired_date', 'desired_slot_label',
] as const;

type SessionRow = {
  id: string;
  call_state: CallState;
  message_count: number;
  client_session_id: string | null;
  channel: string;
} & Record<(typeof INFO_COLUMNS)[number], string | null>;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders } });

  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const body = await req.json().catch(() => ({}));
    const sessionId = typeof body.session_id === 'string' ? body.session_id : '';
    const clientSessionId = typeof body.client_session_id === 'string' ? body.client_session_id.trim().slice(0, 100) : '';
    const toolName = typeof body.tool_name === 'string' ? body.tool_name : '';
    const toolArgs = (body.tool_args && typeof body.tool_args === 'object') ? body.tool_args as Record<string, unknown> : {};
    if (!sessionId || !clientSessionId || !toolName) return json({ error: 'invalid_input' }, 400);
    if (!REALTIME_ALLOWED_TOOLS.includes(toolName)) return json({ ok: false, error: 'Outil non autorisé sur ce canal.' }, 200);

    const { data: settings } = await supabase
      .from('voice_assistant_settings')
      .select('enabled, realtime_enabled, realtime_max_messages_per_session')
      .eq('id', true)
      .maybeSingle();
    if (!settings || !settings.enabled || !settings.realtime_enabled) return json({ ok: false, error: 'Service indisponible.' }, 200);

    const selectCols = `id, call_state, message_count, client_session_id, channel, ${INFO_COLUMNS.join(', ')}`;
    const { data: existing } = await supabase.from('voice_call_sessions').select(selectCols).eq('id', sessionId).maybeSingle();
    // Vérification d'appartenance : jamais confiance dans le session_id seul
    // envoyé par le navigateur — il doit correspondre au client_session_id
    // qui a réellement créé cette session (même patron que ai-assistant.ts
    // pour ai_conversations).
    if (!existing || (existing as SessionRow).client_session_id !== clientSessionId || (existing as SessionRow).channel !== 'realtime_browser') {
      return json({ ok: false, error: 'Session introuvable.' }, 200);
    }
    const session = existing as SessionRow;
    if (isTerminal(session.call_state)) return json({ ok: false, error: 'Cette conversation est terminée.' }, 200);
    if (session.message_count >= settings.realtime_max_messages_per_session) return json({ ok: false, error: 'Limite atteinte pour cette conversation.' }, 200);

    const sessionInfo: SessionInfo = {
      call_state: session.call_state,
      customer_type: session.customer_type,
      service_category: session.service_category,
      customer_name: session.customer_name,
      customer_phone: session.customer_phone,
      customer_address: session.customer_address,
      customer_city: session.customer_city,
      problem_description: session.problem_description,
      urgency_level: session.urgency_level,
      desired_date: session.desired_date,
      desired_slot_label: session.desired_slot_label,
    };
    const ctx: ToolContext = { supabase, sessionId, session: sessionInfo };
    const result = await executeTool(toolName, ctx, toolArgs);

    let seq = 0;
    const { data: lastEvent } = await supabase.from('voice_call_events').select('seq').eq('session_id', sessionId).order('seq', { ascending: false }).limit(1).maybeSingle();
    seq = (lastEvent?.seq ?? -1) + 1;
    const insertEvent = async (event: Record<string, unknown>) => {
      await supabase.from('voice_call_events').insert({ session_id: sessionId, seq: seq++, created_at: new Date().toISOString(), ...event });
    };
    await insertEvent({ type: 'tool_call', tool_name: toolName, tool_args: toolArgs });
    const resultData = result.ok ? result.data ?? {} : { error: result.error };
    await insertEvent({ type: 'tool_result', tool_name: toolName, tool_result: resultData });

    let currentState = session.call_state;
    if (result.ok && result.sessionPatch) {
      const patch = result.sessionPatch;
      if (patch.call_state && patch.call_state !== currentState && canTransition(currentState, patch.call_state)) {
        currentState = patch.call_state;
        await insertEvent({ type: 'state_change', state: currentState });
      }
      for (const col of INFO_COLUMNS) {
        const v = (patch as Record<string, unknown>)[col];
        if (typeof v === 'string' && v) (session as Record<string, unknown>)[col] = v;
      }
    }
    if (result.ok) {
      let target = AUTO_ADVANCE_TARGET[toolName];
      if (toolName === 'get_available_slots') {
        const hasSlots = Array.isArray((result.data as { slots?: unknown[] } | undefined)?.slots) && (result.data as { slots: unknown[] }).slots.length > 0;
        if (hasSlots) target = 'propose_slots';
      }
      if (target) {
        const path = shortestPathForward(currentState, target);
        if (path && path.length) {
          for (const step of path) {
            currentState = step;
            await insertEvent({ type: 'state_change', state: currentState });
          }
        }
      }
    }

    const updatePayload: Record<string, unknown> = {
      call_state: currentState,
      message_count: session.message_count + 1,
      updated_at: new Date().toISOString(),
      ended_at: isTerminal(currentState) ? new Date().toISOString() : null,
    };
    for (const col of INFO_COLUMNS) updatePayload[col] = (session as Record<string, unknown>)[col] ?? null;
    await supabase.from('voice_call_sessions').update(updatePayload).eq('id', sessionId);

    const today = new Date().toISOString().slice(0, 10);
    const { data: usageRow } = await supabase.from('voice_realtime_usage_daily').select('tool_call_count').eq('usage_date', today).maybeSingle();
    if (usageRow) {
      await supabase.from('voice_realtime_usage_daily').update({ tool_call_count: usageRow.tool_call_count + 1, updated_at: new Date().toISOString() }).eq('usage_date', today);
    }

    return json({ ok: result.ok, data: resultData, call_state: currentState }, 200);
  } catch (e) {
    console.error('voice-realtime-tool: erreur inattendue', e);
    return json({ ok: false, error: 'Erreur technique.' }, 200);
  }
});
