#!/usr/bin/env node
import { createServer as createHttpServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { extname, join, resolve, sep } from 'node:path';
import { spawn } from 'node:child_process';

const root = resolve(new URL('.', import.meta.url).pathname, '..');
const publicDir = resolve(root, 'public');
const env = readDotenv(resolve(root, '.env.web'));
const host = env.WEB_HOST || process.env.WEB_HOST || '127.0.0.1';
const port = Number(env.WEB_PORT || process.env.WEB_PORT || 8788);
const backendUrl = env.BACKEND_URL || process.env.BACKEND_URL || 'http://localhost:8787';
const frameStoreDir = resolve(root, env.WEB_FRAME_STORE_PATH || process.env.WEB_FRAME_STORE_PATH || '.data/device-frames');
const openBrowser = !process.argv.includes('--no-open');
const httpsEnabled = truthy(env.WEB_HTTPS || process.env.WEB_HTTPS);
const protocol = httpsEnabled ? 'https' : 'http';
const serverOptions = httpsEnabled ? readHttpsOptions() : undefined;

mkdirSync(frameStoreDir, { recursive: true });

const server = httpsEnabled ? createHttpsServer(serverOptions, handleRequest) : createHttpServer(handleRequest);

function handleRequest(request, response) {
  void routeRequest(request, response).catch((error) => {
    response.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }));
  });
}

async function routeRequest(request, response) {
  const url = new URL(request.url || '/', `http://${request.headers.host || 'localhost'}`);
  if (url.pathname === '/env.js') {
    sendEnv(response);
    return;
  }

  if (url.pathname === '/device/frames' && request.method === 'GET') {
    listFrames(response);
    return;
  }

  if (url.pathname === '/device/frames' && request.method === 'POST') {
    await saveFrame(request, response);
    return;
  }

  if (url.pathname === '/device/frames' && request.method === 'DELETE') {
    clearFrames(response);
    return;
  }

  const frameMatch = url.pathname.match(/^\/device\/frames\/([^/]+)(?:\/image)?$/);
  if (frameMatch && request.method === 'GET') {
    sendFrame(frameMatch[1], url.pathname.endsWith('/image'), response);
    return;
  }

  const pathname = url.pathname === '/' ? '/phone.html' : decodeURIComponent(url.pathname);
  const filePath = resolve(publicDir, `.${pathname}`);
  if (!filePath.startsWith(`${publicDir}${sep}`) || !existsSync(filePath)) {
    response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end('Not found');
    return;
  }

  response.writeHead(200, {
    'Content-Type': contentType(filePath),
    'Cache-Control': 'no-store'
  });
  response.end(readFileSync(filePath));
}

server.listen(port, host, () => {
  const url = `${protocol}://${host === '0.0.0.0' ? 'localhost' : host}:${port}/phone.html`;
  console.log(`Phone web app: ${url}`);
  console.log(`Backend URL: ${backendUrl}`);
  console.log(`Device frame store: ${frameStoreDir}`);
  if (openBrowser) openUrl(url);
});

async function saveFrame(request, response) {
  const payload = await readJson(request);
  const frameId = sanitizeFrameId(payload.device_frame_uuid || payload.frame_id || payload.id);
  const mimeType = String(payload.mime_type || 'image/jpeg');
  const imageBase64 = imageBase64FromPayload(payload);
  const imageBuffer = Buffer.from(imageBase64, 'base64');
  if (!imageBuffer.length) throw new Error('Frame image is empty.');
  if (imageBuffer.length > 5_000_000) throw new Error('Frame image is too large.');

  const paths = framePaths(frameId);
  const metadata = {
    device_frame_uuid: frameId,
    captured_at: payload.captured_at || payload.capturedAt || new Date().toISOString(),
    caption: payload.caption || null,
    mime_type: mimeType,
    byte_length: imageBuffer.length,
    stored_at: new Date().toISOString()
  };

  writeFileSync(paths.image, imageBuffer);
  writeFileSync(paths.metadata, `${JSON.stringify(metadata, null, 2)}\n`);

  response.writeHead(201, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify({ ok: true, frame: metadata, image_url: `/device/frames/${frameId}/image` }));
}

function listFrames(response) {
  const frames = readdirSync(frameStoreDir)
    .filter((name) => name.endsWith('.json'))
    .map((name) => JSON.parse(readFileSync(join(frameStoreDir, name), 'utf8')))
    .sort((a, b) => String(a.captured_at || '').localeCompare(String(b.captured_at || '')));
  response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify({ frames }));
}

