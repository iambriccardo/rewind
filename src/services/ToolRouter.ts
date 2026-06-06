import { z } from 'zod';
import { config } from '../config.js';
import type { JsonObject, RewindFrame, RewindProtocolResult, RewindSearchResults, RewindSaveRequest, ToolCall } from '../types.js';
import { EmbeddingService } from './EmbeddingService.js';
import type { RewindRepository } from './RewindRepository.js';
import { SupervisionLogger } from './SupervisionLogger.js';

const SearchContextSchema = z
  .object({
    time_range: z
      .object({
        started_after: z.string().datetime().optional(),
        ended_before: z.string().datetime().optional()
      })
      .optional(),
    entities: z.array(z.string()).optional(),
    location_hint: z.string().optional(),
    status: z.array(z.string()).optional(),
    database_filters: z.record(z.string(), z.unknown()).optional()
  })
  .optional();

const TimeRangeSchema = z
  .object({
    started_after: z.string().datetime().optional(),
    ended_before: z.string().datetime().optional()
  })
  .optional();

const CreateRewindSchema = z.object({
  title: z.string().min(1).max(160),
  description: z.string().min(1).max(4000),
  entities: z.array(z.string()).default([]),
  location_hint: z.string().optional(),
  rewind_duration_seconds: z.number().int().positive().max(60).optional(),
  capture_window_ms: z.number().int().positive().max(60_000).optional()
});

const SearchRewindsSchema = z.object({
  query: z.string().min(1).max(1000),
  limit: z.number().int().positive().max(20).default(10),
  time_range: TimeRangeSchema,
  entities: z.array(z.string()).optional(),
  location_hint: z.string().optional(),
  context: SearchContextSchema
});

export class ToolRouter {
  constructor(
    private readonly repository: RewindRepository,
    private readonly embeddings: EmbeddingService,
    private readonly logger: SupervisionLogger
  ) {}

  async route(input: { session_id: string; user_id: string; device_id: string; toolCall: ToolCall }): Promise<JsonObject> {
    const started = Date.now();
    try {
      const result = await this.execute(input);
      await this.logger.tool({
        session_id: input.session_id,
        user_id: input.user_id,
        tool_name: input.toolCall.name,
        tool_call_id: input.toolCall.id,
        arguments: input.toolCall.args,
        result,
        status: 'succeeded',
        latency_ms: Date.now() - started
      });
      return result;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await this.logger.tool({
        session_id: input.session_id,
        user_id: input.user_id,
        tool_name: input.toolCall.name,
        tool_call_id: input.toolCall.id,
        arguments: input.toolCall.args,
        status: 'failed',
        error: message,
        latency_ms: Date.now() - started
      });
      throw error;
    }
  }

  private async execute(input: { session_id: string; user_id: string; device_id: string; toolCall: ToolCall }): Promise<JsonObject> {
    switch (input.toolCall.name) {
      case 'create_rewind':
        return this.createRewind(input);
      case 'search_rewinds':
        return this.searchRewinds(input);
      default:
        throw new Error(`Unknown tool: ${(input.toolCall as ToolCall).name}`);
    }
  }

  async search(input: { user_id: string; args: JsonObject }): Promise<RewindSearchResults> {
    return this.buildSearchResults(input.user_id, input.args);
  }

  private async createRewind(input: { session_id: string; user_id: string; device_id: string; toolCall: ToolCall }): Promise<JsonObject> {
    const args = CreateRewindSchema.parse(input.toolCall.args);
    const rewindDurationSeconds = args.rewind_duration_seconds ?? Math.ceil((args.capture_window_ms ?? 6000) / 1000);
    const embeddingText = this.embeddings.buildEventEmbeddingText({
      title: args.title,
      description: args.description,
      entities: args.entities,
      location_hint: args.location_hint
    });
    const embedding = await this.embeddings.embedDocument(embeddingText);
    const event = await this.repository.createPendingRewind({
      user_id: input.user_id,
      device_id: input.device_id,
      title: args.title,
      description: args.description,
      reason: undefined,
      entities: args.entities,
      location_hint: args.location_hint,
      embedding,
      metadata: {
        rewind_duration_seconds: rewindDurationSeconds
      }
    });

    const saveRequest: RewindSaveRequest = {
      request_id: input.toolCall.id,
      event_id: event.id,
      upload_url: `/v1/rewinds/${event.id}/commit`,
      title: event.title,
      description: event.description,
      rewind_duration_seconds: rewindDurationSeconds,
      frame_embedding_mode: config.EMBEDDING_MODE,
      include_frame_images: config.EMBEDDING_MODE === 'text_and_image'
    };
    return {
      event: compactEvent(event, rewindDurationSeconds),
      save_request: saveRequest
    };
  }

  private async searchRewinds(input: { session_id: string; user_id: string; device_id: string; toolCall: ToolCall }): Promise<JsonObject> {
    return this.buildSearchResults(input.user_id, input.toolCall.args) as unknown as JsonObject;
  }

  private async buildSearchResults(userId: string, rawArgs: JsonObject): Promise<RewindSearchResults> {
    const args = SearchRewindsSchema.parse(rawArgs);
    const queryEmbedding = await this.embeddings.embedQuery(args.query);
    const results = await this.repository.searchRewinds({
      user_id: userId,
      query: args.query,
      query_embedding: queryEmbedding,
      context: {
        ...(args.context ?? {}),
        time_range: args.time_range ?? args.context?.time_range,
        entities: args.entities ?? args.context?.entities,
        location_hint: args.location_hint ?? args.context?.location_hint
      },
      limit: args.limit
    });
    const protocolResults = await Promise.all(
      results.map(async (result): Promise<RewindProtocolResult> => {
        const details = await this.repository.getRewindDetails({ user_id: userId, event_id: result.id });
        const frames = result.frames?.length ? result.frames : details?.frames ?? [];
        return {
          event_id: result.id,
          title: result.title,
          description: result.description,
          entities: result.entities,
          location_hint: result.location_hint,
          started_at: result.started_at,
          ended_at: result.ended_at,
          score: {
            similarity: result.similarity,
            event_similarity: result.event_similarity,
            frame_similarity: result.frame_similarity,
            text_rank: result.text_rank
          },
          frame_refs: frames.map(frameRef)
        };
      })
    );

    const searchResults: RewindSearchResults = {
      query: args.query,
      filters: {
        time_range: args.time_range ?? args.context?.time_range,
        entities: args.entities ?? args.context?.entities,
        location_hint: args.location_hint ?? args.context?.location_hint
      },
      results: protocolResults
    };
    return searchResults;
  }
}

function compactEvent(event: { id: string; status: string; title: string; description: string; entities: string[]; location_hint?: string | null }, rewindDurationSeconds?: number) {
  return {
    id: event.id,
    status: event.status,
    title: event.title,
    description: event.description,
    entities: event.entities,
    location_hint: event.location_hint,
    rewind_duration_seconds: rewindDurationSeconds
  };
}

function frameRef(frame: RewindFrame) {
  return {
    frame_id: frame.id,
    device_frame_uuid: frame.device_frame_uuid,
    captured_at: frame.captured_at,
    offset_ms: frame.offset_ms
  };
}
