export type JsonObject = Record<string, unknown>;

export type AgentSession = {
  id: string;
  user_id: string;
  device_id: string;
  status: string;
  started_at: string;
  ended_at?: string | null;
  model?: string | null;
  metadata: JsonObject;
};

export type RewindEvent = {
  id: string;
  user_id: string;
  device_id: string;
  status: 'pending' | 'committed' | 'failed';
  title: string;
  description: string;
  reason?: string | null;
  entities: string[];
  location_hint?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  started_at?: string | null;
  ended_at?: string | null;
  local_asset_id?: string | null;
  thumbnail_frame_uuid?: string | null;
  embedding?: number[] | string | null;
  metadata: JsonObject;
  created_at: string;
  updated_at: string;
};

export type RewindFrame = {
  id: string;
  rewind_event_id: string;
  user_id: string;
  device_id: string;
  device_frame_uuid: string;
  local_asset_id?: string | null;
  order_index: number;
  captured_at?: string | null;
  offset_ms?: number | null;
  embedding?: number[] | string | null;
  metadata: JsonObject;
  created_at: string;
};

export type RewindSearchContext = {
  time_range?: {
    started_after?: string;
    ended_before?: string;
  };
  entities?: string[];
  location_hint?: string;
  status?: string[];
  database_filters?: JsonObject;
};

export type RewindSearchResult = RewindEvent & {
  similarity?: number | null;
  event_similarity?: number | null;
  frame_similarity?: number | null;
  text_rank?: number | null;
  frames?: RewindFrame[];
};

export type ToolCall = {
  id: string;
  name: 'create_rewind' | 'search_rewinds';
  args: JsonObject;
};

export type SessionHello = {
  type: 'session.hello';
  protocol_version: 1;
  timestamp?: string;
  device?: {
    id?: string;
    kind?: string;
    label?: string;
  };
  buffers: {
    rewind: {
      duration_ms: number;
      frame_interval_ms?: number;
      max_frames?: number;
    };
    realtime?: {
      image_interval_ms?: number;
      audio_chunk_ms?: number;
      audio_sample_rate_hz?: number;
    };
  };
  capabilities?: JsonObject;
};

export type RewindCommitRequest = {
  event_id: string;
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
    image_base64?: string;
    mime_type?: string;
    embedding?: number[];
    metadata?: JsonObject;
  }>;
  metadata?: JsonObject;
};

export type ClientMessage =
  | SessionHello
  | { type: 'user.text'; text: string }
  | { type: 'user.media'; modality: 'audio' | 'video' | 'image'; mime_type: string; data: string; seq?: number; timestamp?: string }
  | { type: 'user.media_end'; modality: 'audio' | 'video' | 'image' };

export type RewindFrameRef = {
  frame_id?: string;
  device_frame_uuid: string;
  captured_at?: string | null;
  offset_ms?: number | null;
};

export type RewindProtocolResult = {
  event_id: string;
  title: string;
  description: string;
  entities: string[];
  location_hint?: string | null;
  started_at?: string | null;
  ended_at?: string | null;
  score: {
    similarity?: number | null;
    event_similarity?: number | null;
    frame_similarity?: number | null;
    text_rank?: number | null;
  };
  frame_refs: RewindFrameRef[];
};

export type RewindSaveRequest = {
  request_id: string;
  event_id: string;
  upload_url: string;
  title: string;
  description: string;
  rewind_duration_seconds: number;
  include_frame_images: boolean;
  frame_embedding_mode: 'text_only' | 'text_and_image' | string;
};

export type RewindSearchResults = {
  query: string;
  filters?: {
    time_range?: RewindSearchContext['time_range'];
    entities?: string[];
    location_hint?: string;
  };
  results: RewindProtocolResult[];
};

export type ServerMessage =
  | { type: 'session.ready'; session_id: string; user_id: string; device_id: string; max_rewind_duration_seconds?: number }
  | { type: 'agent.message'; text: string; payload?: JsonObject }
  | { type: 'agent.live_state'; state: 'connecting' | 'transport_open' | 'connected' | 'closed' | 'error'; payload?: JsonObject }
  | { type: 'agent.media'; modality: 'audio' | 'text'; mime_type?: string; data?: string; text?: string; seq?: number }
  | ({ type: 'rewind.save_request' } & RewindSaveRequest)
  | ({ type: 'rewind.search_results' } & RewindSearchResults)
  | { type: 'error'; error: string; details?: unknown };
