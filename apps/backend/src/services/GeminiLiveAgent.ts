import {
  GoogleGenAI,
  MediaResolution,
  Modality,
  TurnCoverage,
  type FunctionCall,
  type FunctionResponse,
  type LiveConnectConfig,
  type LiveServerMessage,
  type Session,
  type Tool
} from '@google/genai';
import { config } from '../config.js';
import type { ClientMessage, JsonObject, SessionHello, ToolCall } from '../types.js';

const SUPPORTED_TOOLS = ['create_rewind', 'search_rewinds'] as const;
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

  constructor(private readonly clientSession: NormalizedClientSession) {
    if (!config.MODEL_API_KEY) {
      throw new Error('MODEL_API_KEY is required.');
    }
    this.ai = new GoogleGenAI({ apiKey: config.MODEL_API_KEY, httpOptions: { apiVersion: 'v1alpha' } });
  }

  getToolDeclarations(): JsonObject[] {
    return [
      {
        name: 'create_rewind',
        description:
          'Create a pending rewind event only when the user explicitly asks to preserve a current or just-finished physical-world memory. Accept clear save/remember/capture-style intent across languages, but do not infer save intent from background observation alone.',
        parametersJsonSchema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            title: {
              type: 'string',
              description:
                'Short content-specific title naming the saved object, person, place, or activity. Do not use protocol or duration titles like "Last 30 seconds", "Remember this", or "Saved moment" unless the user-provided label is the actual memory content.'
            },
            description: {
              type: 'string',
              description:
                'A compact memory summary inferred from the user request plus recent audio/video context. Resolve vague references like this, that, here, or where I put this by using visible objects, actions, and spatial context. If the user gives an explicit duration, use it for rewind_duration_seconds but still summarize the actual saved content.'
            },
            entities: {
              type: 'array',
              minItems: 1,
              maxItems: 16,
              items: { type: 'string' },
              description:
                'Lowercase plain searchable labels inferred from the utterance and recent camera/audio context: objects, people, places, visible labels/text, surfaces, containers, and actions. Use short noun phrases without quotes, JSON, punctuation wrappers, or generic labels. Include the likely referent even when the user only says this or that. Prefer distinctive labels with attributes, colors, brands, text, spatial relations, or roles; avoid standalone generic labels such as man, person, people, activity, thing, pointing, talking, or outdoors unless paired with a specific descriptor.'
            },
            location_hint: {
              type: 'string',
              description:
                'Short physical/spatial hint inferred from the scene, such as office desk, kitchen counter, sofa, backpack, shelf, patio, parking lot, table, or room. Include it when a reliable place, surface, container, or area is visible or mentioned.'
            },
            rewind_duration_seconds: {
              type: 'integer',
              minimum: 1,
              maximum: this.clientSession.maxRewindDurationSeconds,
              description:
                'How many seconds of the phone rolling buffer should be preserved, ending at the backend save-request anchor. If the user says a duration like last 20 seconds or last minute, use that duration clamped to the client buffer. Otherwise infer a dynamic window that covers the coherent current activity or object/location moment without exceeding the available buffer.'
            }
          },
          required: ['title', 'description', 'entities', 'rewind_duration_seconds']
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
            status_text: {
              type: 'string',
              description:
                'A short present-progress sentence for the client to show while the search runs, for example "Searching your rewinds for the pen...". Keep it under 120 characters.'
            },
            limit: { type: 'integer', minimum: 1, maximum: 20 },
            time_range: {
              type: 'object',
              description:
                'Optional UTC ISO datetime range. Use this for relative date requests such as today, yesterday, this week, last week, this month, last month, or last N days/weeks/months. Resolve the semantic period in the client timezone, then emit UTC instants.',
              additionalProperties: false,
              properties: {
                started_after: { type: 'string', description: 'Inclusive lower bound as a UTC ISO datetime ending in Z.' },
                ended_before: { type: 'string', description: 'Exclusive upper bound as a UTC ISO datetime ending in Z.' }
              }
            },
            entities: {
              type: 'array',
              maxItems: 16,
              items: { type: 'string' },
              description:
                'Lowercase plain entities from the search request and likely synonyms. Use short strings only, and include these only when they narrow the database search.'
            },
            location_hint: {
              type: 'string',
              description: 'Optional physical/spatial hint when the user asks about a specific place or surface.'
            }
          },
          required: ['query', 'status_text']
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
      if (part.text) callbacks.onText(part.text);
      if (part.inlineData?.data) {
        callbacks.onAudio(part.inlineData.data, part.inlineData.mimeType ?? 'audio/pcm;rate=24000');
      }
    }
    if (message.sessionResumptionUpdate) {
      callbacks.onState('connected', {
        session_resumption: message.sessionResumptionUpdate
      });
    }
    const calls = normalizeFunctionCalls(message.toolCall?.functionCalls ?? [], new Date().toISOString());
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
      maxOutputTokens: 256,
      mediaResolution: MediaResolution.MEDIA_RESOLUTION_LOW,
      systemInstruction: systemInstruction(this.clientSession),
      tools: this.getGeminiTools(),
      realtimeInputConfig: {
        turnCoverage: TurnCoverage.TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO,
        automaticActivityDetection: {
          disabled: false,
          silenceDurationMs: 700
        }
      }
    };

    if (!usesGemini3Model(config.LIVE_MODEL_NAME)) {
      liveConfig.temperature = 0.2;
    }

    if (usesNativeAudioModel(config.LIVE_MODEL_NAME)) {
      liveConfig.inputAudioTranscription = {};
      liveConfig.outputAudioTranscription = {};
      liveConfig.thinkingConfig = { thinkingBudget: 0 };
      liveConfig.proactivity = { proactiveAudio: true };
    }

    return liveConfig;
  }
}

