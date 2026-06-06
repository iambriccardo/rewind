import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { config } from '../config.js';
import type {
  AgentSession,
  DeviceCommand,
  JsonObject,
  RewindEvent,
  RewindFrame,
  RewindSearchContext,
  RewindSearchResult
} from '../types.js';
import { cosineSimilarity, vectorLiteral } from '../utils/vector.js';

export type CreatePendingRewindInput = {
  user_id: string;
  device_id: string;
  title: string;
  description: string;
  reason?: string;
  entities?: string[];
  location_hint?: string;
  started_at?: string;
  ended_at?: string;
  embedding?: number[];
  metadata?: JsonObject;
};

export type CommitRewindInput = {
  event_id: string;
  user_id: string;
  device_id: string;
  local_asset_id?: string;
  thumbnail_frame_uuid?: string;
  started_at?: string;
  ended_at?: string;
  location?: { latitude?: number; longitude?: number; location_hint?: string };
	frames: Array<{
	    device_frame_uuid: string;
	    local_asset_id?: string;
	    captured_at?: string;
	    offset_ms?: number;
	    caption?: string;
	    embedding?: number[];
	    metadata?: JsonObject;
	  }>;
  metadata?: JsonObject;
};

export interface RewindRepository {
  createSession(input: { user_id: string; device_id: string; model?: string; metadata?: JsonObject }): Promise<AgentSession>;
  endSession(sessionId: string): Promise<void>;
  logAgentEvent(input: { session_id: string; user_id: string; type: string; payload: JsonObject }): Promise<void>;
  logToolCall(input: {
    session_id: string;
    user_id: string;
    tool_name: string;
    tool_call_id?: string;
    arguments: JsonObject;
    result?: JsonObject;
    status: string;
    error?: string;
    latency_ms?: number;
  }): Promise<void>;
  createDeviceCommand(input: {
    session_id: string;
    user_id: string;
    device_id: string;
    command_type: string;
    payload: JsonObject;
  }): Promise<DeviceCommand>;
  updateDeviceCommandAck(input: { command_id: string; status: DeviceCommand['status']; ack_payload?: JsonObject; error?: string }): Promise<void>;
  createPendingRewind(input: CreatePendingRewindInput): Promise<RewindEvent>;
  commitRewind(input: CommitRewindInput): Promise<{ event: RewindEvent; frames: RewindFrame[] }>;
  searchRewinds(input: {
    user_id: string;
    query?: string;
    query_embedding?: number[];
    context?: RewindSearchContext;
    limit?: number;
  }): Promise<RewindSearchResult[]>;
  getRewindDetails(input: { user_id: string; event_id: string }): Promise<{ event: RewindEvent; frames: RewindFrame[] } | null>;
  listRewinds(userId: string, limit?: number): Promise<RewindSearchResult[]>;
}

type Store = {
  sessions: AgentSession[];
  events: JsonObject[];
  toolCalls: JsonObject[];
  commands: DeviceCommand[];
  rewindEvents: RewindEvent[];
  rewindFrames: RewindFrame[];
};

const emptyStore = (): Store => ({
  sessions: [],
  events: [],
  toolCalls: [],
  commands: [],
  rewindEvents: [],
  rewindFrames: []
});

function now(): string {
  return new Date().toISOString();
}

function uuid(): string {
  return crypto.randomUUID();
}

export class LocalJsonRewindRepository implements RewindRepository {
  constructor(private readonly path = config.LOCAL_DATA_PATH) {}

  private async read(): Promise<Store> {
    try {
      const raw = await readFile(this.path, 'utf8');
      return { ...emptyStore(), ...JSON.parse(raw) };
    } catch {
      return emptyStore();
    }
  }

