// HAYEVA Voice — adaptateur LLM (Phase 1)
//
// Interface générique : le cœur de HAYEVA Voice (state-machine.ts, tools.ts,
// et l'Edge Function voice-assistant-simulate) ne connaît QUE `LLMProvider`,
// jamais OpenRouter ni un format propriétaire directement. Changer de
// fournisseur de modèle plus tard (autre passerelle, appel direct à
// l'API d'un fournisseur, modèle auto-hébergé...) ne demande qu'une
// nouvelle classe implémentant cette interface, jamais une réécriture du
// moteur de conversation — c'est exactement l'exigence de modularité posée
// avant le début de l'implémentation.

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | null;
  // Uniquement pour role='assistant' quand le modèle demande un appel d'outil.
  tool_calls?: ToolCall[];
  // Uniquement pour role='tool' : résultat renvoyé après exécution.
  tool_call_id?: string;
  name?: string;
}

export interface ToolCall {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

export interface ToolSchema {
  name: string;
  description: string;
  // JSON Schema standard (format OpenAI/OpenRouter "function calling").
  parameters: Record<string, unknown>;
}

export interface LLMResponse {
  content: string | null;
  toolCalls: ToolCall[];
}

export interface LLMProvider {
  chat(messages: ChatMessage[], tools: ToolSchema[]): Promise<LLMResponse>;
}

// ------------------------------------------------------------
// Implémentation OpenRouter — même fournisseur et même clé
// (OPENROUTER_API_KEY) que ai-assistant/ai-assistant-pro, jamais une
// deuxième intégration OpenRouter dupliquée. Le modèle est piloté par
// voice_assistant_settings.model_name (modifiable sans redéploiement),
// même principe que ai_settings.model_name pour le chatbot existant.
export class OpenRouterLLMProvider implements LLMProvider {
  constructor(
    private apiKey: string,
    private model: string,
    private siteUrl = 'https://hayeva.fr',
    private timeoutMs = 20000,
  ) {}

  async chat(messages: ChatMessage[], tools: ToolSchema[]): Promise<LLMResponse> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + this.apiKey,
          'Content-Type': 'application/json',
          'HTTP-Referer': this.siteUrl,
          'X-Title': 'HAYEVA Voice',
        },
        body: JSON.stringify({
          model: this.model,
          max_tokens: 400,
          messages: messages.map((m) => {
            if (m.role === 'assistant' && m.tool_calls?.length) {
              return {
                role: 'assistant',
                content: m.content,
                tool_calls: m.tool_calls.map((tc) => ({
                  id: tc.id,
                  type: 'function',
                  function: { name: tc.name, arguments: JSON.stringify(tc.arguments) },
                })),
              };
            }
            if (m.role === 'tool') {
              return { role: 'tool', tool_call_id: m.tool_call_id, content: m.content ?? '' };
            }
            return { role: m.role, content: m.content };
          }),
          tools: tools.length
            ? tools.map((t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.parameters } }))
            : undefined,
        }),
        signal: controller.signal,
      });
      if (!res.ok) {
        const errBody = await res.text().catch(() => '');
        // Ne jamais logger this.apiKey : elle n'apparaît que dans l'en-tête
        // de la requête sortante, jamais dans le corps de la réponse.
        throw new Error(`OpenRouter HTTP ${res.status}: ${errBody.slice(0, 300)}`);
      }
      const json = await res.json();
      const choice = json.choices?.[0]?.message;
      const rawToolCalls = choice?.tool_calls as Array<{ id: string; function: { name: string; arguments: string } }> | undefined;
      const toolCalls: ToolCall[] = (rawToolCalls || []).map((tc) => {
        let args: Record<string, unknown> = {};
        try { args = JSON.parse(tc.function.arguments || '{}'); } catch { /* modèle a renvoyé un JSON invalide — outil traité comme sans arguments valides, jamais planté */ }
        return { id: tc.id, name: tc.function.name, arguments: args };
      });
      return { content: choice?.content ?? null, toolCalls };
    } finally {
      clearTimeout(timeout);
    }
  }
}
