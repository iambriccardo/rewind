import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import fastifyWebsocket from '@fastify/websocket';
import Fastify from 'fastify';
import type { WebSocket } from 'ws';
import { config } from './config.js';
import type {
  ClientMessage,
  JsonObject,
  RewindCommitRequest,
  RewindEvent,
  RewindFrame,
  RewindSaveRequest,
  RewindSearchResults,
  ServerMessage,
  ToolCall
} from './types.js';
import { EmbeddingService } from './services/EmbeddingService.js';
import { GeminiLiveAgent } from './services/GeminiLiveAgent.js';
import { createRepository } from './services/RewindRepository.js';
import { SupervisionLogger } from './services/SupervisionLogger.js';
import { ToolRouter } from './services/ToolRouter.js';

const MAX_UPLOAD_BODY_BYTES = 25_000_000;
const fastifyOptions: Record<string, unknown> = { logger: true, bodyLimit: MAX_UPLOAD_BODY_BYTES };
if (config.httpsOptions) {
  fastifyOptions.https = config.httpsOptions;
}
const app = Fastify(fastifyOptions);

const repository = createRepository();
const embeddings = new EmbeddingService();
const logger = new SupervisionLogger(repository);
const toolRouter = new ToolRouter(repository, embeddings, logger);
const FRAME_INDEXING_CONCURRENCY = 4;

await app.register(fastifyWebsocket);
app.addHook('onRequest', async (request, reply) => {
  reply.header('Access-Control-Allow-Origin', '*');
  reply.header('Access-Control-Allow-Headers', 'content-type,x-user-id,x-device-id');
  reply.header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  if (request.method === 'OPTIONS') {
    return reply.code(204).send();
  }
});

app.get('/health', async () => ({
  ok: true,
  service: 'rewind-backend',
  storage: {
    repository: config.repositoryMode
  },
  realtime: {
    websocket_path: '/v1/live',
    live_model_name: config.LIVE_MODEL_NAME
  },
  embeddings: {
    provider: config.EMBEDDING_PROVIDER,
    mode: config.EMBEDDING_MODE,
    text_model: config.TEXT_EMBEDDING_MODEL,
    image_embedding_model: config.IMAGE_EMBEDDING_MODEL,
    dimension: config.EMBEDDING_DIMENSION,
    max_embedded_frames_per_rewind: embeddings.frameEmbeddingLimit()
  },
  uploads: {
    rewind_commit_path: '/v1/rewinds/:event_id/commit',
    max_body_bytes: MAX_UPLOAD_BODY_BYTES
  },
  search: {
    rewind_search_path: '/v1/rewinds/search'
  }
}));

app.get('/v1/rewinds', async (request) => {
  const userId = getUserId(request.headers, request.query);
  const results = await repository.listRewinds(userId);
  return { results: results.map((event) => ({ ...publicEvent(event), frames: event.frames?.map(publicFrame) })) };
});

app.post<{ Body: JsonObject }>('/v1/rewinds/search', async (request, reply) => {
  const userId = getUserId(request.headers, request.query);
  try {
    return await toolRouter.search({ user_id: userId, args: request.body ?? {} });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return reply.code(400).send({ error: message });
  }
});

app.get<{ Params: { id: string } }>('/v1/rewinds/:id', async (request, reply) => {
  const userId = getUserId(request.headers, request.query);
  const details = await repository.getRewindDetails({ user_id: userId, event_id: request.params.id });
  if (!details) return reply.code(404).send({ error: 'Not found' });
  return publicDetails(details);
});