  private async write(store: Store): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    await writeFile(this.path, JSON.stringify(store, null, 2));
  }

  async createSession(input: { user_id: string; device_id: string; model?: string; metadata?: JsonObject }): Promise<AgentSession> {
    const store = await this.read();
    const session: AgentSession = {
      id: uuid(),
      user_id: input.user_id,
      device_id: input.device_id,
      status: 'active',
      started_at: now(),
      ended_at: null,
      model: input.model ?? null,
      metadata: input.metadata ?? {}
    };
    store.sessions.push(session);
    await this.write(store);
    return session;
  }

  async endSession(sessionId: string): Promise<void> {
    const store = await this.read();
    const session = store.sessions.find((item) => item.id === sessionId);
    if (session) {
      session.status = 'ended';
      session.ended_at = now();
    }
    await this.write(store);
  }

  async logAgentEvent(input: { session_id: string; user_id: string; type: string; payload: JsonObject }): Promise<void> {
    const store = await this.read();
    store.events.push({ id: uuid(), created_at: now(), ...input });
    await this.write(store);
  }

  async logToolCall(input: {
    session_id: string;
    user_id: string;
    tool_name: string;
    tool_call_id?: string;
    arguments: JsonObject;
    result?: JsonObject;
    status: string;
    error?: string;
    latency_ms?: number;
  }): Promise<void> {
    const store = await this.read();
    store.toolCalls.push({ id: uuid(), created_at: now(), ...input });
    await this.write(store);
  }

  async createDeviceCommand(input: {
    session_id: string;
    user_id: string;
    device_id: string;
    command_type: string;
    payload: JsonObject;
  }): Promise<DeviceCommand> {
    const store = await this.read();
    const command: DeviceCommand = {
      id: uuid(),
      status: 'pending',
      ack_payload: null,
      error: null,
      created_at: now(),
      acknowledged_at: null,
      ...input
    };
    store.commands.push(command);
    await this.write(store);
    return command;
  }

  async updateDeviceCommandAck(input: { command_id: string; status: DeviceCommand['status']; ack_payload?: JsonObject; error?: string }): Promise<void> {
    const store = await this.read();
    const command = store.commands.find((item) => item.id === input.command_id);
    if (command) {
      command.status = input.status;
      command.ack_payload = input.ack_payload ?? null;
      command.error = input.error ?? null;
      command.acknowledged_at = now();
    }
    await this.write(store);
  }

  async createPendingRewind(input: CreatePendingRewindInput): Promise<RewindEvent> {
    const store = await this.read();
    const event: RewindEvent = {
      id: uuid(),
      user_id: input.user_id,
      device_id: input.device_id,
      status: 'pending',
      title: input.title,
      description: input.description,
      reason: input.reason ?? null,
      entities: input.entities ?? [],
      location_hint: input.location_hint ?? null,
      latitude: null,
      longitude: null,
      started_at: input.started_at ?? null,
      ended_at: input.ended_at ?? null,
      local_asset_id: null,
      thumbnail_frame_uuid: null,
      embedding: input.embedding ?? null,
      metadata: input.metadata ?? {},
      created_at: now(),
      updated_at: now()
    };
    store.rewindEvents.push(event);
    await this.write(store);
    return event;
  }

  async commitRewind(input: CommitRewindInput): Promise<{ event: RewindEvent; frames: RewindFrame[] }> {
    const store = await this.read();
    const event = store.rewindEvents.find(
      (item) => item.id === input.event_id && item.user_id === input.user_id && item.device_id === input.device_id
    );
    if (!event) throw new Error(`Rewind event not found: ${input.event_id}`);

    event.status = 'committed';
    event.local_asset_id = input.local_asset_id ?? event.local_asset_id ?? null;
    event.thumbnail_frame_uuid = input.thumbnail_frame_uuid ?? event.thumbnail_frame_uuid ?? null;
    event.started_at = input.started_at ?? event.started_at ?? null;
    event.ended_at = input.ended_at ?? event.ended_at ?? null;
    event.latitude = input.location?.latitude ?? event.latitude ?? null;
    event.longitude = input.location?.longitude ?? event.longitude ?? null;
    event.location_hint = input.location?.location_hint ?? event.location_hint ?? null;
    event.metadata = { ...event.metadata, ...(input.metadata ?? {}) };
    event.updated_at = now();

    const existing = new Set(store.rewindFrames.filter((frame) => frame.rewind_event_id === event.id).map((frame) => frame.device_frame_uuid));
    const frames = input.frames
      .filter((frame) => !existing.has(frame.device_frame_uuid))
      .map((frame, index): RewindFrame => ({
        id: uuid(),
        rewind_event_id: event.id,
        user_id: input.user_id,
        device_id: input.device_id,
        device_frame_uuid: frame.device_frame_uuid,
        local_asset_id: frame.local_asset_id ?? input.local_asset_id ?? null,
        order_index: index,
        captured_at: frame.captured_at ?? null,
	        offset_ms: frame.offset_ms ?? null,
	        caption: frame.caption ?? null,
	        embedding: frame.embedding ?? null,
	        metadata: frame.metadata ?? {},
	        created_at: now()
      }));
    store.rewindFrames.push(...frames);
    await this.write(store);
    return { event, frames: store.rewindFrames.filter((frame) => frame.rewind_event_id === event.id).sort((a, b) => a.order_index - b.order_index) };
  }

  async searchRewinds(input: {
    user_id: string;
    query?: string;
    query_embedding?: number[];
    context?: RewindSearchContext;
    limit?: number;
  }): Promise<RewindSearchResult[]> {
    const store = await this.read();
    const query = input.query?.toLowerCase().trim();
    const entities = input.context?.entities?.map((entity) => entity.toLowerCase());
    const startedAfter = input.context?.time_range?.started_after ? Date.parse(input.context.time_range.started_after) : undefined;
    const endedBefore = input.context?.time_range?.ended_before ? Date.parse(input.context.time_range.ended_before) : undefined;
    const rows = store.rewindEvents
      .filter((event) => event.user_id === input.user_id)
      .filter((event) => !entities?.length || event.entities.some((entity) => entities.includes(entity.toLowerCase())))
      .filter((event) => !startedAfter || Date.parse(event.ended_at ?? event.started_at ?? event.created_at) >= startedAfter)
      .filter((event) => !endedBefore || Date.parse(event.started_at ?? event.ended_at ?? event.created_at) <= endedBefore)
      .map((event) => {
        const haystack = [event.title, event.description, event.location_hint, ...event.entities].join(' ').toLowerCase();
        const text_rank = query && haystack.includes(query) ? 1 : query ? tokenOverlap(query, haystack) : 0;
        const event_similarity = cosineSimilarity(event.embedding, input.query_embedding);
        const frames = store.rewindFrames.filter((frame) => frame.rewind_event_id === event.id).sort((a, b) => a.order_index - b.order_index);
        const frame_similarity =
          frames.reduce<number | null>((best, frame) => {
            const score = cosineSimilarity(frame.embedding, input.query_embedding);
            if (score === null) return best;
            return best === null ? score : Math.max(best, score);
          }, null) ?? null;
        const similarity = Math.max(event_similarity ?? -1, frame_similarity ?? -1);
        return {
          ...event,
          similarity: similarity < 0 ? null : similarity,
          event_similarity,
          frame_similarity,
          text_rank,
          frames
        };
      })
      .filter((event) => !query || event.text_rank > 0 || event.similarity !== null)
      .sort((a, b) => (b.similarity ?? 0) - (a.similarity ?? 0) || (b.text_rank ?? 0) - (a.text_rank ?? 0) || Date.parse(b.created_at) - Date.parse(a.created_at));

    return rows.slice(0, input.limit ?? 10);
  }

  async getRewindDetails(input: { user_id: string; event_id: string }): Promise<{ event: RewindEvent; frames: RewindFrame[] } | null> {
    const store = await this.read();
    const event = store.rewindEvents.find((item) => item.id === input.event_id && item.user_id === input.user_id);
    if (!event) return null;
    return {
      event,
      frames: store.rewindFrames.filter((frame) => frame.rewind_event_id === event.id).sort((a, b) => a.order_index - b.order_index)
    };
  }

  async listRewinds(userId: string, limit = 50): Promise<RewindSearchResult[]> {
    const store = await this.read();
    return store.rewindEvents
      .filter((event) => event.user_id === userId)
      .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))
      .slice(0, limit)
      .map((event) => ({
        ...event,
        frames: store.rewindFrames.filter((frame) => frame.rewind_event_id === event.id).sort((a, b) => a.order_index - b.order_index)
      }));
  }
}

