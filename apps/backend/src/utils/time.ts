import type { JsonObject, RewindSearchContext } from '../types.js';

export function isValidInstant(value: unknown): value is string {
  return typeof value === 'string' && Number.isFinite(Date.parse(value));
}

export function utcIso(value: string | number | Date): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) {
    throw new Error(`Invalid datetime: ${String(value)}`);
  }
  return date.toISOString();
}

export function optionalUtcIso(value: string | null | undefined): string | undefined {
  if (!value) return undefined;
  return isValidInstant(value) ? utcIso(value) : undefined;
}

export function nullableUtcIso(value: string | null | undefined): string | null {
  return optionalUtcIso(value) ?? null;
}

export function normalizeTimeRange(range: RewindSearchContext['time_range'] | undefined): RewindSearchContext['time_range'] | undefined {
  const startedAfter = optionalUtcIso(range?.started_after);
  const endedBefore = optionalUtcIso(range?.ended_before);
  if (!startedAfter && !endedBefore) return undefined;
  return {
    started_after: startedAfter,
    ended_before: endedBefore
  };
}

export function normalizeKnownMetadataInstants(metadata: JsonObject | undefined): JsonObject {
  const normalized: JsonObject = { ...(metadata ?? {}) };
  for (const key of ['capture_anchor_utc', 'capture_window_started_at', 'capture_window_ended_at', 'location_captured_at']) {
    const value = normalized[key];
    if (isValidInstant(value)) normalized[key] = utcIso(value);
  }
  return normalized;
}
