import { z } from 'zod';
import { config } from '../config.js';
import type { JsonObject, RewindFrame, RewindProtocolResult, RewindSearchContext, RewindSearchResults, RewindSaveRequest, SessionHello, ToolCall } from '../types.js';
import { isValidInstant, normalizeTimeRange, nullableUtcIso, utcIso } from '../utils/time.js';
import { EmbeddingService } from './EmbeddingService.js';
import type { RewindRepository } from './RewindRepository.js';
import { SupervisionLogger } from './SupervisionLogger.js';

const DateTimeSchema = z.string().refine(isValidInstant, 'Must be a valid datetime.');

const SearchContextSchema = z
  .object({
    time_range: z
      .object({
        started_after: DateTimeSchema.optional(),
        ended_before: DateTimeSchema.optional()
      })
      .optional(),
    entities: z.array(z.unknown()).optional(),
    location_hint: z.string().optional(),
    status: z.array(z.string()).optional(),
    database_filters: z.record(z.string(), z.unknown()).optional()
  })
  .optional();

const TimeRangeSchema = z
  .object({
    started_after: DateTimeSchema.optional(),
    ended_before: DateTimeSchema.optional()
  })
  .optional();

const CreateRewindSchema = z.object({
  title: z.string().min(1).max(160),
  description: z.string().min(1).max(4000),
  entities: z.array(z.unknown()).default([]),
  location_hint: z.string().optional(),
  rewind_duration_seconds: z.number().positive().max(300).optional()
});
const DEFAULT_REWIND_CAPTURE_DURATION_SECONDS = 8;
const MAX_ENTITIES_PER_REWIND = 16;
const GENERIC_ENTITIES = new Set([
  'a',
  'an',
  'it',
  'item',
  'memory',
  'moment',
  'object',
  'something',
  'stuff',
  'that',
  'the',
  'thing',
  'this',
  'user'
]);
const GENERIC_SEARCH_TERMS = new Set([
  'a',
  'an',
  'are',
  'around',
  'at',
  'about',
  'did',
  'do',
  'during',
  'find',
  'for',
  'from',
  'happened',
  'had',
  'have',
  'i',
  'in',
  'is',
  'latest',
  'locate',
  'look',
  'me',
  'memories',
  'memory',
  'my',
  'of',
  'on',
  'please',
  'previous',
  'put',
  'recent',
  'remind',
  'rewind',
  'rewinds',
  'search',
  'show',
  'tell',
  'the',
  'this',
  'that',
  'these',
  'those',
  'to',
  'was',
  'were',
  'what',
  'when',
  'where'
]);

const SearchRewindsSchema = z.object({
  query: z.string().min(1).max(1000),
  limit: z.number().int().positive().max(20).default(10),
  time_range: TimeRangeSchema,
  entities: z.array(z.unknown()).optional(),
  location_hint: z.string().optional(),
  client_context: z
    .object({
      current_time: DateTimeSchema.optional(),
      time_zone: z.string().optional(),
      utc_offset_minutes: z.number().int().min(-840).max(840).optional()
    })
    .optional(),
  context: SearchContextSchema
});

type ToolRouteInput = {
  session_id: string;
  user_id: string;
  device_id: string;
  toolCall: ToolCall;
  max_rewind_duration_seconds?: number;
  rewind_buffer_duration_ms?: number;
  rewind_frame_interval_ms?: number;
  client_context?: SessionHello['context'];
  client_clock_offset_ms?: number;
};

export class ToolRouter {
  constructor(
    private readonly repository: RewindRepository,
    private readonly embeddings: EmbeddingService,
    private readonly logger: SupervisionLogger
  ) {}