function tokenOverlap(query: string, haystack: string): number {
  const tokens = query.split(/\s+/).filter((token) => token.length > 2);
  if (!tokens.length) return 0;
  const hits = tokens.filter((token) => haystack.includes(token)).length;
  return hits / tokens.length;
}

export class SupabaseRewindRepository implements RewindRepository {
  private readonly client: SupabaseClient;

  constructor() {
    if (!config.SUPABASE_URL || !config.SUPABASE_SERVICE_ROLE_KEY) {
      throw new Error('Supabase repository requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.');
    }
    this.client = createClient(config.SUPABASE_URL, config.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false }
    });
  }

  async createSession(input: { user_id: string; device_id: string; model?: string; metadata?: JsonObject }): Promise<AgentSession> {
    return {
      id: uuid(),
      user_id: input.user_id,
      device_id: input.device_id,
      status: 'active',
      started_at: now(),
      ended_at: null,
      model: input.model ?? null,
      metadata: input.metadata ?? {}
    };
  }

  async endSession(_sessionId: string): Promise<void> {
    return;
  }

  async logAgentEvent(_input: { session_id: string; user_id: string; type: string; payload: JsonObject }): Promise<void> {
    return;
  }

  async logToolCall(input: {
    session_id: string;
    user_id: string;
    tool_name: string;
    tool_call_id?: string;
    arguments: JsonObject;
    result?: JsonObject;
    status: string;
    error?: string;
    latency_ms?: number;
  }): Promise<void> {
    return;
  }

  async createDeviceCommand(input: {
    session_id: string;
    user_id: string;
    device_id: string;
    command_type: string;
    payload: JsonObject;
  }): Promise<DeviceCommand> {
    return {
      id: uuid(),
      session_id: input.session_id,
      user_id: input.user_id,
      device_id: input.device_id,
      command_type: input.command_type,
      payload: input.payload,
      status: 'pending',
      ack_payload: null,
      error: null,
      created_at: now(),
      acknowledged_at: null
    };
  }

  async updateDeviceCommandAck(_input: { command_id: string; status: DeviceCommand['status']; ack_payload?: JsonObject; error?: string }): Promise<void> {
    return;
  }

  async createPendingRewind(input: CreatePendingRewindInput): Promise<RewindEvent> {
    const { data, error } = await this.client
      .from('rewind_events')
      .insert({
        ...input,
        embedding: vectorLiteral(input.embedding)
      })
      .select('*')
      .single();
    if (error) throw error;
    return data;
  }

  async commitRewind(input: CommitRewindInput): Promise<{ event: RewindEvent; frames: RewindFrame[] }> {
    const { data: event, error: updateError } = await this.client
      .from('rewind_events')
      .update({
        status: 'committed',
        local_asset_id: input.local_asset_id ?? null,
        thumbnail_frame_uuid: input.thumbnail_frame_uuid ?? null,
        started_at: input.started_at ?? null,
        ended_at: input.ended_at ?? null,
        latitude: input.location?.latitude ?? null,
        longitude: input.location?.longitude ?? null,
        location_hint: input.location?.location_hint ?? null,
        metadata: input.metadata ?? {}
      })
      .eq('id', input.event_id)
      .eq('user_id', input.user_id)
      .eq('device_id', input.device_id)
      .select('*')
      .single();
    if (updateError) throw updateError;

    const frameRows = input.frames.map((frame, index) => ({
      rewind_event_id: input.event_id,
      user_id: input.user_id,
      device_id: input.device_id,
      device_frame_uuid: frame.device_frame_uuid,
      local_asset_id: frame.local_asset_id ?? input.local_asset_id ?? null,
      order_index: index,
      captured_at: frame.captured_at ?? null,
      offset_ms: frame.offset_ms ?? null,
      caption: frame.caption ?? null,
	      embedding: vectorLiteral(frame.embedding),
	      metadata: frame.metadata ?? {}
	    }));

    if (frameRows.length) {
      const { error } = await this.client.from('rewind_frames').upsert(frameRows, { onConflict: 'rewind_event_id,device_frame_uuid' });
      if (error) throw error;
    }

    const details = await this.getRewindDetails({ user_id: input.user_id, event_id: input.event_id });
    return details ?? { event, frames: [] };
  }

  async searchRewinds(input: {
    user_id: string;
    query?: string;
    query_embedding?: number[];
    context?: RewindSearchContext;
    limit?: number;
  }): Promise<RewindSearchResult[]> {
    const { data, error } = await this.client.rpc('match_rewind_events', {
      p_user_id: input.user_id,
      p_query_text: input.query ?? null,
      p_query_embedding: vectorLiteral(input.query_embedding),
      p_entities: input.context?.entities ?? null,
      p_location_hint: input.context?.location_hint ?? null,
      p_statuses: input.context?.status ?? null,
      p_started_after: input.context?.time_range?.started_after ?? null,
      p_ended_before: input.context?.time_range?.ended_before ?? null,
      p_limit: input.limit ?? 10
    });
    if (error) throw error;
    return (data ?? []) as RewindSearchResult[];
  }

  async getRewindDetails(input: { user_id: string; event_id: string }): Promise<{ event: RewindEvent; frames: RewindFrame[] } | null> {
    const { data: event, error } = await this.client
      .from('rewind_events')
      .select('*')
      .eq('id', input.event_id)
      .eq('user_id', input.user_id)
      .single();
    if (error) return null;

    const { data: frames, error: frameError } = await this.client
      .from('rewind_frames')
      .select('*')
      .eq('rewind_event_id', input.event_id)
      .order('order_index', { ascending: true });
    if (frameError) throw frameError;
    return { event, frames: frames ?? [] };
  }

  async listRewinds(userId: string, limit = 50): Promise<RewindSearchResult[]> {
    const { data, error } = await this.client
      .from('rewind_events')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(limit);
    if (error) throw error;
    return data ?? [];
  }
}

export function createRepository(): RewindRepository {
  return config.repositoryMode === 'supabase' ? new SupabaseRewindRepository() : new LocalJsonRewindRepository();
}