app.post<{ Params: { id: string }; Body: RewindCommitRequest }>('/v1/rewinds/:id/commit', async (request, reply) => {
  const userId = getUserId(request.headers, request.query);
  const deviceId = getDeviceId(request.headers, request.query);
  const validationError = validateCommitRequest(request.body, request.params.id);
  if (validationError) return reply.code(400).send({ error: validationError });
  const existing = await repository.getRewindDetails({ user_id: userId, event_id: request.params.id });
  if (!existing || existing.event.device_id !== deviceId) return reply.code(404).send({ error: 'Not found' });
  const body = await prepareCommitPayload(request.body);
  const eventEmbedding = await buildCommittedEventEmbedding(existing.event, body);
  const result = await repository.commitRewind({
    ...body,
    event_id: request.params.id,
    user_id: userId,
    device_id: deviceId,
    location: {
      ...body.location,
      location_hint: body.location?.location_hint ?? existing.event.location_hint ?? undefined
    },
    embedding: eventEmbedding,
    metadata: {
      ...existing.event.metadata,
      ...(body.metadata ?? {}),
      event_embedding_refreshed_at: new Date().toISOString(),
      event_embedding_sources: ['live_summary', 'entities', 'location_hint']
    }
  });
  return reply.code(201).send(publicDetails(result));
});

app.get('/v1/live', { websocket: true }, async (socket, request) => {
  const userId = getUserId(request.headers, request.query);
  const deviceId = getDeviceId(request.headers, request.query);
  let agent: GeminiLiveAgent;
  try {
    agent = new GeminiLiveAgent();
  } catch (error) {
    sendJson(socket as WebSocket, { type: 'error', error: error instanceof Error ? error.message : String(error) });
    socket.close();
    return;
  }
  const session = await repository.createSession({
    user_id: userId,
    device_id: deviceId,
    model: agent.model,
    metadata: {
      tools: agent.getToolDeclarations(),
      user_agent: request.headers['user-agent'] ?? null
    }
  });

  let lastUserText = '';
  socket.on('message', async (raw) => {
    try {
      const message = JSON.parse(raw.toString()) as ClientMessage;
      if (message.type === 'user.text') lastUserText = message.text;
      await handleClientMessage(socket as WebSocket, {
        message,
        session_id: session.id,
        user_id: userId,
        device_id: deviceId,
        agent,
        last_user_text: lastUserText
      });
    } catch (error) {
      app.log.error({ error }, 'websocket message failed');
      sendJson(socket as WebSocket, { type: 'error', error: error instanceof Error ? error.message : String(error) });
    }
  });

  socket.once('close', async () => {
    agent.close();
    await repository.endSession(session.id).catch((error) => app.log.error(error));
  });

  let readySent = false;
  const sendReady = () => {
    if (readySent) return;
    readySent = true;
    sendJson(socket as WebSocket, { type: 'session.ready', session_id: session.id, user_id: userId, device_id: deviceId });
  };
  await agent
    .connectLive({
      onState: (state, payload) => {
        sendJson(socket as WebSocket, { type: 'agent.live_state', state, payload });
        if (state === 'connected') sendReady();
      },
      onText: (text) => sendJson(socket as WebSocket, { type: 'agent.media', modality: 'text', text }),
      onAudio: (data, mimeType) => sendJson(socket as WebSocket, { type: 'agent.media', modality: 'audio', mime_type: mimeType, data }),
      onToolCalls: async (toolCalls) => {
        await runToolCalls(socket as WebSocket, { session_id: session.id, user_id: userId, device_id: deviceId, last_user_text: lastUserText }, agent, toolCalls);
      }
    })
    .catch((error) => {
      const message = error instanceof Error ? error.message : String(error);
      app.log.error({ error }, 'Live model connection failed');
      sendJson(socket as WebSocket, { type: 'agent.live_state', state: 'error', payload: { error: message } });
    });
});

