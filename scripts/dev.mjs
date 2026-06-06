#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(new URL('.', import.meta.url).pathname, '..');
const supabasePorts = [54320, 54321, 54322, 54323, 54324, 54325, 54326, 54327, 54329];

const options = parseArgs(process.argv.slice(2));
const dotenv = readDotenv(resolve(root, '.env.backend'));
const webDotenv = readDotenv(resolve(root, '.env.web'));
const port = Number(options.port ?? dotenv.PORT ?? process.env.PORT ?? 8787);
const protocol = truthy(options.https ?? dotenv.DEV_HTTPS ?? process.env.DEV_HTTPS) ? 'https' : 'http';
const appUrl = `${protocol}://localhost:${port}`;
const webPort = Number(webDotenv.WEB_PORT ?? process.env.WEB_PORT ?? 8788);
const webUrl = `http://localhost:${webPort}/phone.html`;

if (options.help) {
  printHelp();
  process.exit(0);
}

if (!['json', 'local', 'remote'].includes(options.data)) {
  fail(`Unknown --data value "${options.data}". Use json, local, or remote.`);
}

if (!['none', 'backend', 'web', 'both'].includes(options.open)) {
  fail(`Unknown --open value "${options.open}". Use none, backend, web, or both.`);
}

if (!existsSync(resolve(root, 'node_modules'))) {
  run('npm', ['install']);
}

const backendAlreadyRunning = isHttpOk(`${appUrl}/health`);

const env = {
  ...process.env,
  PORT: String(port)
};

if (options.data === 'json') {
  env.REPOSITORY_MODE = 'local';
} else if (options.data === 'local') {
  env.REPOSITORY_MODE = 'supabase';
  assertDockerRunning();
  const supabaseAlreadyRunning = isHttpOk('http://127.0.0.1:54321/rest/v1/');
  if (supabaseAlreadyRunning) {
    console.log('Local Supabase is already running; reusing it.');
    if (options.resetDb) {
      console.log('Skipping --reset-db because local Supabase was already running.');
    }
  } else {
    run('npm', ['run', 'supabase:start']);
  }
  if (options.resetDb && !supabaseAlreadyRunning) {
    run('npm', ['run', 'supabase:reset']);
  }
  Object.assign(env, readSupabaseLocalEnv());
} else {
  env.REPOSITORY_MODE = 'supabase';
}

if (!(dotenv.MODEL_API_KEY ?? process.env.MODEL_API_KEY)) {
  fail('MODEL_API_KEY is required. Add it to .env.backend before starting the Rewind backend.');
}

console.log('');
console.log('Rewind local runner');
console.log(`- backend: ${appUrl}`);
console.log(`- phone web app: ${webUrl} (start with npm run web)`);
console.log(`- data: ${options.data}`);
console.log(`- repository mode: ${env.REPOSITORY_MODE}`);
console.log('');

if (backendAlreadyRunning) {
  console.log(`Backend is already running on ${appUrl}; reusing it.`);
  openRequestedUrls();
  process.exit(0);
}

const server = spawn('npx', ['tsx', 'watch', 'src/server.ts'], {
  cwd: root,
  env,
  stdio: 'inherit'
});

let opened = false;
const openTimer = setTimeout(() => {
  opened = true;
  openRequestedUrls();
}, options.openDelay);

server.on('exit', (code, signal) => {
  if (!opened) clearTimeout(openTimer);
  if (signal) process.kill(process.pid, signal);
  process.exit(code ?? 0);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    clearTimeout(openTimer);
    server.kill(signal);
  });
}

