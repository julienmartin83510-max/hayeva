// HAYEVA Voice — machine d'état de l'appel
//
// La machine d'état appartient au MOTEUR, jamais au modèle : le LLM peut
// DEMANDER une transition (via l'outil set_call_state, voir tools.ts), mais
// c'est toujours canTransition() ci-dessous qui décide si elle est
// acceptée. Un modèle qui "invente" un état ou saute une étape ne peut
// jamais faire avancer l'appel au-delà de ce que ce graphe autorise.

export type CallState =
  | 'incoming' | 'greeting' | 'identify_need' | 'collect_information'
  | 'check_availability' | 'propose_slots' | 'confirmation' | 'create_booking'
  | 'completed' | 'human_transfer' | 'callback_required' | 'failed' | 'cancelled';

export const ALL_STATES: CallState[] = [
  'incoming', 'greeting', 'identify_need', 'collect_information',
  'check_availability', 'propose_slots', 'confirmation', 'create_booking',
  'completed', 'human_transfer', 'callback_required', 'failed', 'cancelled',
];

export const TERMINAL_STATES: CallState[] = ['completed', 'human_transfer', 'callback_required', 'failed', 'cancelled'];

// Chemin nominal explicite — reflète exactement l'énoncé du cahier des
// charges (incoming → greeting → ... → completed).
const HAPPY_PATH: Record<string, CallState[]> = {
  incoming: ['greeting'],
  greeting: ['identify_need'],
  identify_need: ['collect_information'],
  // Boucle sur elle-même tant que des informations manquent — voir §3
  // "récupérer progressivement les informations" : ce n'est pas un aller
  // simple, le modèle peut redemander tant qu'il ne dispose pas de tout.
  collect_information: ['collect_information', 'check_availability'],
  check_availability: ['propose_slots', 'callback_required'],
  // Le client peut redemander d'autres créneaux, ou revenir en arrière si
  // finalement plus rien ne convient.
  propose_slots: ['propose_slots', 'confirmation', 'check_availability'],
  // Avant confirmation explicite du client, retour possible vers d'autres
  // créneaux, ou abandon.
  confirmation: ['create_booking', 'propose_slots', 'cancelled'],
  create_booking: ['completed', 'failed'],
};

// Échappatoires globales : depuis N'IMPORTE QUEL état non terminal, le
// moteur peut toujours basculer vers ces trois états — c'est exactement le
// "reconnaître les situations qu'il ne peut pas gérer" du cahier des
// charges, qui ne doit jamais être bloqué par le chemin nominal.
const GLOBAL_ESCAPES: CallState[] = ['human_transfer', 'failed', 'callback_required'];

export function canTransition(from: CallState, to: CallState): boolean {
  if (from === to) return true; // rester dans le même état (ex. reformuler une question) est toujours permis
  if (TERMINAL_STATES.includes(from)) return false; // un état terminal ne repart jamais
  if (GLOBAL_ESCAPES.includes(to)) return true;
  return (HAPPY_PATH[from] || []).includes(to);
}

export function isTerminal(state: CallState): boolean {
  return TERMINAL_STATES.includes(state);
}