  async route(input: ToolRouteInput): Promise<JsonObject> {
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

  private async execute(input: ToolRouteInput): Promise<JsonObject> {
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

  private async createRewind(input: ToolRouteInput): Promise<JsonObject> {
    const rawArgs = CreateRewindSchema.parse(input.toolCall.args);
    const args = {
      ...rawArgs,
      title: normalizeFreeText(rawArgs.title, 160),
      description: normalizeFreeText(rawArgs.description, 4000),
      entities: normalizeEntities(rawArgs.entities),
      location_hint: normalizeOptionalText(rawArgs.location_hint, 160)
    };
    const requestedDurationSeconds = args.rewind_duration_seconds ?? DEFAULT_REWIND_CAPTURE_DURATION_SECONDS;
    const bufferDurationMs = positiveInteger(input.rewind_buffer_duration_ms) ?? Math.max(1, input.max_rewind_duration_seconds ?? 60) * 1000;
    const frameIntervalMs = Math.min(bufferDurationMs, positiveInteger(input.rewind_frame_interval_ms) ?? 1000);
    const captureDurationMs = quantizedCaptureDurationMs(requestedDurationSeconds * 1000, {
      bufferDurationMs,
      frameIntervalMs
    });
    const rewindDurationSeconds = captureDurationMs / 1000;
    const backendAnchorUtc = normalizedToolReceivedAt(input.toolCall.received_at);
    const captureAnchorMs = Date.parse(backendAnchorUtc) + Math.round(input.client_clock_offset_ms ?? 0);
    const captureAnchorUtc = utcIso(captureAnchorMs);
    const captureWindowStartedAt = new Date(captureAnchorMs - captureDurationMs).toISOString();
    const captureWindowEndedAt = captureAnchorUtc;
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
      entities: args.entities,
      location_hint: args.location_hint,
      embedding,
      metadata: {
        rewind_duration_seconds: rewindDurationSeconds,
        capture_anchor_utc: captureAnchorUtc,
        capture_duration_ms: captureDurationMs,
        capture_frame_interval_ms: frameIntervalMs,
        capture_window_started_at: captureWindowStartedAt,
        capture_window_ended_at: captureWindowEndedAt,
        backend_capture_anchor_utc: backendAnchorUtc,
        client_clock_offset_ms: input.client_clock_offset_ms ?? 0
      }
    });

    const saveRequest: RewindSaveRequest = {
      request_id: input.toolCall.id,
      event_id: event.id,
      upload_url: `/v1/rewinds/${event.id}/commit`,
      title: event.title,
      description: event.description,
      rewind_duration_seconds: rewindDurationSeconds,
      capture_anchor_utc: captureAnchorUtc,
      capture_duration_ms: captureDurationMs,
      capture_frame_interval_ms: frameIntervalMs,
      capture_window_started_at: captureWindowStartedAt,
      capture_window_ended_at: captureWindowEndedAt,
      frame_embedding_mode: config.EMBEDDING_MODE,
      include_frame_images: config.EMBEDDING_MODE === 'text_and_image'
    };
    return {
      event: compactEvent(event, rewindDurationSeconds),
      save_request: saveRequest
    };
  }

  private async searchRewinds(input: ToolRouteInput): Promise<JsonObject> {
    return this.buildSearchResults(input.user_id, input.toolCall.args, input.client_context) as unknown as JsonObject;
  }