function sendFrame(frameIdValue, imageOnly, response) {
  const frameId = sanitizeFrameId(frameIdValue);
  const paths = framePaths(frameId);
  if (!existsSync(paths.metadata)) {
    response.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify({ error: 'Frame not found.' }));
    return;
  }

  if (!imageOnly) {
    response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(readFileSync(paths.metadata));
    return;
  }

  const metadata = JSON.parse(readFileSync(paths.metadata, 'utf8'));
  response.writeHead(200, {
    'Content-Type': metadata.mime_type || 'image/jpeg',
    'Content-Length': statSync(paths.image).size,
    'Cache-Control': 'no-store'
  });
  response.end(readFileSync(paths.image));
}

function clearFrames(response) {
  rmSync(frameStoreDir, { recursive: true, force: true });
  mkdirSync(frameStoreDir, { recursive: true });
  response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify({ ok: true }));
}

function framePaths(frameId) {
  return {
    image: join(frameStoreDir, `${frameId}.jpg`),
    metadata: join(frameStoreDir, `${frameId}.json`)
  };
}

function sanitizeFrameId(value) {
  const frameId = String(value || '');
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(frameId)) {
    throw new Error('Invalid frame id.');
  }
  return frameId;
}

function imageBase64FromPayload(payload) {
  if (typeof payload.image_base64 === 'string') return payload.image_base64;
  if (typeof payload.data_url === 'string') return payload.data_url.split(',')[1] || '';
  throw new Error('Frame image_base64 or data_url is required.');
}

function readJson(request) {
  return new Promise((resolveJson, reject) => {
    let body = '';
    request.setEncoding('utf8');
    request.on('data', (chunk) => {
      body += chunk;
      if (body.length > 8_000_000) {
        reject(new Error('Request body is too large.'));
        request.destroy();
      }
    });
    request.on('end', () => {
      try {
        resolveJson(JSON.parse(body || '{}'));
      } catch (error) {
        reject(error);
      }
    });
    request.on('error', reject);
  });
}

function readHttpsOptions() {
  const certPath = env.WEB_TLS_CERT_PATH || env.TLS_CERT_PATH || process.env.WEB_TLS_CERT_PATH || process.env.TLS_CERT_PATH;
  const keyPath = env.WEB_TLS_KEY_PATH || env.TLS_KEY_PATH || process.env.WEB_TLS_KEY_PATH || process.env.TLS_KEY_PATH;
  if (!certPath || !keyPath) {
    fail('WEB_HTTPS=true requires WEB_TLS_CERT_PATH and WEB_TLS_KEY_PATH in .env.web.');
  }
  return {
    cert: readFileSync(resolve(root, certPath)),
    key: readFileSync(resolve(root, keyPath))
  };
}

function sendEnv(response) {
  const clientEnv = {
    BACKEND_URL: backendUrl,
    FRAME_STORE_ENABLED: true,
    DEV_USER_ID: env.DEV_USER_ID || process.env.DEV_USER_ID || '00000000-0000-4000-8000-000000000001',
    DEV_DEVICE_ID: env.DEV_DEVICE_ID || process.env.DEV_DEVICE_ID || 'dev-phone'
  };
  response.writeHead(200, {
    'Content-Type': 'application/javascript; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  response.end(`window.REWIND_WEB_CONFIG = ${JSON.stringify(clientEnv)};\n`);
}

function readDotenv(path) {
  if (!existsSync(path)) return {};
  const values = {};
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!match || line.trimStart().startsWith('#')) continue;
    values[match[1]] = match[2].replace(/^['"]|['"]$/g, '');
  }
  return values;
}

function contentType(path) {
  switch (extname(path)) {
    case '.html':
      return 'text/html; charset=utf-8';
    case '.js':
      return 'application/javascript; charset=utf-8';
    case '.css':
      return 'text/css; charset=utf-8';
    case '.svg':
      return 'image/svg+xml';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    default:
      return 'application/octet-stream';
  }
}

function openUrl(url) {
  if (process.platform === 'darwin') {
    spawn('open', [url], { stdio: 'ignore', detached: true }).unref();
    return;
  }
  console.log(`Open ${url}`);
}

function truthy(value) {
  return ['1', 'true', 'yes', 'on'].includes(String(value ?? '').toLowerCase());
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