function parseArgs(args) {
  const parsed = {
    data: 'json',
    open: 'backend',
    openDelay: 1200,
    resetDb: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const [key, inlineValue] = arg.split('=', 2);
    const nextValue = () => inlineValue ?? args[++index];

    switch (key) {
      case '--data':
      case '--mode':
        parsed.data = normalizeData(nextValue());
        break;
      case '--json':
        parsed.data = 'json';
        break;
      case '--local':
        parsed.data = 'local';
        break;
      case '--remote':
        parsed.data = 'remote';
        break;
      case '--open':
        parsed.open = nextValue();
        break;
      case '--demo':
      case '--web':
        parsed.open = 'web';
        break;
      case '--both':
        parsed.open = 'both';
        break;
      case '--no-open':
      case '--no-demo':
        parsed.open = 'none';
        break;
      case '--port':
        parsed.port = nextValue();
        break;
      case '--reset-db':
        parsed.resetDb = true;
        break;
      case '--open-delay':
        parsed.openDelay = Number(nextValue());
        break;
      case '-h':
      case '--help':
        parsed.help = true;
        break;
      default:
        fail(`Unknown option "${arg}". Run npm run dev:all -- --help for usage.`);
    }
  }

  return parsed;
}

function normalizeData(value) {
  if (value === 'local-json' || value === 'local-file' || value === 'file') return 'json';
  if (value === 'local-supabase' || value === 'supabase-local') return 'local';
  if (value === 'hosted' || value === 'supabase-remote') return 'remote';
  return value;
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

function readSupabaseLocalEnv() {
  const result = spawnSync('supabase', ['status', '-o', 'env'], {
    cwd: root,
    encoding: 'utf8'
  });

  if (result.status !== 0) {
    fail(`Could not read local Supabase env:\n${result.stderr || result.stdout}`);
  }

  const values = {};
  for (const line of result.stdout.split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)\s*$/);
    if (!match) continue;
    values[match[1]] = match[2].replace(/^['"]|['"]$/g, '');
  }
  if (values.API_URL) values.SUPABASE_URL = values.API_URL;
  if (values.SERVICE_ROLE_KEY) values.SUPABASE_SERVICE_ROLE_KEY = values.SERVICE_ROLE_KEY;
  return values;
}

function isHttpOk(url) {
  const result = spawnSync('curl', ['-fsS', '--max-time', '2', url], {
    encoding: 'utf8'
  });
  return result.status === 0;
}

function openRequestedUrls() {
  if (options.open === 'backend' || options.open === 'both') openUrl(`${appUrl}/health`);
  if (options.open === 'web' || options.open === 'both') openUrl(webUrl);
}

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: process.env,
    stdio: 'inherit'
  });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

function openUrl(url) {
  if (process.platform === 'darwin') {
    spawn('open', [url], { stdio: 'ignore', detached: true }).unref();
    return;
  }
  console.log(`Open ${url}`);
}

function assertDockerRunning() {
  const result = spawnSync('docker', ['info'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });

  if (result.status === 0) return;

  const details = (result.stderr || result.stdout || '').trim();
  fail(`Local Supabase requires a running Docker-compatible daemon.

Start OrbStack or Docker Desktop, then rerun:
  npm run dev:all -- --data local --reset-db

Alternatives:
  npm run dev:json
  npm run dev:remote

Docker check failed:
${details}`);
}

function truthy(value) {
  return ['1', 'true', 'yes', 'on'].includes(String(value ?? '').toLowerCase());
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

function printHelp() {
  console.log(`Usage:
  npm run dev:all -- [options]

Data targets:
  --data json       Run with local JSON persistence only. Fastest demo path. Default.
  --data local      Start local Supabase, inject its env, and run the backend against it.
  --data remote     Run against SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from .env.backend.

App opening:
  --open backend    Open the backend health endpoint. Default.
  --open web        Open the separately served phone web app.
  --open both       Open both URLs.
  --open none       Start services without opening a browser.

Other options:
  --port 8787       Override the backend port.
  --reset-db        With --data local, reset local Supabase after starting it.
  --help            Show this message.

Shortcuts:
  --json, --local, --remote, --web, --both, --no-open

The runner reuses already-running backend and local Supabase services. It does not
kill listeners, stop containers, or restart services that are already available.
Run npm run web in a separate terminal for the phone app.`);
}