  private async buildSearchResults(userId: string, rawArgs: JsonObject, routeClientContext?: SessionHello['context']): Promise<RewindSearchResults> {
    const rawSearchArgs = SearchRewindsSchema.parse(rawArgs);
    const normalizedContext = normalizeSearchContext(rawSearchArgs.context);
    const clientContext = normalizeTemporalContext(rawSearchArgs.client_context ?? routeClientContext);
    const args = {
      ...rawSearchArgs,
      query: normalizeFreeText(rawSearchArgs.query, 1000),
      entities: normalizeEntities(rawSearchArgs.entities ?? []),
      location_hint: normalizeOptionalText(rawSearchArgs.location_hint, 160),
      context: normalizedContext
    };
    const entities = args.entities.length ? args.entities : args.context?.entities;
    const locationHint = args.location_hint ?? args.context?.location_hint;
    const timeRange = normalizeTimeRange(args.time_range ?? args.context?.time_range ?? inferRelativeTimeRange(args.query, clientContext));
    const contentQuery = searchContentQuery(args.query);
    const queryEmbedding = contentQuery ? await this.embeddings.embedQuery(contentQuery) : undefined;
    const results = await this.repository.searchRewinds({
      user_id: userId,
      query: contentQuery,
      query_embedding: queryEmbedding,
      context: {
        ...(args.context ?? {}),
        time_range: timeRange,
        entities,
        location_hint: locationHint
      },
      limit: args.limit
    });
    const resultFrames = await this.repository.getRewindFrames({
      user_id: userId,
      event_ids: results.map((result) => result.id)
    });
    const framesByEventId = new Map<string, RewindFrame[]>();
    for (const frame of resultFrames) {
      const frames = framesByEventId.get(frame.rewind_event_id);
      if (frames) frames.push(frame);
      else framesByEventId.set(frame.rewind_event_id, [frame]);
    }
    const protocolResults = results.map((result): RewindProtocolResult => ({
      event_id: result.id,
      title: result.title,
      description: result.description,
      entities: result.entities,
      location_hint: result.location_hint,
      started_at: nullableUtcIso(result.started_at),
      ended_at: nullableUtcIso(result.ended_at),
      score: {
        similarity: result.similarity,
        event_similarity: result.event_similarity,
        frame_similarity: result.frame_similarity,
        text_rank: result.text_rank,
        retrieval_score: result.retrieval_score
      },
      frame_refs: (result.frames?.length ? result.frames : framesByEventId.get(result.id) ?? []).map(frameRef)
    }));

    const searchResults: RewindSearchResults = {
      query: args.query,
      filters: {
        time_range: timeRange,
        entities,
        location_hint: locationHint
      },
      results: protocolResults
    };
    return searchResults;
  }
}

function normalizedToolReceivedAt(receivedAt: string | undefined): string {
  if (isValidInstant(receivedAt)) {
    return utcIso(receivedAt);
  }
  return utcIso(new Date());
}

function positiveInteger(value: number | undefined): number | undefined {
  return value !== undefined && Number.isInteger(value) && value > 0 ? value : undefined;
}

function quantizedCaptureDurationMs(requestedMs: number, input: { bufferDurationMs: number; frameIntervalMs: number }): number {
  const bufferDurationMs = Math.max(1, Math.round(input.bufferDurationMs));
  const frameIntervalMs = Math.max(1, Math.min(bufferDurationMs, Math.round(input.frameIntervalMs)));
  if (!Number.isFinite(requestedMs) || requestedMs <= 0) {
    throw new Error('rewind_duration_seconds must be greater than zero.');
  }
  const clampedMs = Math.min(bufferDurationMs, requestedMs);
  return Math.max(frameIntervalMs, Math.min(bufferDurationMs, Math.ceil(clampedMs / frameIntervalMs) * frameIntervalMs));
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
    captured_at: nullableUtcIso(frame.captured_at),
    offset_ms: frame.offset_ms
  };
}

function normalizeSearchContext(context: z.infer<typeof SearchContextSchema>): RewindSearchContext | undefined {
  if (!context) return undefined;
  const entities = normalizeEntities(context.entities ?? []);
  return {
    ...context,
    time_range: normalizeTimeRange(context.time_range),
    entities: entities.length ? entities : undefined,
    location_hint: normalizeOptionalText(context.location_hint, 160),
    status: normalizeStatuses(context.status)
  };
}

function normalizeStatuses(statuses?: string[]): string[] | undefined {
  const normalized = [...new Set((statuses ?? []).map((status) => normalizeEntityToken(status)).filter(Boolean))].filter((status) =>
    ['pending', 'committed', 'failed'].includes(status)
  );
  return normalized.length ? normalized : undefined;
}

function normalizeEntities(values: unknown[]): string[] {
  const entities: string[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    for (const token of entityTokens(value)) {
      const entity = normalizeEntityToken(token);
      if (!entity || seen.has(entity) || GENERIC_ENTITIES.has(entity)) continue;
      seen.add(entity);
      entities.push(entity);
      if (entities.length >= MAX_ENTITIES_PER_REWIND) return entities;
    }
  }
  return entities;
}