async function handleClientMessage(
  socket: WebSocket,
  input: { message: ClientMessage; session_id: string; user_id: string; device_id: string; agent: GeminiLiveAgent; last_user_text: string }
): Promise<void> {
  await logger.event({
    session_id: input.session_id,
    user_id: input.user_id,
    type: input.message.type,
    payload: loggableClientMessage(input.message)
  });

  switch (input.message.type) {
    case 'user.text': {
      const toolCalls = await input.agent.handleUserText(input.message.text);
      sendPendingAgentTexts(socket, input.agent);
      if (!toolCalls.length) {
        return;
      }
      await runToolCalls(socket, input, input.agent, toolCalls);
      return;
    }
    case 'user.media':
      try {
        input.agent.sendLiveMedia(input.message);
      } catch (error) {
        sendJson(socket, {
          type: 'agent.message',
          text: 'Media chunk received, but Gemini Live is not available.',
          payload: {
            modality: input.message.modality,
            mime_type: input.message.mime_type,
            seq: input.message.seq,
            timestamp: input.message.timestamp,
            error: error instanceof Error ? error.message : String(error)
          }
        });
      }
      return;
    case 'user.media_end':
      try {
        input.agent.sendLiveMediaEnd(input.message.modality);
      } catch (error) {
        app.log.warn({ error, modality: input.message.modality }, 'Live media end could not be forwarded');
      }
      return;
    default:
      throw new Error(`Unhandled message type: ${(input.message as ClientMessage).type}`);
  }
}

function validateCommitRequest(message: RewindCommitRequest, eventId: string): string | undefined {
  if (!message || typeof message !== 'object') return 'Commit payload must be a JSON object.';
  if (message.event_id && message.event_id !== eventId) return 'Commit event_id must match the URL event_id.';
  if (!Array.isArray(message.frames) || !message.frames.length) return 'Commit payload requires at least one frame.';
  if (message.frames.length > 120) return 'Commit payload contains too many frames.';
  for (const [index, frame] of message.frames.entries()) {
    if (!frame || typeof frame !== 'object') return `Frame ${index} must be an object.`;
    if (!frame.device_frame_uuid || typeof frame.device_frame_uuid !== 'string') return `Frame ${index} requires device_frame_uuid.`;
    if (frame.image_base64 && typeof frame.image_base64 !== 'string') return `Frame ${index} image_base64 must be a string.`;
    if (frame.mime_type && typeof frame.mime_type !== 'string') return `Frame ${index} mime_type must be a string.`;
  }
  return undefined;
}

function loggableClientMessage(message: ClientMessage): JsonObject {
  if (message.type !== 'user.media') return message as unknown as JsonObject;
  return {
    type: message.type,
    modality: message.modality,
    mime_type: message.mime_type,
    seq: message.seq,
    timestamp: message.timestamp,
    data_bytes_base64: message.data.length
  };
}

async function prepareCommitPayload(message: RewindCommitRequest): Promise<RewindCommitRequest> {
  if (!embeddings.shouldEmbedFrameImages()) {
    return stripFrameImages(message);
  }

  let eligible = 0;
  const frames = await mapWithConcurrency(message.frames, FRAME_INDEXING_CONCURRENCY, async (frame) => {
    const { image_base64, mime_type, ...safeFrame } = frame;
    const shouldEmbed = image_base64 && mime_type && eligible < embeddings.frameEmbeddingLimit();
    if (!shouldEmbed) return safeFrame;
    eligible += 1;
    const embedding = await embeddings.embedFrameImage({
      base64: image_base64,
      mimeType: mime_type
    });
    return {
      ...safeFrame,
      embedding,
      metadata: {
        ...(safeFrame.metadata ?? {}),
        image_embedding_model: config.IMAGE_EMBEDDING_MODEL,
        frame_embedding_mode: config.EMBEDDING_MODE
      }
    };
  });

  return {
    ...message,
    frames,
    metadata: {
      ...(message.metadata ?? {}),
      frame_embeddings_generated: eligible,
      embedding_mode: config.EMBEDDING_MODE
    }
  };
}

async function buildCommittedEventEmbedding(event: RewindEvent, commit: RewindCommitRequest): Promise<number[]> {
  const embeddingText = embeddings.buildEventEmbeddingText({
    title: event.title,
    description: event.description,
    entities: event.entities,
    location_hint: commit.location?.location_hint ?? event.location_hint
  });
  return embeddings.embedDocument(embeddingText);
}

function stripFrameImages(message: RewindCommitRequest): RewindCommitRequest {
  return {
    ...message,
    frames: message.frames.map(({ image_base64, mime_type, ...frame }) => frame),
    metadata: {
      ...(message.metadata ?? {}),
      embedding_mode: config.EMBEDDING_MODE
    }
  };
}

