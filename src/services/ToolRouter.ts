import { z } from 'zod';
import { config } from '../config.js';
import type { JsonObject, RewindSearchContext, ToolCall } from '../types.js';
import { DeviceCommandBus } from './DeviceCommandBus.js';
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

const ShowRewindSchema = z.object({
  event_id: z.uuid(),
  answer_text: z.string().max(2000).optional()
});

export class ToolRouter {
  constructor(
    private readonly repository: RewindRepository,
    private readonly embeddings: EmbeddingService,
    private readonly deviceBus: DeviceCommandBus,
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
      case 'show_rewind':
        return this.showRewind(input);
      default:
        throw new Error(`Unknown tool: ${(input.toolCall as ToolCall).name}`);
    }
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

    const { command } = await this.deviceBus.send({
      session_id: input.session_id,
      user_id: input.user_id,
      device_id: input.device_id,
      command_type: 'device.capture_rewind',
      waitForAck: false,
      payload: {
        event_id: event.id,
        rewind_duration_seconds: rewindDurationSeconds,
        title: event.title,
        frame_embedding_mode: config.EMBEDDING_MODE,
        include_frame_images: config.EMBEDDING_MODE === 'text_and_image'
      }
    });

    return {
      event: compactEvent(event, rewindDurationSeconds),
      device_command: compactCommand(command)
    };
  }

  private async searchRewinds(input: { session_id: string; user_id: string; device_id: string; toolCall: ToolCall }): Promise<JsonObject> {
    const args = SearchRewindsSchema.parse(input.toolCall.args);
    const queryEmbedding = await this.embeddings.embedQuery(args.query);
    const results = await this.repository.searchRewinds({
      user_id: input.user_id,
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
    return {
      query: args.query,
      filters: {
        time_range: args.time_range ?? args.context?.time_range,
        entities: args.entities ?? args.context?.entities,
        location_hint: args.location_hint ?? args.context?.location_hint
      },
      results: results.map((result) => ({
        id: result.id,
        title: result.title,
        description: result.description,
        entities: result.entities,
        location_hint: result.location_hint,
        started_at: result.started_at,
        ended_at: result.ended_at,
        similarity: result.similarity,
        event_similarity: result.event_similarity,
        frame_similarity: result.frame_similarity,
        text_rank: result.text_rank,
        frame_count: result.frames?.length
      }))
    };
  }

  private async showRewind(input: { session_id: string; user_id: string; device_id: string; toolCall: ToolCall }): Promise<JsonObject> {
    const args = ShowRewindSchema.parse(input.toolCall.args);
    const details = await this.repository.getRewindDetails({ user_id: input.user_id, event_id: args.event_id });
    if (!details) throw new Error(`Rewind not found: ${args.event_id}`);

    const frameRefs = details.frames.map((frame) => ({
      frame_id: frame.id,
      device_frame_uuid: frame.device_frame_uuid,
      captured_at: frame.captured_at,
      offset_ms: frame.offset_ms,
      caption: frame.caption
    }));

    const { command } = await this.deviceBus.send({
      session_id: input.session_id,
      user_id: input.user_id,
      device_id: details.event.device_id,
      command_type: 'device.show_rewind',
      waitForAck: false,
      payload: {
        event_id: details.event.id,
        title: details.event.title,
        answer_text: args.answer_text,
        frame_refs: frameRefs,
        display: {
          local_asset_id: details.event.local_asset_id,
          thumbnail_frame_uuid: details.event.thumbnail_frame_uuid,
          location_hint: details.event.location_hint
        }
      }
    });

    return {
      event: {
        id: details.event.id,
        title: details.event.title,
        description: details.event.description
      },
      frames: frameRefs,
      device_command: compactCommand(command)
    };
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

function compactCommand(command: { id: string; command_type: string; status: string }) {
  return {
    id: command.id,
    command_type: command.command_type,
    status: command.status
  };
}
