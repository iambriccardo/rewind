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
  caption?: string | null;
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
  name: 'create_rewind' | 'search_rewinds' | 'show_rewind';
  args: JsonObject;
};

export type DeviceCommand = {
  id: string;
  session_id: string;
  user_id: string;
  device_id: string;
  command_type: 'device.capture_rewind' | 'device.show_rewind' | string;
  payload: JsonObject;
  status: 'pending' | 'sent' | 'acknowledged' | 'failed' | 'timed_out';
  ack_payload?: JsonObject | null;
  error?: string | null;
  created_at: string;
  acknowledged_at?: string | null;
};

export type ClientMessage =
  | { type: 'user.text'; text: string }
  | { type: 'user.turn'; state: 'start' | 'end' }
  | { type: 'user.media'; modality: 'audio' | 'video' | 'image'; mime_type: string; data: string; seq?: number; timestamp?: string }
  | { type: 'user.media_end'; modality: 'audio' | 'video' | 'image' }
  | { type: 'device.command_ack'; command_id: string; status: 'ok' | 'error'; payload?: JsonObject; error?: string }
  | { type: 'device.frame_observation'; frame_uuid: string; captured_at: string; caption?: string; metadata?: JsonObject }
  | {
      type: 'rewind.commit';
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
        caption?: string;
        image_base64?: string;
        mime_type?: string;
        embedding?: number[];
        metadata?: JsonObject;
      }>;
      metadata?: JsonObject;
    };

export type ServerMessage =
  | { type: 'session.ready'; session_id: string; user_id: string; device_id: string }
  | { type: 'agent.message'; text: string; payload?: JsonObject }
  | { type: 'agent.live_state'; state: 'connecting' | 'transport_open' | 'connected' | 'closed' | 'error'; payload?: JsonObject }
  | { type: 'agent.media'; modality: 'audio' | 'text'; mime_type?: string; data?: string; text?: string; seq?: number }
  | { type: 'agent.tool_call'; tool_call: ToolCall }
  | { type: 'agent.tool_result'; tool_call_id: string; tool_name: string; result: JsonObject }
  | { type: 'device.command'; command: DeviceCommand }
  | { type: 'rewind.committed'; event: RewindEvent; frames: RewindFrame[] }
  | { type: 'search.results'; results: RewindSearchResult[] }
  | { type: 'error'; error: string; details?: unknown };
