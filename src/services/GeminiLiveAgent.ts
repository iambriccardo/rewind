import {
  GoogleGenAI,
  MediaResolution,
  Modality,
  type FunctionCall,
  type FunctionResponse,
  type LiveConnectConfig,
  type LiveServerMessage,
  type Session,
  type Tool
} from '@google/genai';
import { config } from '../config.js';
import type { ClientMessage, JsonObject, ToolCall } from '../types.js';

const SUPPORTED_TOOLS = ['create_rewind', 'search_rewinds', 'show_rewind'] as const;
type SupportedToolName = (typeof SUPPORTED_TOOLS)[number];
type LiveState = 'connecting' | 'transport_open' | 'connected' | 'closed' | 'error';
type QueuedLiveInput =
  | { type: 'text'; text: string }
  | { type: 'media'; message: Extract<ClientMessage, { type: 'user.media' }> }
  | { type: 'audio_end' };

type LiveCallbacks = {
  onState: (state: LiveState, payload?: JsonObject) => void;
  onText: (text: string) => void;
  onAudio: (data: string, mimeType: string) => void;
  onToolCalls: (toolCalls: ToolCall[]) => void | Promise<void>;
};

export class GeminiLiveAgent {
  readonly model = config.LIVE_MODEL_NAME;
  private readonly ai: GoogleGenAI;
  private readonly pendingTexts: string[] = [];
  private readonly queuedInputs: QueuedLiveInput[] = [];
  private liveSession?: Session;
  private liveConnecting = false;
  private liveReady = false;
  private liveClosed = false;
  private clientSeq = 0;
  private readonly maxQueuedInputs = 80;

  constructor() {
    if (!config.MODEL_API_KEY) {
      throw new Error('MODEL_API_KEY is required.');
    }
    this.ai = new GoogleGenAI({ apiKey: config.MODEL_API_KEY });
  }

