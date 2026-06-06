# Rewind Prototype

Local MVP for a real-time rewind memory agent. The backend accepts a live device WebSocket, routes Gemini Live tool calls, stores rewind metadata, and searches events through text, metadata, and vector indexes. Media bytes stay on the device simulator except for transient frame JPEGs used when frame embeddings are enabled.

## What Is Included

- Fastify TypeScript backend at `http://localhost:8787`
- WebSocket route at `/v1/live`
- Browser phone simulator served separately with `npm run web`
- Supabase migrations for rewind events and rewind frames
- `pgvector` + HNSW search RPC for combined embedding + metadata/full-text filtering
- Tool-call/tool-result debug protocol messages visible in the simulator
- Gemini Live function calling with `MODEL_API_KEY`
- Gemini Live protocol support for text, image/video frames, audio chunks, tool calls, and manual tool responses
- Gemini embeddings using `gemini-embedding-2` with 768 dimensions by default
- Optional frame embedding mode that stores direct multimodal frame vectors for pgvector search

## Quick Start

Docker is the primary way to run the backend locally. The phone web app runs separately so the backend container does not host browser assets.

```bash
npm install
cp .env.backend.example .env.backend
cp .env.web.example .env.web
# Add MODEL_API_KEY to .env.backend
npm run docker:json
```

In a second terminal:

```bash
npm run web
```

Open:

```txt
http://localhost:8788/phone.html
```

`npm run docker:json` runs only the backend in Docker with local JSON persistence. It is the fastest backend path and does not require Supabase, but it still requires `MODEL_API_KEY`.

Common Docker commands:

```bash
npm run docker:backend        # remote Supabase from .env.backend + backend
npm run docker:local          # local Supabase Docker stack + backend
npm run docker:json           # JSON persistence, fastest local backend
npm run web                   # phone web app from public/
npm run docker:logs           # follow app container logs
npm run docker:down           # stop/remove the app container
```

Advanced options:

```bash
npm run docker:run -- --data remote|local|json --port 8787
npm run docker:run -- --data local --reset-db
npm run docker:run -- --data remote --no-open
```

The Docker runner uses `.env.backend` as the source of truth every time it starts. If `.env.backend` does not exist, it creates one from `.env.backend.example` or migrates an existing legacy `.env`. The Rewind backend container is recreated on each Docker start so changed env values are applied. Local Supabase is not restarted if it is already running.

After backend code changes, rerun the same Docker command, for example:

```bash
npm run docker:backend
```

The Docker image copies only `src/` at build time. It does not copy or serve `public/`. For phone UI changes, restart `npm run web` or reload the browser. For hot reload while editing backend code, use the non-Docker commands under "Non-Docker Development".

For remote Supabase backend runs, set these in `.env.backend`:

```bash
REPOSITORY_MODE=supabase
SUPABASE_URL=...
SUPABASE_SERVICE_ROLE_KEY=...
MODEL_API_KEY=...
```

For local Supabase demos, run:

```bash
npm run docker:local
```

The runner starts the Supabase CLI's local Docker stack if needed, reads the local service-role key, and points the app container at `host.docker.internal:54321`.

The phone app reads browser-safe config from `.env.web`:

```bash
WEB_PORT=8788
BACKEND_URL=http://localhost:8787
```

Try:

1. Click `Start Streaming`.
2. Allow camera access if available.
3. Type `remember where I left this pen`.
4. Then type `where is my pen?`.
5. Inspect the `Tool JSON` panel for normalized tool calls/results.

The simulator also has:

- `Hide Camera`: stops realtime image forwarding while keeping the session open.
- `Mute Mic`: disables microphone tracks without closing the WebSocket.
- `Frame every`: controls how often camera frames are forwarded to Gemini Live.

The demo keeps realtime media cheap by default: camera frames are resized to a 384px max edge, encoded as moderate-quality JPEGs, and forwarded to Gemini Live at 1 FPS by default. The `Frame every` control can raise that interval up to 60 seconds to reduce Live API media tokens. The rolling frame buffer still captures locally at 1 FPS for 30 seconds, so rewind commits keep useful temporal coverage even when realtime model observation is throttled. A rewind indexes at most 12 frame embeddings. Audio is downsampled in the browser to 16 kHz little-endian PCM and sent in 250 ms chunks with `audio/pcm;rate=16000`.

## Non-Docker Development

The older local Node runner is still available for quick code iteration:

```bash
npm run dev:json
npm run dev:local
npm run dev:remote
npm run web
```

## Supabase

The CLI is linked to the hosted Supabase project:

```txt
rewind / eoczmtezhqteujpwgbwz
```

Local Supabase:

```bash
npm run supabase:start
supabase status -o env
```

For the Docker local mode you do not need to copy these values; `npm run docker:local` reads them automatically and injects container-safe values into the backend container. For manual non-Docker runs, copy the printed local URL and service-role key into `.env.backend`, then set:

```bash
REPOSITORY_MODE=supabase
```