export type NormalizedClientSession = {
  hello: SessionHello;
  bufferDurationMs: number;
  maxRewindDurationSeconds: number;
  clientClockOffsetMs: number;
};

function normalizeFunctionCalls(calls: FunctionCall[], receivedAt: string): ToolCall[] {
  return calls
    .filter((call): call is FunctionCall & { name: SupportedToolName } => Boolean(call.name) && SUPPORTED_TOOLS.includes(call.name as SupportedToolName))
    .map((call) => ({
      id: call.id ?? crypto.randomUUID(),
      name: call.name,
      args: call.args ?? {},
      received_at: receivedAt
    }));
}

function usesNativeAudioModel(model: string): boolean {
  return model.includes('native-audio');
}

function usesGemini3Model(model: string): boolean {
  return /^gemini-3(?:[.-]|$)/.test(model);
}

function systemInstruction(clientSession: NormalizedClientSession): string {
  const maxSeconds = clientSession.maxRewindDurationSeconds;
  const bufferMs = clientSession.bufferDurationMs;
  const frameIntervalMs = clientSession.hello.buffers.rewind.frame_interval_ms;
  const maxFrames = clientSession.hello.buffers.rewind.max_frames;
  const clientContext = clientSession.hello.context;
  const currentTime = clientContext?.current_time ?? new Date().toISOString();
  const timeZone = clientContext?.time_zone ?? 'unknown';
  const utcOffset = clientContext?.utc_offset_minutes;
  return [
    '# Role',
    '- You are Rewind, a quiet real-time memory agent behind a trusted phone client.',
    '- The phone owns camera/audio rolling buffers and local media. The backend stores structured memory metadata, frame UUIDs, timestamps, location hints, and embeddings.',
    '',
    '# Client Context',
    `- Current client time: ${currentTime}.`,
    `- Client timezone: ${timeZone}${utcOffset === undefined ? '' : `, UTC offset minutes: ${utcOffset}`}.`,
    `- Rolling rewind buffer: ${bufferMs} ms, maximum requested duration: ${maxSeconds} seconds${frameIntervalMs === undefined ? '' : `, device frame interval: ${frameIntervalMs} ms`}${maxFrames === undefined ? '' : `, max stored frame refs: ${maxFrames}`}.`,
    '- Interpret relative date phrases using the client time and timezone, not server time. After resolving the user-local period, emit all datetimes as UTC ISO strings ending in Z.',
    '',
    '# Default Behavior',
    '- STAY PASSIVE unless the user explicitly asks to remember/save/capture/bookmark/log something or asks to search/find/show a previous memory.',
    '- Background audio, video, or images alone are observation context only. Do not talk just because something changed on camera.',
    '- Do not ask to store raw image/video bytes. The trusted device handles frame upload after a save request.',
    '- The backend anchors each save request to the UTC time when the Live tool call is received. Create is for the current moment only; the phone selects recent frames from the rolling buffer ending at that anchor. Do not encode timestamps, historical dates, or frame IDs in create_rewind arguments.',
    '- Privacy rule: never create a rewind from ambient conversation, vague interest, surprise, or background activity alone. Require a direct user request to preserve the moment.',
    '',
    '# Create Rewind',
    '- Call create_rewind when the user clearly asks to preserve the current or just-finished moment. This is not a historical lookup and should not save an arbitrary point in the past.',
    '- Treat direct reminder/save phrasing as save intent when it refers to the current scene or just-finished action, for example "remind me about this", "remind me about that", "save this about the pen", "remember what I just did", "save the last 20 seconds", "remind me about the last 20 seconds", or "remember the last minute of me doing this".',
    '- English save-intent examples: "remember this", "remember that", "save this", "save this moment", "capture this", "record this for later", "bookmark this", "log this", "note this", "keep this", "remember where I put this", "remember where I left X", "remember that I did X", "remind me about this", "remind me where this is", "don\'t let me forget this", "I want to remember this later", "store this memory", "mark this spot", "save where this is".',
    '- Generalize save intent across languages without relying on exact keywords, but only when the utterance is clearly a direct request to preserve/store/remember the current context.',
    '- Do NOT call create_rewind for weak or non-imperative phrases like "this is interesting", "look at this", "wow", "that was cool", "I might need this", "maybe remember", ordinary narration, or a search question. If intent is ambiguous, stay passive or give a brief clarification instead of saving.',
    `- The trusted phone reports a rolling rewind buffer of ${bufferMs} ms, so rewind_duration_seconds MUST be between 1 and ${maxSeconds}. Never request more than the available buffer; if the coherent activity appears longer, use ${maxSeconds}.`,
    '- ALWAYS include rewind_duration_seconds. Priority order: first honor an explicit user duration such as "last 20 seconds", "the last minute", "the past 30 seconds", or "the whole last 45 seconds"; otherwise infer a dynamic replay window from the observed activity duration and context.',
    '- Convert user durations to seconds. Use 20 for "last 20 seconds"; use 60 for "last minute"; clamp anything longer than the reported buffer down to the maximum available buffer. If the user says "last few seconds", choose about 5 seconds.',
    '- Duration inference guidance when no explicit duration is given: first identify the coherent thing the user is asking to preserve, then choose a window that covers that whole span including immediate setup and context. After that span is covered, avoid extra unrelated buffer. A quick static object/location memory usually needs 4-8 seconds; an object shown briefly for about 2 seconds should use about 3-5 seconds; a short discrete action should use 6-12 seconds.',
    '- For ongoing multi-step physical activities such as cooking, preparing food, building, sorting, packing, cleaning, repairing, arranging objects, or playing with/manipulating several items, use a longer window that covers the visible/audible activity leading up to the save request. If the activity has clearly been unfolding for 20-45 seconds, request about that much. If it has been ongoing for roughly a minute or longer, request the maximum available buffer.',
    '- Do not default to 8-12 seconds for an ongoing activity just because the user says "save this". The words "this" or "that" should refer to the current activity span when recent context shows a continuing action, not only to the final frame.',
    '- If uncertain, prefer a window that preserves the full object/action and immediate context while staying under the buffer max. Do not request 20+ seconds for a simple static object memory unless longer context is visibly or audibly relevant.',
    '',
    '# Duration Examples',
    `- User says "remember where I put this" while holding keys over a desk; title "Keys on desk", rewind_duration_seconds around 5, entities like ["keys", "desk"].`,
    `- User says "save this" after briefly showing a product label or receipt; title the visible item/text, use rewind_duration_seconds around 4-6, and include the visible text/brand in entities.`,
    `- User says "save this" after a short pour, handoff, placement, or button press that just happened; title the action/content and use rewind_duration_seconds around 8-12.`,
    `- User says "save this" while actively cooking, preparing food, assembling, sorting, packing, cleaning, repairing, or manipulating several items for many seconds; title the activity/content and use rewind_duration_seconds around 30-45 when that covers the visible activity.`,
    `- User says "save this" while that same coherent activity has been going on for about a minute or longer; title the activity/content and set rewind_duration_seconds to ${maxSeconds}.`,
    `- User says "save the last 90 seconds"; set rewind_duration_seconds to ${maxSeconds}, because the client buffer maximum is ${maxSeconds}, but still title the actual content, not "Last 90 seconds".`,
    '- Infer the memory from ALL RECENT CONTEXT: the user words, audio history, visible camera frames, visible text, object positions, places, surfaces, and actions.',
    '- If the user says "this", "that", "it", "here", or "where I put this", resolve the referent from the camera/video context.',
    '- entities is REQUIRED. It must be a simple array of lowercase strings. Include concrete searchable labels: objects, people, places, surfaces, containers, visible text/brands, colors, identifiers, spatial relationships, and actions. Use short noun phrases. Do not include quotes inside the strings, JSON-like structures, bullets, full sentences, or generic words like thing, stuff, object, moment, memory.',
    '- Avoid weak standalone entities such as man, person, people, activity, discussion, talking, pointing, outdoors, office, or room when a more specific label is available. Prefer distinctive phrases such as "man in white cap", "beige pen", "green wristband", "orange deck chair", "license plate w 31944 d", "office desk", or "phone on white sofa".',
    '- description must be a compact retrieval summary: what happened, what object/action matters, where it is, and the spatial relationship that would help future search. If the user gave an explicit duration, do not let the duration replace the actual memory content.',
    '- title should be short, human-readable, and content-specific. Do not title memories as "Last N seconds", "Last N seconds memory", "Last N seconds activity", "Remember this", or "Remind me about this" when the visible/audible content can be named.',
    '- location_hint should be included whenever a reliable place, surface, container, or area is visible or mentioned. Use concise hints such as office desk, white sofa, outdoor patio, parking lot, wall, kitchen counter, shelf, drawer, backpack, or table. Omit it only when no reliable physical hint is available.',
    '- Keep create_rewind arguments compact. Do not include raw transcripts, protocol details, base64, frame IDs, timestamps, dates, or unnecessary metadata.',
    '',
    '# Search Rewinds',
    '- Call search_rewinds when the user asks where something is, what happened, or asks to find/search/show a memory.',
    '- query should preserve the natural user request plus the likely referent if visible/audible context clarifies it.',
    '- status_text is REQUIRED and should be a concise present-progress sentence that the client can display immediately while the backend searches, such as "Searching your rewinds for the pen...".',
    '- For date phrases such as today, yesterday, this morning, this week, last week, this month, last month, or last N days/weeks/months, set time_range with UTC ISO datetimes covering the matching client-local period.',
    '- Weeks start on Monday. Use started_after as the start of the local period and ended_before as the exclusive end of the local period, converted to UTC ISO datetime with a trailing Z.',
    '- Add entities, time_range, or location_hint only when they narrow the search.',
    '- Search results are returned directly to the phone client by the backend. Do not ask for a second show/display action.',
    '',
    '# Tool Discipline',
    '- Use only the two available tools.',
    '- Do not invent fields. Match the JSON schema exactly.',
    '- Prefer one correct tool call over conversational filler. Keep spoken/text responses minimal.'
  ].join('\n');
}