async function mapWithConcurrency<T, R>(items: T[], concurrency: number, mapper: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let nextIndex = 0;
  const workers = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await mapper(items[index], index);
    }
  });
  await Promise.all(workers);
  return results;
}

async function runToolCalls(
  socket: WebSocket,
  context: { session_id: string; user_id: string; device_id: string; last_user_text?: string },
  agent: GeminiLiveAgent,
  toolCalls: ToolCall[]
): Promise<void> {
  for (const toolCall of toolCalls) {
    const normalizedToolCall = normalizeToolCall(toolCall, context.last_user_text);
    let result: JsonObject;
    try {
      result = await toolRouter.route({ ...context, toolCall: normalizedToolCall });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      sendJson(socket, { type: 'error', error: `${normalizedToolCall.name} failed`, details: { message } });
      await agent.handleToolResult(normalizedToolCall, { error: message });
      continue;
    }
    if (normalizedToolCall.name === 'search_rewinds') {
      sendJson(socket, { type: 'rewind.search_results', ...(result as unknown as RewindSearchResults) });
    }
    if (normalizedToolCall.name === 'create_rewind') {
      const saveRequest = result.save_request as RewindSaveRequest | undefined;
      if (!saveRequest) throw new Error('create_rewind did not return a save_request.');
      sendJson(socket, { type: 'rewind.save_request', ...saveRequest });
    }

    const followUps = await agent.handleToolResult(normalizedToolCall, result);
    sendPendingAgentTexts(socket, agent);
    if (followUps.length) {
      await runToolCalls(socket, context, agent, followUps);
    }
  }
}

function normalizeToolCall(toolCall: ToolCall, lastUserText?: string): ToolCall {
  if (toolCall.name !== 'search_rewinds') return toolCall;
  if (typeof toolCall.args.query === 'string' && toolCall.args.query.trim()) return toolCall;
  if (!lastUserText?.trim()) return toolCall;
  return {
    ...toolCall,
    args: {
      ...toolCall.args,
      query: lastUserText.trim()
    }
  };
}

function sendPendingAgentTexts(socket: WebSocket, agent: GeminiLiveAgent): void {
  for (const text of agent.takePendingTexts()) {
    sendJson(socket, { type: 'agent.message', text });
  }
}

function sendJson(socket: WebSocket, message: ServerMessage): void {
  socket.send(JSON.stringify(message));
}

function publicDetails(details: { event: RewindEvent; frames: RewindFrame[] }) {
  return {
    event: publicEvent(details.event),
    frames: details.frames.map(publicFrame)
  };
}

function publicEvent(event: RewindEvent) {
  const { embedding, search_tsv, ...safeEvent } = event as RewindEvent & { search_tsv?: unknown };
  return safeEvent;
}

function publicFrame(frame: RewindFrame) {
  const { embedding, ...safeFrame } = frame;
  return safeFrame;
}

function getUserId(headers: Record<string, unknown>, query: unknown): string {
  const queryUserId = typeof query === 'object' && query && 'user_id' in query ? String((query as Record<string, unknown>).user_id) : undefined;
  const headerUserId = typeof headers['x-user-id'] === 'string' ? headers['x-user-id'] : undefined;
  return queryUserId || headerUserId || config.DEV_USER_ID;
}

function getDeviceId(headers: Record<string, unknown>, query: unknown): string {
  const queryDeviceId = typeof query === 'object' && query && 'device_id' in query ? String((query as Record<string, unknown>).device_id) : undefined;
  const headerDeviceId = typeof headers['x-device-id'] === 'string' ? headers['x-device-id'] : undefined;
  return queryDeviceId || headerDeviceId || config.DEV_DEVICE_ID;
}

try {
  const packageJson = JSON.parse(readFileSync(resolve('package.json'), 'utf8')) as { version?: string };
  app.log.info({ version: packageJson.version }, 'starting rewind prototype');
} catch {
  app.log.info('starting rewind prototype');
}

await app.listen({ host: config.HOST, port: config.PORT });