  getToolDeclarations(): JsonObject[] {
    return [
      {
        name: 'create_rewind',
        description:
          'Create a pending rewind event. Use this whenever the user asks to remember, save, capture, or recall a physical-world moment. The backend will ask the trusted device to capture its local rolling buffer.',
        parametersJsonSchema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            title: { type: 'string' },
            description: { type: 'string' },
            entities: { type: 'array', items: { type: 'string' } },
            location_hint: { type: 'string' },
            rewind_duration_seconds: {
              type: 'integer',
              minimum: 1,
              maximum: 60,
              description: 'How many seconds of the phone rolling buffer should be preserved for this rewind.'
            }
          },
          required: ['title', 'description', 'rewind_duration_seconds']
        }
      },
      {
        name: 'search_rewinds',
        description:
          'Search rewind metadata using semantic embeddings plus database filters. Include only useful filters that narrow the query.',
        parametersJsonSchema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            query: { type: 'string' },
            limit: { type: 'integer', minimum: 1, maximum: 20 },
            time_range: {
              type: 'object',
              additionalProperties: false,
              properties: {
                started_after: { type: 'string' },
                ended_before: { type: 'string' }
              }
            },
            entities: { type: 'array', items: { type: 'string' } },
            location_hint: { type: 'string' }
          },
          required: ['query']
        }
      },
      {
        name: 'show_rewind',
        description:
          'Show a selected rewind on the trusted phone. Only call after search_rewinds or when the event_id is known and validated by the backend.',
        parametersJsonSchema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            event_id: { type: 'string' },
            answer_text: { type: 'string' }
          },
          required: ['event_id']
        }
      }
    ];
  }

  async connectLive(callbacks: LiveCallbacks): Promise<void> {
    callbacks.onState('connecting');
    this.liveConnecting = true;
    this.liveReady = false;
    this.liveClosed = false;
    this.queuedInputs.length = 0;
    this.liveSession = await this.ai.live.connect({
      model: config.LIVE_MODEL_NAME,
      config: this.getLiveConfig(),
      callbacks: {
        onopen: () => {
          callbacks.onState('transport_open', { ready: false });
        },
        onmessage: (message: LiveServerMessage) => {
          this.handleLiveMessage(message, callbacks);
        },
        onerror: (event) => {
          callbacks.onState('error', {
            error: String(event.error ?? event.message ?? event),
            message: event.message ?? undefined,
            type: event.type ?? undefined
          });
        },
        onclose: (event) => {
          this.liveReady = false;
          this.liveConnecting = false;
          this.liveClosed = true;
          this.liveSession = undefined;
          this.queuedInputs.length = 0;
          callbacks.onState('closed', {
            code: event.code,
            reason: event.reason || undefined,
            was_clean: event.wasClean
          });
        }
      }
    });
    this.liveConnecting = false;
  }

  close(): void {
    this.liveSession?.close();
    this.liveSession = undefined;
    this.liveConnecting = false;
    this.liveReady = false;
    this.liveClosed = true;
    this.queuedInputs.length = 0;
  }

  isLiveActive(): boolean {
    return Boolean(this.liveSession && this.liveReady);
  }

  sendLiveText(text: string): void {
    if (!this.liveSession || !this.liveReady) {
      this.enqueue({ type: 'text', text });
      return;
    }
    this.sendLiveTextNow(text);
  }

  private sendLiveTextNow(text: string): void {
    this.liveSession?.sendClientContent({
      turns: [{ role: 'user', parts: [{ text }] }],
      turnComplete: true
    });
  }

  sendLiveTurn(_state: 'start' | 'end'): void {
    // The MVP uses Gemini's automatic VAD. Client turn markers are kept in our
    // protocol logs, but are not forwarded as manual activity signals.
  }

  sendLiveMedia(message: Extract<ClientMessage, { type: 'user.media' }>): void {
    if (!this.liveSession || !this.liveReady) {
      this.enqueue({ type: 'media', message });
      return;
    }
    this.sendLiveMediaNow(message);
  }

  private sendLiveMediaNow(message: Extract<ClientMessage, { type: 'user.media' }>): void {
    this.clientSeq = Math.max(this.clientSeq + 1, message.seq ?? 0);
    const blob = { data: message.data, mimeType: message.mime_type };
    if (message.modality === 'audio') this.liveSession?.sendRealtimeInput({ audio: blob });
    else if (message.modality === 'video') this.liveSession?.sendRealtimeInput({ video: blob });
    else this.liveSession?.sendRealtimeInput({ media: blob });
  }

  sendLiveMediaEnd(modality: 'audio' | 'video' | 'image'): void {
    if (modality !== 'audio') return;
    if (!this.liveSession || !this.liveReady) {
      this.enqueue({ type: 'audio_end' });
      return;
    }
    this.liveSession.sendRealtimeInput({ audioStreamEnd: true });
  }

  sendLiveToolResponse(toolCall: ToolCall, result: JsonObject): void {
    if (!this.liveSession) return;
    const response: FunctionResponse = {
      id: toolCall.id,
      name: toolCall.name,
      response: { output: result }
    };
    this.liveSession.sendToolResponse({ functionResponses: response });
  }

  takePendingTexts(): string[] {
    return this.pendingTexts.splice(0);
  }

  async handleUserText(text: string): Promise<ToolCall[]> {
    this.sendLiveText(text);
    return [];
  }

  async handleToolResult(toolCall: ToolCall, result: JsonObject): Promise<ToolCall[]> {
    if (this.isLiveActive()) {
      this.sendLiveToolResponse(toolCall, result);
      return [];
    }

    throw new Error(`Live model session is not connected while handling ${toolCall.name}.`);
  }

  private handleLiveMessage(message: LiveServerMessage, callbacks: LiveCallbacks): void {
    if (message.setupComplete) {
      this.liveReady = true;
      callbacks.onState('connected', {
        setup_complete: true,
        provider_session_id: message.setupComplete.sessionId
      });
      this.flushQueuedInputs();
    }
    const outputTranscript = message.serverContent?.outputTranscription?.text;
    if (outputTranscript) callbacks.onText(outputTranscript);
    for (const part of message.serverContent?.modelTurn?.parts ?? []) {
      if (part.inlineData?.data) {
        callbacks.onAudio(part.inlineData.data, part.inlineData.mimeType ?? 'audio/pcm;rate=24000');
      }
    }
    if (message.text) callbacks.onText(message.text);
    if (message.sessionResumptionUpdate) {
      callbacks.onState('connected', {
        session_resumption: message.sessionResumptionUpdate
      });
    }
    const calls = normalizeFunctionCalls(message.toolCall?.functionCalls ?? []);
    if (calls.length) {
      void callbacks.onToolCalls(calls);
    }
  }

  private getGeminiTools(): Tool[] {
    return [
      {
        functionDeclarations: this.getToolDeclarations()
      }
    ];
  }

  private enqueue(input: QueuedLiveInput): void {
    if (this.liveClosed || (!this.liveConnecting && !this.liveSession)) {
      throw new Error('Gemini Live session is closed.');
    }
    this.queuedInputs.push(input);
    while (this.queuedInputs.length > this.maxQueuedInputs) {
      this.queuedInputs.shift();
    }
  }

  private flushQueuedInputs(): void {
    while (this.liveReady && this.queuedInputs.length) {
      const input = this.queuedInputs.shift();
      if (!input) continue;
      if (input.type === 'text') this.sendLiveTextNow(input.text);
      else if (input.type === 'media') this.sendLiveMediaNow(input.message);
      else this.liveSession?.sendRealtimeInput({ audioStreamEnd: true });
    }
  }

  private getLiveConfig(): LiveConnectConfig {
    const liveConfig: LiveConnectConfig = {
      responseModalities: usesNativeAudioModel(config.LIVE_MODEL_NAME) ? [Modality.AUDIO] : [Modality.TEXT],
      temperature: 0.2,
      maxOutputTokens: 256,
      mediaResolution: MediaResolution.MEDIA_RESOLUTION_LOW,
      systemInstruction: systemInstruction(),
      tools: this.getGeminiTools()
    };

    if (usesNativeAudioModel(config.LIVE_MODEL_NAME)) {
      liveConfig.inputAudioTranscription = {};
      liveConfig.outputAudioTranscription = {};
      liveConfig.thinkingConfig = { thinkingBudget: 0 };
    }

    return liveConfig;
  }
}