function entityTokens(value: unknown): string[] {
  if (typeof value !== 'string') return [];
  const normalized = value.normalize('NFKC').trim();
  if (!normalized) return [];
  if (normalized.startsWith('[') && normalized.endsWith(']')) {
    try {
      const parsed = JSON.parse(normalized) as unknown;
      if (Array.isArray(parsed)) return parsed.flatMap(entityTokens);
    } catch {
      // Fall through to plain token handling.
    }
  }
  return normalized.split(/[,;|]/);
}

function normalizeEntityToken(value: string): string {
  return stripWrapperPunctuation(value)
    .toLocaleLowerCase('en-US')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/^(?:a|an|the)\s+/, '')
    .replace(/[.?!:]+$/g, '')
    .trim()
    .slice(0, 80);
}

function normalizeFreeText(value: string, maxLength: number): string {
  const normalized = stripWrapperPunctuation(value)
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, maxLength);
  if (!normalized) throw new Error('Text field normalized to an empty value.');
  return normalized;
}

function normalizeOptionalText(value: string | undefined, maxLength: number): string | undefined {
  if (value === undefined) return undefined;
  const normalized = stripWrapperPunctuation(value)
    .toLocaleLowerCase('en-US')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, maxLength);
  return normalized || undefined;
}

function searchContentQuery(query: string): string | undefined {
  let content = query
    .replace(/\b(?:just now|recently|a moment ago|a few minutes ago|earlier today)\b/gi, ' ')
    .replace(
      /\b(?:in\s+the\s+)?(?:last|past)\s+(?:hour|\d{1,3}\s+(?:minute|minutes|hour|hours|day|days|week|weeks|month|months))\b/gi,
      ' '
    )
    .replace(
      /\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d{1,3})\s+(?:minute|minutes|hour|hours|day|days|week|weeks|month|months)\s+ago\b/gi,
      ' '
    )
    .replace(/\b(?:around|about|near|at)\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?\b/gi, ' ')
    .replace(/\b(?:last|previous)\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|week|month)\b/gi, ' ')
    .replace(/\b(?:this|current)\s+(?:morning|afternoon|evening|week|month)\b/gi, ' ')
    .replace(/\b(?:today|yesterday|tonight)\b/gi, ' ');

  content = stripWrapperPunctuation(content)
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 1000);

  if (!content) return undefined;
  const meaningfulTokens = content
    .toLocaleLowerCase('en-US')
    .match(/[\p{L}\p{N}]+/gu)
    ?.filter((token) => !GENERIC_SEARCH_TERMS.has(token));
  return meaningfulTokens?.length ? meaningfulTokens.join(' ').slice(0, 1000) : undefined;
}

