#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';

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

if (!['local', 'remote'].includes(options.data)) {
  fail(`Unknown --data value "${options.data}". Use local or remote.`);
}

assertDockerRunning();

const env = {
  ...process.env,
  ...dotenv,
  REWIND_PORT: hostPort
};

if (options.data === 'remote') {
  env.SUPABASE_URL = process.env.SUPABASE_URL ?? dotenv.SUPABASE_URL ?? '';
  env.SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? dotenv.SUPABASE_SERVICE_ROLE_KEY ?? '';
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    fail('Remote mode requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in .env.backend or the shell environment.');
  }
} else {
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

const runtimeEnvFile = writeRuntimeEnv(env);
cleanupLegacyComposeProject(env);
try {
  runCompose(['up', '--build', '--force-recreate', '-d', 'rewind'], {
    ...env,
    REWIND_BACKEND_ENV_FILE: runtimeEnvFile
  });
} finally {
  removeRuntimeEnv(runtimeEnvFile);
}

waitForHealth(appUrl);

if (options.open) openUrl(`${appUrl}/health`);

console.log('Ready.');
console.log(`- backend: ${appUrl}`);
console.log('- phone web app: npm run web');

function parseArgs(args) {
  const parsed = {
    data: 'local',
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
  cleanupLegacyRuntimeEnv();
  const runtimeDir = mkdtempSync(resolve(tmpdir(), 'rewind-backend-env-'));
  const allowedKeys = [
    'DEV_DEVICE_ID',
    'DEV_HTTPS',
    'DEV_USER_ID',
    'EMBEDDING_MODE',
    'IMAGE_EMBEDDING_MODEL',
    'LIVE_MODEL_NAME',
    'MODEL_API_KEY',
    'SUPABASE_SERVICE_ROLE_KEY',
    'SUPABASE_URL',
    'TEXT_EMBEDDING_MODEL',
    'TLS_CERT_PATH',
    'TLS_KEY_PATH'
  ];
  const lines = allowedKeys
    .filter((key) => env[key] !== undefined)
    .map((key) => `${key}=${String(env[key]).replace(/\n/g, '')}`);
  const envFile = resolve(runtimeDir, 'backend.env');
  writeFileSync(envFile, `${lines.join('\n')}\n`, { mode: 0o600 });
  return envFile;
}

function removeRuntimeEnv(envFile) {
  try {
    const runtimeDir = dirname(envFile);
    unlinkSync(envFile);
    rmSync(runtimeDir, { recursive: true, force: true });
  } catch {
    // Best-effort cleanup only. Docker has already read the file.
  }
}

function cleanupLegacyRuntimeEnv() {
  rmSync(resolve(root, '.docker', 'rewind.env'), { force: true });
}

function cleanupLegacyComposeProject(env) {
  const inspect = spawnSync('docker', ['inspect', 'rewind-app', '--format', '{{ index .Config.Labels "com.docker.compose.project" }}'], {
    cwd: root,
    env,
    encoding: 'utf8'
  });
  if (inspect.status !== 0 || inspect.stdout.trim() !== 'rewind') return;
  run('docker', ['compose', '-p', 'rewind', 'down'], env);
}

function ensureBackendEnv() {
  const envPath = resolve(root, '.env.backend');
  if (existsSync(envPath)) return;
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
  npm run docker:backend       Local Supabase + backend
  npm run docker:local         Local Supabase + backend
  npm run docker:remote        Remote Supabase + backend
  npm run web                  Phone web app on a separate local port

Options:
  --data local|remote          Data target. Default: local.
  --port 8787                  Host port. Container always listens on 8787.
  --reset-db                   Reset local Supabase only when it was not already running.
  --no-open                    Do not open a browser.

The Docker runner reloads .env.backend on every start, writes a temporary
Compose env file, then injects either local Supabase or remote Supabase
credentials. It recreates only the Rewind backend container so updated env
values are applied. The temporary env file is removed after Docker reads it. It
does not stop or restart already-running local Supabase.`);
}