function normalizeFunctionCalls(calls: FunctionCall[]): ToolCall[] {
  return calls
    .filter((call): call is FunctionCall & { name: SupportedToolName } => Boolean(call.name) && SUPPORTED_TOOLS.includes(call.name as SupportedToolName))
    .map((call) => ({
      id: call.id ?? crypto.randomUUID(),
      name: call.name,
      args: call.args ?? {}
    }));
}

function usesNativeAudioModel(model: string): boolean {
  return model.includes('native-audio');
}

function systemInstruction(): string {
  return [
    'You are Rewind, a quiet real-time memory agent behind a trusted phone client.',
    'The phone owns camera/audio rolling buffers and local media. For this MVP, the backend stores structured metadata, frame UUIDs, timestamps, captions, labels, location hints, and event embeddings. Do not ask to store raw image/video bytes.',
    'Default behavior is passive observation. Background audio, video, or images alone are not a reason to call a tool or send a message.',
    'Only call tools when the user clearly asks to create/save/remember/capture a rewind, or asks to search/find/show a previous rewind.',
    'Broad create_rewind intents include: "remember this", "save that I did this", "remember where I put X", "capture this", "save this moment", "remember where I left X", "make a rewind of this", and similar phrasing.',
    'For create_rewind, always include rewind_duration_seconds. Pick a compact duration that fits the request: usually 5-10 seconds, longer only if the user asks for more context.',
    'For create_rewind, include only a concise title, useful description, rewind_duration_seconds, entities, and optional location_hint.',
    'Use search_rewinds when the user asks where something is, what happened, or asks to find/search/show a memory.',
    'For search_rewinds, include only useful narrowing filters: entities, time_range, and location_hint.',
    'After search_rewinds returns useful candidates, call show_rewind for the best candidate unless the user only asked for a textual answer.',
    'When calling show_rewind, rely on backend-validated event IDs and frame UUIDs. Never invent event IDs or frame IDs.',
    'Keep tool arguments compact and structured. The backend validates every tool call and converts tool calls into trusted phone commands.'
  ].join('\n');
}