function stripWrapperPunctuation(value: string): string {
  let normalized = value.normalize('NFKC').trim();
  for (let index = 0; index < 3; index += 1) {
    const stripped = normalized.replace(/^[\s"'`“”‘’[\]{}()<>]+|[\s"'`“”‘’[\]{}()<>]+$/g, '').trim();
    if (stripped === normalized) break;
    normalized = stripped;
  }
  return normalized;
}

type TemporalContext = {
  now: Date;
  timeZone?: string;
  utcOffsetMinutes?: number;
};

type LocalDateParts = {
  year: number;
  month: number;
  day: number;
};

type LocalDateTimeParts = LocalDateParts & {
  hour?: number;
  minute?: number;
};

function normalizeTemporalContext(context: SessionHello['context'] | undefined): TemporalContext {
  const now = isValidInstant(context?.current_time) ? new Date(context.current_time) : new Date();
  const timeZone = context?.time_zone && isValidTimeZone(context.time_zone) ? context.time_zone : undefined;
  const utcOffsetMinutes =
    typeof context?.utc_offset_minutes === 'number' && Number.isInteger(context.utc_offset_minutes) ? context.utc_offset_minutes : undefined;
  return { now, timeZone, utcOffsetMinutes };
}

function inferRelativeTimeRange(query: string, context: TemporalContext): RewindSearchContext['time_range'] | undefined {
  const normalized = query.toLocaleLowerCase('en-US').replace(/\s+/g, ' ').trim();
  const today = localDateParts(context.now, context);
  if (/\bjust now\b|\brecently\b|\ba moment ago\b|\ba few minutes ago\b/.test(normalized)) {
    return rollingUtcRange(context.now, 5, 'minute');
  }

  const agoMatch = normalized.match(
    /\b(\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(minute|minutes|hour|hours|day|days|week|weeks|month|months)\s+ago\b/
  );
  if (agoMatch) {
    const amount = parseSmallPositiveInteger(agoMatch[1]);
    if (amount !== undefined) {
      const unit = agoMatch[2];
      if (unit.startsWith('minute')) return relativeMinuteRange(context.now, amount);
      if (unit.startsWith('hour')) return relativeHourRange(context.now, amount);
      if (unit.startsWith('day')) return localDayRange(addLocalDays(today, -amount), context);
      if (unit.startsWith('week')) return localWeekRange(today, -amount, context);
      if (unit.startsWith('month')) return localMonthRange(today, -amount, context);
    }
  }

  const clockMatch = normalized.match(/\b(?:around|about|near|at)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b/);
  if (clockMatch) {
    const localTime = parseClockTime(clockMatch);
    if (localTime) {
      const rangeDay = /yesterday/.test(normalized) ? addLocalDays(today, -1) : today;
      const radiusMinutes = /around|about|near/.test(clockMatch[0]) ? 15 : 0;
      return localMinuteWindow(rangeDay, localTime.hour, localTime.minute, radiusMinutes, context);
    }
  }

  const weekdayMatch = normalized.match(/\b(?:last|previous)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/);
  if (weekdayMatch) return localDayRange(previousWeekday(today, weekdayIndex(weekdayMatch[1])), context);
  if (/\byesterday\b/.test(normalized)) return localDayRange(addLocalDays(today, -1), context);
  if (/\bthis morning\b|\btoday morning\b/.test(normalized)) return localHourRange(today, 0, 12, context);
  if (/\bthis afternoon\b|\btoday afternoon\b/.test(normalized)) return localHourRange(today, 12, 18, context);
  if (/\btonight\b|\bthis evening\b|\btoday evening\b/.test(normalized)) return localHourRange(today, 18, 24, context);
  if (/\btoday\b|\bearlier today\b/.test(normalized)) return localDayRange(today, context);
  if (/\bthis week\b/.test(normalized)) return localWeekRange(today, 0, context);
  if (/\blast week\b|\bprevious week\b/.test(normalized)) return localWeekRange(today, -1, context);
  if (/\bthis month\b/.test(normalized)) return localMonthRange(today, 0, context);
  if (/\blast month\b|\bprevious month\b/.test(normalized)) return localMonthRange(today, -1, context);

  if (/\b(?:last|past)\s+hour\b|\bin the last hour\b/.test(normalized)) return rollingUtcRange(context.now, 1, 'hour');

  const lastMatch = normalized.match(/\b(?:last|past|in the last)\s+(\d{1,3})\s+(minute|minutes|hour|hours|day|days|week|weeks|month|months)\b/);
  if (lastMatch) {
    const amount = Math.max(1, Math.min(365, Number(lastMatch[1])));
    const unit = lastMatch[2];
    if (unit.startsWith('minute')) return rollingUtcRange(context.now, amount, 'minute');
    if (unit.startsWith('hour')) return rollingUtcRange(context.now, amount, 'hour');
    if (unit.startsWith('day')) return rangeFromLocalDates(addLocalDays(today, -amount), addLocalDays(today, 1), context);
    if (unit.startsWith('week')) return rangeFromLocalDates(addLocalDays(today, -amount * 7), addLocalDays(today, 1), context);
    if (unit.startsWith('month')) return rangeFromLocalDates(addLocalMonths(today, -amount), addLocalDays(today, 1), context);
  }

  return undefined;
}

function parseSmallPositiveInteger(value: string): number | undefined {
  if (/^\d+$/.test(value)) return Math.max(1, Math.min(365, Number(value)));
  const words: Record<string, number> = {
    one: 1,
    two: 2,
    three: 3,
    four: 4,
    five: 5,
    six: 6,
    seven: 7,
    eight: 8,
    nine: 9,
    ten: 10,
    eleven: 11,
    twelve: 12
  };
  return words[value];
}

function rollingUtcRange(now: Date, amount: number, unit: 'minute' | 'hour'): RewindSearchContext['time_range'] {
  const minutes = unit === 'hour' ? amount * 60 : amount;
  return {
    started_after: utcIso(now.getTime() - minutes * 60_000),
    ended_before: utcIso(now)
  };
}

function relativeMinuteRange(now: Date, minutesAgo: number): RewindSearchContext['time_range'] {
  const start = floorUtcMinute(new Date(now.getTime() - minutesAgo * 60_000));
  return {
    started_after: utcIso(start),
    ended_before: utcIso(start.getTime() + 60_000)
  };
}

function relativeHourRange(now: Date, hoursAgo: number): RewindSearchContext['time_range'] {
  const start = floorUtcHour(new Date(now.getTime() - hoursAgo * 60 * 60_000));
  return {
    started_after: utcIso(start),
    ended_before: utcIso(start.getTime() + 60 * 60_000)
  };
}

function floorUtcMinute(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), date.getUTCHours(), date.getUTCMinutes()));
}

