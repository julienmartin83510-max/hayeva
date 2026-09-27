// HAYEVA Voice — interfaces des adaptateurs Téléphonie / STT / TTS
//
// AUCUNE implémentation ici en Phase 1 — ce fichier ne fait que déclarer les
// contrats que devront respecter les futurs adaptateurs concrets (Twilio,
// Telnyx, Deepgram, ElevenLabs...), pour que le moteur HAYEVA Voice
// (state-machine.ts, tools.ts) puisse être écrit et testé (Phase 1, via le
// simulateur texte) SANS dépendre d'aucun fournisseur, puis branché à un
// vrai appel (Phase 3+) sans réécrire le cœur.
//
// Phase 1 : aucune de ces interfaces n'est instanciée (pas d'appel
// téléphonique réel, pas de STT/TTS). Elles sont posées maintenant pour
// documenter la frontière exacte que respectera l'implémentation à venir.

/** Une trame audio brute échangée avec la passerelle téléphonique. */
export interface AudioFrame {
  data: Uint8Array;
  timestampMs: number;
}

/**
 * Connexion à un fournisseur de téléphonie (Twilio, Telnyx...) pour UN appel.
 * Une instance par appel — jamais d'état partagé entre appels (voir Phase 8,
 * "plusieurs appels simultanés").
 */
export interface TelephonyProvider {
  /** Décroche/initie l'appel et ouvre le flux audio bidirectionnel. */
  connect(): Promise<void>;
  /** Envoie une trame audio synthétisée (TTS) vers l'appelant. */
  sendAudioFrame(frame: AudioFrame): Promise<void>;
  /** Vide immédiatement le buffer de sortie — utilisé pour couper l'assistant en cas d'interruption (voir Phase 2/4). */
  clearOutboundBuffer(): Promise<void>;
  /** S'abonne aux trames audio entrantes (voix du client). */
  onAudioFrame(handler: (frame: AudioFrame) => void): void;
  /** Raccroche proprement. */
  hangUp(): Promise<void>;
}

/** Reconnaissance vocale en flux continu — un provider par appel. */
export interface SpeechToTextProvider {
  /** Transmet une trame audio entrante pour transcription. */
  sendAudio(frame: AudioFrame): void;
  /** Transcription partielle (encore en cours de prononciation) ou finale (fin de tour de parole détectée). */
  onTranscript(handler: (text: string, isFinal: boolean) => void): void;
}

/** Synthèse vocale en flux — un provider par appel. */
export interface TextToSpeechProvider {
  /** Lance la synthèse d'un texte ; les morceaux audio arrivent via onAudioChunk au fur et à mesure (latence basse, voir §3 de l'architecture). */
  synthesize(text: string): void;
  onAudioChunk(handler: (frame: AudioFrame) => void): void;
  /** Annule une synthèse en cours (barge-in, voir §4). */
  cancel(): void;
}
