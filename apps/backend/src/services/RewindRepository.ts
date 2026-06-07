import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { config } from '../config.js';
import type {
  AgentSession,
  JsonObject,
  RewindEvent,
  RewindFrame,
  RewindSearchContext,
  RewindSearchResult
} from '../types.js';
import { vectorLiteral } from '../utils/vector.js';

export type CreatePendingRewindInput = {
  user_id: string;
  device_id: string;
  title: string;
  description: string;
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
  started_at?: string;
  ended_at?: string;
  location?: { latitude?: number; longitude?: number; location_hint?: string };
  embedding?: number[];
  frames: Array<{
    device_frame_uuid: string;
    captured_at?: string;
    offset_ms?: number;
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
  createPendingRewind(input: CreatePendingRewindInput): Promise<RewindEvent>;
  commitRewind(input: CommitRewindInput): Promise<{ event: RewindEvent; frames: RewindFrame[] }>;
  searchRewinds(input: {
    user_id: string;
    query?: string;
    query_embedding?: number[];
    context?: RewindSearchContext;
    limit?: number;
  }): Promise<RewindSearchResult[]>;
  getRewindEvent(input: { user_id: string; event_id: string }): Promise<RewindEvent | null>;
  getRewindFrames(input: { user_id: string; event_ids: string[] }): Promise<RewindFrame[]>;
  getRewindDetails(input: { user_id: string; event_id: string }): Promise<{ event: RewindEvent; frames: RewindFrame[] } | null>;
  listRewinds(userId: string, limit?: number): Promise<RewindSearchResult[]>;
}

function now(): string {
  return new Date().toISOString();
}

function uuid(): string {
  return crypto.randomUUID();
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
    const eventUpdate: Record<string, unknown> = {
      status: 'committed',
      started_at: input.started_at ?? null,
      ended_at: input.ended_at ?? null,
      latitude: input.location?.latitude ?? null,
      longitude: input.location?.longitude ?? null,
      metadata: input.metadata ?? {}
    };
    if (Object.prototype.hasOwnProperty.call(input.location ?? {}, 'location_hint')) {
      eventUpdate.location_hint = input.location?.location_hint ?? null;
    }
    if (input.embedding) {
      eventUpdate.embedding = vectorLiteral(input.embedding);
    }

    const { data: event, error: updateError } = await this.client
      .from('rewind_events')
      .update(eventUpdate)
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
      order_index: index,
      captured_at: frame.captured_at ?? null,
      offset_ms: frame.offset_ms ?? null,
      embedding: vectorLiteral(frame.embedding),
      metadata: frame.metadata ?? {}
    }));

    if (frameRows.length) {
      const { data: frames, error } = await this.client
        .from('rewind_frames')
        .upsert(frameRows, { onConflict: 'rewind_event_id,device_frame_uuid' })
        .select('*');
      if (error) throw error;
      return {
        event,
        frames: (frames ?? []).sort((left, right) => left.order_index - right.order_index)
      };
    }

    return { event, frames: [] };
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

  async getRewindEvent(input: { user_id: string; event_id: string }): Promise<RewindEvent | null> {
    const { data: event, error } = await this.client
      .from('rewind_events')
      .select('*')
      .eq('id', input.event_id)
      .eq('user_id', input.user_id)
      .single();
    if (error) return null;
    return event;
  }

  async getRewindFrames(input: { user_id: string; event_ids: string[] }): Promise<RewindFrame[]> {
    if (!input.event_ids.length) return [];
    const { data, error } = await this.client
      .from('rewind_frames')
      .select('*')
      .eq('user_id', input.user_id)
      .in('rewind_event_id', input.event_ids)
      .order('rewind_event_id', { ascending: true })
      .order('order_index', { ascending: true });
    if (error) throw error;
    return data ?? [];
  }

  async getRewindDetails(input: { user_id: string; event_id: string }): Promise<{ event: RewindEvent; frames: RewindFrame[] } | null> {
    const event = await this.getRewindEvent(input);
    if (!event) return null;

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
  return new SupabaseRewindRepository();
}