function floorUtcHour(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), date.getUTCHours()));
}

function parseClockTime(match: RegExpMatchArray): { hour: number; minute: number } | undefined {
  let hour = Number(match[1]);
  const minute = match[2] === undefined ? 0 : Number(match[2]);
  if (!Number.isInteger(hour) || !Number.isInteger(minute) || minute < 0 || minute > 59) return undefined;
  const meridiem = match[3];
  if (meridiem) {
    if (hour < 1 || hour > 12) return undefined;
    if (meridiem === 'pm' && hour !== 12) hour += 12;
    if (meridiem === 'am' && hour === 12) hour = 0;
  } else if (hour < 0 || hour > 23) {
    return undefined;
  }
  return { hour, minute };
}

function localDayRange(day: LocalDateParts, context: TemporalContext): RewindSearchContext['time_range'] {
  return rangeFromLocalDates(day, addLocalDays(day, 1), context);
}

function localHourRange(day: LocalDateParts, startHour: number, endHour: number, context: TemporalContext): RewindSearchContext['time_range'] {
  return rangeFromLocalDateTimes({ ...day, hour: startHour }, { ...day, hour: endHour }, context);
}

function localMinuteWindow(day: LocalDateParts, hour: number, minute: number, radiusMinutes: number, context: TemporalContext): RewindSearchContext['time_range'] {
  const start = addLocalMinutes({ ...day, hour, minute }, -radiusMinutes);
  const end = addLocalMinutes({ ...day, hour, minute }, radiusMinutes || 1);
  return rangeFromLocalDateTimes(start, end, context);
}

function localWeekRange(today: LocalDateParts, weekOffset: number, context: TemporalContext): RewindSearchContext['time_range'] {
  const weekday = dayOfWeek(today);
  const daysSinceMonday = (weekday + 6) % 7;
  const start = addLocalDays(today, -daysSinceMonday + weekOffset * 7);
  return rangeFromLocalDates(start, addLocalDays(start, 7), context);
}

function previousWeekday(today: LocalDateParts, targetWeekday: number): LocalDateParts {
  const currentWeekday = dayOfWeek(today);
  const daysAgo = ((currentWeekday - targetWeekday + 7) % 7) || 7;
  return addLocalDays(today, -daysAgo);
}

function weekdayIndex(value: string): number {
  return ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'].indexOf(value);
}

