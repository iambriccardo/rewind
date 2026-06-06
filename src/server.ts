import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import fastifyStatic from '@fastify/static';
import fastifyWebsocket from '@fastify/websocket';
import Fastify from 'fastify';
import type { WebSocket } from 'ws';
import { config, getLanUrls } from './config.js';
import type { ClientMessage, ServerMessage, ToolCall } from './types.js';
import { DeviceCommandBus } from './services/DeviceCommandBus.js';
import { EmbeddingService } from './services/EmbeddingService.js';
import { GeminiLiveAgent } from './services/GeminiLiveAgent.js';
import { createRepository } from './services/RewindRepository.js';
import { SupervisionLogger } from './services/SupervisionLogger.js';
import { ToolRouter } from './services/ToolRouter.js';

const protocol = config.httpsOptions ? 'https' : 'http';
const fastifyOptions: Record<string, unknown> = { logger: true };
if (config.httpsOptions) {
  fastifyOptions.https = config.httpsOptions;
}
const app = Fastify(fastifyOptions);

const repository = createRepository();
const embeddings = new EmbeddingService();
const deviceBus = new DeviceCommandBus(repository);
const logger = new SupervisionLogger(repository);
const toolRouter = new ToolRouter(repository, embeddings, deviceBus, logger);
const FRAME_INDEXING_CONCURRENCY = 4;

await app.register(fastifyWebsocket);
if (config.SERVE_DEMO_APP) {
  await app.register(fastifyStatic, {
    root: resolve('public'),
    prefix: '/'
  });
}

app.get('/health', async () => ({
  ok: true,
  repository: config.repositoryMode,
  embedding_provider: config.EMBEDDING_PROVIDER,
  embedding_mode: config.EMBEDDING_MODE,
  text_embedding_model: config.TEXT_EMBEDDING_MODEL,
  image_embedding_model: config.IMAGE_EMBEDDING_MODEL,
  embedding_dimension: config.EMBEDDING_DIMENSION,
  live_model_name: config.LIVE_MODEL_NAME,
  demo_app_enabled: config.SERVE_DEMO_APP,
  frame_embedding_max_per_rewind: embeddings.frameEmbeddingLimit()
}));

app.get('/v1/rewinds', async (request) => {
  const userId = getUserId(request.headers, request.query);
  return { results: await repository.listRewinds(userId) };
});

app.get<{ Params: { id: string } }>('/v1/rewinds/:id', async (request, reply) => {
  const userId = getUserId(request.headers, request.query);
  const details = await repository.getRewindDetails({ user_id: userId, event_id: request.params.id });
  if (!details) return reply.code(404).send({ error: 'Not found' });
  return details;
});

app.post<{ Params: { id: string }; Body: Extract<ClientMessage, { type: 'rewind.commit' }> }>('/v1/rewinds/:id/commit', async (request, reply) => {
  const userId = getUserId(request.headers, request.query);
  const deviceId = getDeviceId(request.headers, request.query);
  const body = await prepareCommitPayload(request.body);
  const result = await repository.commitRewind({
    ...body,
    event_id: request.params.id,
    user_id: userId,
    device_id: deviceId
  });
  return reply.code(201).send(result);
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

  deviceBus.register(deviceId, socket as WebSocket);
  socket.on('message', async (raw) => {
    try {
      const message = JSON.parse(raw.toString()) as ClientMessage;
      await handleClientMessage(socket as WebSocket, {
        message,
        session_id: session.id,
        user_id: userId,
        device_id: deviceId,
        agent
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
        await runToolCalls(socket as WebSocket, { session_id: session.id, user_id: userId, device_id: deviceId }, agent, toolCalls);
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
  input: { message: ClientMessage; session_id: string; user_id: string; device_id: string; agent: GeminiLiveAgent }
): Promise<void> {
  await logger.event({
    session_id: input.session_id,
    user_id: input.user_id,
    type: input.message.type,
    payload: input.message as unknown as Record<string, unknown>
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
    case 'user.turn':
      input.agent.sendLiveTurn(input.message.state);
      return;
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
    case 'device.command_ack':
      await deviceBus.handleAck(input.message);
      return;
    case 'rewind.commit': {
      const commit = await prepareCommitPayload(input.message);
      const result = await repository.commitRewind({
        ...commit,
        user_id: input.user_id,
        device_id: input.device_id
      });
      sendJson(socket, { type: 'rewind.committed', event: result.event, frames: result.frames });
      return;
    }
    case 'device.frame_observation':
      sendJson(socket, { type: 'agent.message', text: 'Frame observation noted.', payload: input.message });
      return;
    default:
      throw new Error(`Unhandled message type: ${(input.message as ClientMessage).type}`);
  }
}

async function prepareCommitPayload(message: Extract<ClientMessage, { type: 'rewind.commit' }>): Promise<Extract<ClientMessage, { type: 'rewind.commit' }>> {
  if (!embeddings.shouldEmbedFrameImages()) {
    return stripFrameImages(message);
  }

  let eligible = 0;
  const frames = await mapWithConcurrency(message.frames, FRAME_INDEXING_CONCURRENCY, async (frame) => {
    const { image_base64, mime_type, ...safeFrame } = frame;
    const shouldEmbed = image_base64 && mime_type && eligible < embeddings.frameEmbeddingLimit();
    if (!shouldEmbed) return safeFrame;
    eligible += 1;
    const { embedding, description } = await embeddings.embedFrameImage({
      base64: image_base64,
      mimeType: mime_type,
      textHint: frame.caption
    });
    return {
      ...safeFrame,
      caption: safeFrame.caption ?? description,
      embedding,
      metadata: {
        ...(safeFrame.metadata ?? {}),
        frame_description: description,
        image_embedding_model: config.IMAGE_EMBEDDING_MODEL,
        text_embedding_model: config.TEXT_EMBEDDING_MODEL,
        image_embedding_mode: config.EMBEDDING_MODE
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

function stripFrameImages(message: Extract<ClientMessage, { type: 'rewind.commit' }>): Extract<ClientMessage, { type: 'rewind.commit' }> {
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
  context: { session_id: string; user_id: string; device_id: string },
  agent: GeminiLiveAgent,
  toolCalls: ToolCall[]
): Promise<void> {
  for (const toolCall of toolCalls) {
    sendJson(socket, { type: 'agent.tool_call', tool_call: toolCall });
    const result = await toolRouter.route({ ...context, toolCall });
    sendJson(socket, { type: 'agent.tool_result', tool_call_id: toolCall.id, tool_name: toolCall.name, result });
    if (toolCall.name === 'search_rewinds') {
      sendJson(socket, { type: 'search.results', results: (result.results ?? []) as never[] });
    } else {
      sendJson(socket, { type: 'agent.message', text: `${toolCall.name} completed`, payload: result });
    }

    const followUps = await agent.handleToolResult(toolCall, result);
    sendPendingAgentTexts(socket, agent);
    if (followUps.length) {
      await runToolCalls(socket, context, agent, followUps);
    }
  }
}

function sendPendingAgentTexts(socket: WebSocket, agent: GeminiLiveAgent): void {
  for (const text of agent.takePendingTexts()) {
    sendJson(socket, { type: 'agent.message', text });
  }
}

function sendJson(socket: WebSocket, message: ServerMessage): void {
  socket.send(JSON.stringify(message));
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
const localUrl = `${protocol}://localhost:${config.PORT}/phone.html`;
if (config.SERVE_DEMO_APP) {
  app.log.info(`phone simulator: ${localUrl}`);
  for (const url of getLanUrls(protocol, config.PORT)) {
    app.log.info(`LAN phone simulator: ${url}`);
  }
}
