#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(new URL('.', import.meta.url).pathname, '..');
const options = parseArgs(process.argv.slice(2));
ensureBackendEnv();
const dotenv = readDotenv(resolve(root, '.env.backend'));
const hostPort = String(options.port ?? process.env.REWIND_PORT ?? process.env.PORT ?? dotenv.PORT ?? 8787);
const appUrl = `http://localhost:${hostPort}`;

if (options.help) {
  printHelp();
  process.exit(0);
}

if (!['json', 'local', 'remote'].includes(options.data)) {
  fail(`Unknown --data value "${options.data}". Use json, local, or remote.`);
}

assertDockerRunning();

const env = {
  ...process.env,
  ...dotenv,
  REWIND_PORT: hostPort,
  SERVE_DEMO_APP: 'false'
};

if (options.data === 'json') {
  env.REPOSITORY_MODE = 'local';
  env.SUPABASE_URL = '';
  env.SUPABASE_SERVICE_ROLE_KEY = '';
} else if (options.data === 'remote') {
  env.REPOSITORY_MODE = 'supabase';
  env.SUPABASE_URL = process.env.SUPABASE_URL ?? dotenv.SUPABASE_URL ?? '';
  env.SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? dotenv.SUPABASE_SERVICE_ROLE_KEY ?? '';
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    fail('Remote mode requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in .env.backend or the shell environment.');
  }
} else {
  env.REPOSITORY_MODE = 'supabase';
  ensureLocalSupabase(options.resetDb);
  const localSupabase = readSupabaseLocalEnv();
  env.SUPABASE_URL = 'http://host.docker.internal:54321';
  env.SUPABASE_SERVICE_ROLE_KEY = localSupabase.SUPABASE_SERVICE_ROLE_KEY;
}

if (!env.MODEL_API_KEY) {
  fail('MODEL_API_KEY is required. Add it to .env.backend before starting the Rewind backend.');
}

console.log('');
console.log('Rewind Docker runner');
console.log('- target: backend');
console.log(`- data: ${options.data}`);
console.log(`- backend: ${appUrl}`);
console.log('');

writeRuntimeEnv(env);
runCompose(['up', '--build', '--force-recreate', '-d', 'rewind'], env);

waitForHealth(appUrl);

if (options.open) openUrl(`${appUrl}/health`);

console.log('Ready.');
console.log(`- backend: ${appUrl}`);
console.log('- phone web app: npm run web');

function parseArgs(args) {
  const parsed = {
    data: 'remote',
    open: true,
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
      case '--target':
        if (nextValue() !== 'backend') fail('Docker only runs the backend now. Use npm run web for the phone app.');
        break;
      case '--backend':
        break;
      case '--port':
        parsed.port = nextValue();
        break;
      case '--reset-db':
        parsed.resetDb = true;
        break;
      case '--open':
        parsed.open = true;
        break;
      case '--no-open':
        parsed.open = false;
        break;
      case '-h':
      case '--help':
        parsed.help = true;
        break;
      default:
        fail(`Unknown option "${arg}". Run npm run docker:run -- --help for usage.`);
    }
  }

  return parsed;
}

function normalizeData(value) {
  if (value === 'local-json' || value === 'file') return 'json';
  if (value === 'local-supabase' || value === 'supabase-local') return 'local';
  if (value === 'hosted' || value === 'supabase-remote') return 'remote';
  return value;
}

function ensureLocalSupabase(resetDb) {
  const alreadyRunning = isHttpOk('http://127.0.0.1:54321/rest/v1/');
  if (!alreadyRunning) {
    run('npm', ['run', 'supabase:start'], process.env);
  } else {
    console.log('Local Supabase is already running; reusing it.');
  }

  if (resetDb && !alreadyRunning) {
    run('npm', ['run', 'supabase:reset'], process.env);
  } else if (resetDb) {
    console.log('Skipping --reset-db because local Supabase is already running.');
  }
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
  if (values.SERVICE_ROLE_KEY) values.SUPABASE_SERVICE_ROLE_KEY = values.SERVICE_ROLE_KEY;
  return values;
}

function writeRuntimeEnv(env) {
  const runtimeDir = resolve(root, '.docker');
  mkdirSync(runtimeDir, { recursive: true });
  const allowedKeys = [
    'DEV_DEVICE_ID',
    'DEV_HTTPS',
    'DEV_USER_ID',
    'EMBEDDING_MODE',
    'LIVE_MODEL_NAME',
    'MODEL_API_KEY',
    'REPOSITORY_MODE',
    'SERVE_DEMO_APP',
    'SUPABASE_SERVICE_ROLE_KEY',
    'SUPABASE_URL',
    'TLS_CERT_PATH',
    'TLS_KEY_PATH'
  ];
  const lines = allowedKeys
    .filter((key) => env[key] !== undefined)
    .map((key) => `${key}=${String(env[key]).replace(/\n/g, '')}`);
  writeFileSync(resolve(runtimeDir, 'rewind.env'), `${lines.join('\n')}\n`);
}

function ensureBackendEnv() {
  const envPath = resolve(root, '.env.backend');
  if (existsSync(envPath)) return;
  const legacyPath = resolve(root, '.env');
  if (existsSync(legacyPath)) {
    copyFileSync(legacyPath, envPath);
    console.log('Created .env.backend from existing .env.');
    return;
  }
  const examplePath = resolve(root, '.env.backend.example');
  if (!existsSync(examplePath)) {
    fail('Missing .env.backend and .env.backend.example. Create .env.backend before starting Docker.');
  }
  copyFileSync(examplePath, envPath);
  console.log('Created .env.backend from .env.backend.example. Add MODEL_API_KEY before starting the Rewind backend.');
}

function waitForHealth(baseUrl) {
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    if (isHttpOk(`${baseUrl}/health`)) return;
    spawnSync('sleep', ['1']);
  }
  runCompose(['logs', '--tail=120', 'rewind'], process.env);
  fail('Timed out waiting for the Rewind container health endpoint.');
}

function runCompose(args, env) {
  run('docker', ['compose', ...args], env);
}

function run(command, args, env) {
  const result = spawnSync(command, args, {
    cwd: root,
    env,
    stdio: 'inherit'
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function isHttpOk(url) {
  const result = spawnSync('curl', ['-fsS', '--max-time', '2', url], {
    encoding: 'utf8',
    stdio: 'ignore'
  });
  return result.status === 0;
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
  fail(`Docker is not running:\n${(result.stderr || result.stdout || '').trim()}`);
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

function printHelp() {
  console.log(`Usage:
  npm run docker:run -- [options]

Common commands:
  npm run docker:backend       Remote Supabase + backend
  npm run docker:local         Local Supabase + backend
  npm run docker:json          Local JSON persistence + backend
  npm run web                  Phone web app on a separate local port

Options:
  --data remote|local|json     Data target. Default: remote.
  --port 8787                  Host port. Container always listens on 8787.
  --reset-db                   Reset local Supabase only when it was not already running.
  --no-open                    Do not open a browser.

The Docker runner uses .env.backend as the source of truth on every start and
always disables phone page hosting inside the container. It recreates only the
Rewind backend container so updated env values are applied. It does not stop or
restart already-running local Supabase.`);
}