function localMonthRange(today: LocalDateParts, monthOffset: number, context: TemporalContext): RewindSearchContext['time_range'] {
  const start = addLocalMonths({ year: today.year, month: today.month, day: 1 }, monthOffset);
  return rangeFromLocalDates(start, addLocalMonths(start, 1), context);
}

function rangeFromLocalDates(start: LocalDateParts, end: LocalDateParts, context: TemporalContext): RewindSearchContext['time_range'] {
  return rangeFromLocalDateTimes({ ...start, hour: 0 }, { ...end, hour: 0 }, context);
}

function rangeFromLocalDateTimes(start: LocalDateTimeParts, end: LocalDateTimeParts, context: TemporalContext): RewindSearchContext['time_range'] {
  return {
    started_after: localDateTimeToUtcIso(start, context),
    ended_before: localDateTimeToUtcIso(end, context)
  };
}

function localDateParts(date: Date, context: TemporalContext): LocalDateParts {
  if (context.timeZone) {
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: context.timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit'
    }).formatToParts(date);
    return {
      year: Number(parts.find((part) => part.type === 'year')?.value),
      month: Number(parts.find((part) => part.type === 'month')?.value),
      day: Number(parts.find((part) => part.type === 'day')?.value)
    };
  }
  const shifted = new Date(date.getTime() + (context.utcOffsetMinutes ?? 0) * 60_000);
  return {
    year: shifted.getUTCFullYear(),
    month: shifted.getUTCMonth() + 1,
    day: shifted.getUTCDate()
  };
}

function localDateTimeToUtcIso(day: LocalDateTimeParts, context: TemporalContext): string {
  const hour = day.hour ?? 0;
  const minute = day.minute ?? 0;
  if (!context.timeZone) {
    const offsetMs = (context.utcOffsetMinutes ?? 0) * 60_000;
    return new Date(Date.UTC(day.year, day.month - 1, day.day, hour, minute) - offsetMs).toISOString();
  }
  const targetUtc = Date.UTC(day.year, day.month - 1, day.day, hour, minute);
  let utc = targetUtc;
  for (let index = 0; index < 3; index += 1) {
    const actual = zonedDateTimeParts(new Date(utc), context.timeZone);
    const actualAsUtc = Date.UTC(actual.year, actual.month - 1, actual.day, actual.hour, actual.minute, actual.second);
    utc -= actualAsUtc - targetUtc;
  }
  return new Date(utc).toISOString();
}

function zonedDateTimeParts(date: Date, timeZone: string): LocalDateParts & { hour: number; minute: number; second: number } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  }).formatToParts(date);
  const get = (type: string) => Number(parts.find((part) => part.type === type)?.value);
  return {
    year: get('year'),
    month: get('month'),
    day: get('day'),
    hour: get('hour'),
    minute: get('minute'),
    second: get('second')
  };
}

function addLocalDays(day: LocalDateParts, amount: number): LocalDateParts {
  const date = new Date(Date.UTC(day.year, day.month - 1, day.day + amount));
  return { year: date.getUTCFullYear(), month: date.getUTCMonth() + 1, day: date.getUTCDate() };
}

function addLocalMonths(day: LocalDateParts, amount: number): LocalDateParts {
  const date = new Date(Date.UTC(day.year, day.month - 1 + amount, day.day));
  return { year: date.getUTCFullYear(), month: date.getUTCMonth() + 1, day: date.getUTCDate() };
}

function addLocalMinutes(day: LocalDateTimeParts, amount: number): LocalDateTimeParts {
  const date = new Date(Date.UTC(day.year, day.month - 1, day.day, day.hour ?? 0, (day.minute ?? 0) + amount));
  return {
    year: date.getUTCFullYear(),
    month: date.getUTCMonth() + 1,
    day: date.getUTCDate(),
    hour: date.getUTCHours(),
    minute: date.getUTCMinutes()
  };
}

function dayOfWeek(day: LocalDateParts): number {
  return new Date(Date.UTC(day.year, day.month - 1, day.day)).getUTCDay();
}

function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone }).format(new Date());
    return true;
  } catch {
    return false;
  }
}