Apply migrations locally:

```bash
npm run supabase:reset
```

Push to the linked hosted project when ready:

```bash
npm run supabase:push
```

The repo keeps the DB setup in one squashed initial migration:

- `20260606130000_init_rewind_schema.sql`

The search setup uses `extensions.vector(768)`, cosine HNSW indexes on event and frame embeddings, trigger-maintained `search_tsv`, GIN indexes for full-text/entities, and time/device helper indexes. The RPC pulls event-vector, frame-vector, text, and recent candidates separately, applies filters first, then merges scores so semantic search and database-style search both stay usable.

Local Supabase uses the same migrations. Run Docker/OrbStack first, then:

```bash
npm run supabase:start
npm run supabase:reset
supabase status -o env
```

Copy the local service-role key into `.env.backend` and keep `REPOSITORY_MODE=supabase`.

For no-database non-Docker persistence:

```bash
REPOSITORY_MODE=local npm run dev
```

Because `.env.backend` is loaded as the backend source of truth, edit `.env.backend` directly for persistent backend settings. Edit `.env.web` for phone app settings such as `BACKEND_URL`.

## Model Key

Set these in `.env.backend`:

```bash
MODEL_API_KEY=...
EMBEDDING_MODE=text_only
LIVE_MODEL_NAME=gemini-2.5-flash-native-audio-preview-12-2025
```

`MODEL_API_KEY` is required for Live sessions and embeddings. `EMBEDDING_MODE` is the only embedding behavior switch: keep `text_only` for the cheapest path, or use `text_and_image` to index selected rewind frames too.

Model defaults are code constants for this MVP:

- `TEXT_EMBEDDING_MODEL=gemini-embedding-2`: current Gemini embedding default, used for rewind event text.
- `IMAGE_EMBEDDING_MODEL=gemini-embedding-2`: direct multimodal frame embeddings when frame indexing is enabled.
- `EMBEDDING_DIMENSION=768`: smaller/faster pgvector index with good retrieval quality and lower storage than 1536/3072.
- `FRAME_EMBEDDING_MAX_PER_REWIND=12`: bounded indexing cost per rewind while preserving enough visual evidence for short captures.

The agent prompt is intentionally passive: streamed audio/video can be observed, but it should not call tools unless the user explicitly asks to remember/save/capture a rewind or search/find/show a rewind. `create_rewind` tool calls must include `rewind_duration_seconds`.

## Embedding Modes

`EMBEDDING_MODE=text_only`:

- Embeds the rewind event text only.
- Uses title, description, entities, and location hint.
- Phone commits only frame IDs, timestamps, captions, and metadata.
- Cheapest and best default.

`EMBEDDING_MODE=text_and_image`:

- Embeds the rewind event text.
- Also asks the phone simulator to send transient frame JPEG data during `rewind.commit`.
- Backend embeds up to 12 frames per rewind. This cap is fixed in code for the hackathon MVP.
- Backend uses the multimodal embedding default to store frame vectors plus frame IDs/timestamps/captions/metadata. Raw image bytes are discarded before DB insert.

Relevant env:

```bash
EMBEDDING_MODE=text_only
```

For frame embeddings:

```bash
EMBEDDING_MODE=text_and_image
```

The backend still has a vision-summary fallback path if the image model constant is changed to a non-embedding Gemini vision model later, but the default path is direct multimodal embedding.

The selected Live testing model is `gemini-2.5-flash-native-audio-preview-12-2025`. It is a native-audio Live model, so the backend configures audio response modality, output audio transcription, low media resolution, and manual tool handling. If `LIVE_MODEL_NAME` is changed to a non-native-audio Live model, the backend switches back to text response modality.

## Phone Camera Over LAN

Desktop browsers can use camera access on `localhost`. A phone connecting to your Mac over LAN usually needs HTTPS for `getUserMedia`.

Use `mkcert` or another local CA to create a trusted cert, then set:

```bash
DEV_HTTPS=true
TLS_CERT_PATH=certs/rewind.local.pem
TLS_KEY_PATH=certs/rewind.local-key.pem
```

For phone-over-LAN testing, set `WEB_HOST=0.0.0.0` and `BACKEND_URL` in `.env.web` to your backend LAN URL. Camera/mic access on a phone usually requires HTTPS for the web app, so set `WEB_HTTPS=true` plus `WEB_TLS_CERT_PATH` and `WEB_TLS_KEY_PATH` when using trusted local certs.

## Environment Notes

- `MODEL_API_KEY` is the only model secret.
- `.env.backend` contains backend secrets and database/model settings.
- `.env.web` contains browser-safe phone app settings only.
- `EMBEDDING_MODE=text_only` embeds stored rewind text only.
- `EMBEDDING_MODE=text_and_image` also asks the phone to include transient frame JPEGs for the fixed 12-frame indexing cap.
- `SERVE_DEMO_APP=false` keeps the backend APIs from serving `/phone.html`; this is the default and the Docker image does not include `public/`.
