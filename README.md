# Rewind Prototype

Local MVP for a real-time rewind memory agent. The backend accepts a live device WebSocket, routes Gemini Live tool calls, stores rewind metadata, and searches events through text, metadata, and vector indexes. Media bytes stay on the device simulator except for transient frame JPEGs used when frame embeddings are enabled.

## What Is Included

- Fastify TypeScript backend at `http://localhost:8787`
- WebSocket route at `/v1/live`
- Browser phone simulator served separately with `npm run web`
- Supabase migrations for rewind events and rewind frames
- `pgvector` + HNSW search RPC for combined embedding + metadata/full-text filtering
- Product-level Rewind protocol messages visible in the simulator
- Gemini Live function calling with `MODEL_API_KEY`
- Gemini Live protocol support for text, image/video frames, audio chunks, and internal backend tool handling
- Gemini embeddings using `gemini-embedding-2` with 768 dimensions by default
- Optional frame embedding mode that embeds selected frame images with `gemini-embedding-2` and stores frame vectors for pgvector search
- Client implementer reference for HTTP endpoints and the live WebSocket state machine in [docs/client-protocol.md](docs/client-protocol.md)

## Time Handling

The system stores, compares, and returns timestamps as UTC ISO 8601 instants with a trailing `Z`. The only local-time fields in the protocol are `session.hello.context.time_zone` and `session.hello.context.utc_offset_minutes`, which tell the model/backend how to interpret user phrases such as `this morning`, `today`, or `last week`.

In practice: clients send frame capture times in UTC, the backend normalizes accepted timestamps before writing to Supabase, and search converts user-local semantic periods into UTC ranges before querying Postgres.

## Repository Layout

```txt
apps/backend/   Fastify API, Gemini Live agent loop, Supabase repository, Dockerfile
apps/web/       Browser phone simulator and local ephemeral device-frame store UI
apps/ios/       Native iOS app project
docs/           Client protocol and implementer documentation
scripts/        Root-level local, Docker, and web runner scripts
supabase/       Supabase CLI config, migration, and seed files
```

Keep running commands from the repo root. The root `package.json` is the orchestration surface for the monorepo.

## Quick Start

Docker is the primary way to run the backend locally. The phone web app runs separately so the backend container does not host browser assets.

```bash
npm install
cp .env.backend.example .env.backend
cp .env.web.example .env.web
# Add MODEL_API_KEY to .env.backend
npm run docker:backend
```

In a second terminal:

```bash
npm run web
```

Open:

```txt
http://localhost:8788/phone.html
```

`npm run docker:backend` runs the backend in Docker against local Supabase. The runner starts or reuses the Supabase CLI local stack, reads its service-role key, and injects container-safe connection values.

Common Docker commands:

```bash
npm run docker:backend        # local Supabase Docker stack + backend
npm run docker:local          # local Supabase Docker stack + backend
npm run docker:remote         # hosted Supabase from .env.backend + backend
npm run web                   # phone web app from apps/web/public/
npm run docker:logs           # follow app container logs
npm run docker:down           # stop/remove the app container
```

The backend app Compose project is named `rewind-backend`. If local Supabase is running, OrbStack may also show a separate `rewind` group for the Supabase CLI stack; that group contains containers such as `supabase_db_rewind` and is not the backend app.

Advanced options:

```bash
npm run docker:run -- --data local|remote --port 8787
npm run docker:run -- --data local --reset-db
npm run docker:run -- --data remote --no-open
```

The Docker runner reloads `.env.backend` every time it starts. If `.env.backend` does not exist, it creates one from `.env.backend.example`. It writes a short-lived temporary Compose env file, recreates the Rewind backend container so changed values are applied, then deletes the temporary env file after Docker has read it. Local Supabase is not restarted if it is already running.

After backend code changes, rerun the same Docker command, for example:

```bash
npm run docker:backend
```

The Docker image copies only `apps/backend/` at build time. It does not copy or serve `apps/web/`. For phone UI changes, restart `npm run web` or reload the browser. For hot reload while editing backend code, use the non-Docker commands under "Non-Docker Development".

For remote Supabase backend runs, set these in `.env.backend` only when you explicitly want to use the hosted database:

```bash
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
WEB_FRAME_STORE_PATH=.data/device-frames
```

The standalone phone simulator writes captured JPEG frames to `WEB_FRAME_STORE_PATH` on the machine running `npm run web`. This imitates the iOS-side frame cache: the backend stores and returns `device_frame_uuid` references, and the simulator renders `/device/frames/:uuid/image` locally when `rewind.search_results` includes frame refs. The folder is append-only for now and grows until you delete it by hand:

```bash
rm -rf .data/device-frames
```

Try:

1. Click `Start Streaming`.
2. Allow camera access if available.
3. Say something like `remember where I left this pen`.
4. Then ask by voice, for example `where is my pen?`.
5. Open `Dev protocol JSON` only when you need to inspect `rewind.save_request` or `rewind.search_results`.

The simulator also has:

- `Hide Camera`: stops realtime image forwarding while keeping the session open.
- `Mute Mic`: disables microphone tracks without closing the WebSocket.
- `Frame every`: controls how often camera frames are forwarded to Gemini Live.

The demo keeps realtime media cheap by default: camera frames are resized to a 384px max edge, encoded as moderate-quality JPEGs, and forwarded to Gemini Live at 1 FPS by default. The `Frame every` control can raise that interval up to 60 seconds to reduce Live API media tokens. The rolling frame buffer is independent and still captures locally at 1 FPS for 60 seconds, so rewind commits keep useful temporal coverage even when realtime model observation is throttled. If Gemini ever omits an explicit rewind duration, the app falls back to an 8-second capture window. A rewind indexes at most 12 frame embeddings. Audio is downsampled in the browser to 16 kHz little-endian PCM and sent in 250 ms chunks with `audio/pcm;rate=16000`.

## Client Protocol

The WebSocket protocol is intentionally product-level. Gemini function calls are backend internals and are never forwarded to clients as tool calls.

The full implementer contract for HTTP endpoints, WebSocket states, message schemas, upload behavior, and search responses lives in [docs/client-protocol.md](docs/client-protocol.md). Keep that document aligned with code when adding or changing client-visible protocol fields.

Client to backend over `/v1/live`:

First message after WebSocket open:

```json
{
  "type": "session.hello",
  "protocol_version": 1,
  "device": {
    "id": "dev-phone",
    "kind": "ios"
  },
  "buffers": {
    "rewind": {
      "duration_ms": 60000,
      "frame_interval_ms": 1000,
      "max_frames": 60
    }
  },
  "context": {
    "current_time": "2026-06-06T15:30:00.000Z",
    "time_zone": "Europe/Vienna",
    "utc_offset_minutes": 120
  }
}
```

The backend uses `buffers.rewind.duration_ms` to configure the Gemini Live tool schema and prompt. `create_rewind` is optimized for the current or just-finished moment, not arbitrary historical capture. If the user says `save the last 20 seconds` or `remind me about the last minute`, the model uses that rolling-buffer duration, clamped to the available buffer; otherwise it infers the smallest useful replay window. The backend anchors the save request to the Gemini Live tool-call receive time, adjusts it into the client's frame timestamp clock using the handshake time, and sends an explicit capture window so client uploads are not shifted by later backend or network delay.

After `session.ready`, the client may stream text/media:

```json
{ "type": "user.text", "text": "remember where I left this" }
```

```json
{
  "type": "user.media",
  "modality": "audio",
  "mime_type": "audio/pcm;rate=16000",
  "data": "<base64>",
  "seq": 42,
  "timestamp": "2026-06-06T15:30:00.000Z"
}
```

```json
{ "type": "user.media_end", "modality": "audio" }
```

Backend to client over `/v1/live`:

```json
{
  "type": "session.ready",
  "session_id": "live-session-uuid",
  "user_id": "00000000-0000-4000-8000-000000000001",
  "device_id": "dev-phone",
  "max_rewind_duration_seconds": 60
}
```

```json
{
  "type": "rewind.save_request",
  "request_id": "gemini-function-call-id",
  "event_id": "rewind-event-uuid",
  "upload_url": "/v1/rewinds/rewind-event-uuid/commit",
  "title": "Pen location",
  "description": "User asked to remember where the pen was left.",
  "rewind_duration_seconds": 8,
  "capture_anchor_utc": "2026-06-06T15:30:00.000Z",
  "capture_duration_ms": 8000,
  "capture_window_started_at": "2026-06-06T15:29:52.000Z",
  "capture_window_ended_at": "2026-06-06T15:30:00.000Z",
  "include_frame_images": false,
  "frame_embedding_mode": "text_only"
}
```

On `rewind.save_request`, the client should copy frames from its local rolling buffer whose timestamps fall inside `[capture_window_started_at, capture_window_ended_at]` and upload them out-of-band with `POST upload_url`. The live socket should keep streaming and must not wait on the upload.

```json
{
  "type": "rewind.search_results",
  "query": "where is my pen",
  "filters": { "entities": ["pen"] },
  "results": [
    {
      "event_id": "rewind-event-uuid",
      "title": "Pen location",
      "description": "User left the pen on the desk.",
      "entities": ["pen", "desk"],
      "location_hint": "desk",
      "started_at": "2026-06-06T15:29:52.000Z",
      "ended_at": "2026-06-06T15:30:00.000Z",
      "score": {
        "similarity": 0.82,
        "event_similarity": 0.82,
        "frame_similarity": null,
        "text_rank": 0.6
      },
      "frame_refs": [
        {
          "frame_id": "stored-frame-row-uuid",
          "device_frame_uuid": "client-frame-uuid",
          "captured_at": "2026-06-06T15:29:59.000Z",
          "offset_ms": 7000
        }
      ]
    }
  ]
}
```

The only out-of-band upload endpoint currently needed by clients is:

```http
POST /v1/rewinds/:event_id/commit
```

Commit payload:

```json
{
  "event_id": "rewind-event-uuid",
  "local_asset_id": "client-local-asset-id",
  "thumbnail_frame_uuid": "client-frame-uuid",
  "started_at": "2026-06-06T15:29:52.000Z",
  "ended_at": "2026-06-06T15:30:00.000Z",
  "frames": [
    {
      "device_frame_uuid": "client-frame-uuid",
      "local_asset_id": "client-local-asset-id",
      "captured_at": "2026-06-06T15:29:59.000Z",
      "offset_ms": 7000
    }
  ],
  "metadata": {
    "rewind_duration_seconds": 8,
    "capture_anchor_utc": "2026-06-06T15:30:00.000Z",
    "capture_duration_ms": 8000,
    "capture_window_started_at": "2026-06-06T15:29:52.000Z",
    "capture_window_ended_at": "2026-06-06T15:30:00.000Z",
    "frame_embedding_mode": "text_only"
  }
}
```

If `include_frame_images` is true, include `image_base64` and `mime_type` on up to the requested frames. The backend may generate frame embeddings and then discards raw image bytes before storage. In `text_only`, image bytes should not be uploaded.

Manual/database search uses the same search code path as the Gemini Live `search_rewinds` tool:

```http
POST /v1/rewinds/search
```

```json
{
  "query": "where is my pen",
  "limit": 10,
  "entities": ["pen"],
  "time_range": {
    "started_after": "2026-06-06T00:00:00.000Z"
  }
}
```

It returns the same `query`, `filters`, and `results` shape as `rewind.search_results`.

## Non-Docker Development

The older local Node runner is still available for quick code iteration:

```bash
npm run dev:local
npm run dev:remote
npm run web
```

## Supabase

The CLI may be linked to a hosted Supabase project, but do not push, migrate, or query remote Supabase unless explicitly requested.

Local Supabase:

```bash
npm run supabase:start
supabase status -o env
```

For Docker local mode you do not need to copy these values; `npm run docker:local` reads them automatically and injects container-safe values into the backend container. For manual non-Docker runs, copy the printed local URL and service-role key into `.env.backend`.

Apply migrations locally:

```bash
npm run supabase:reset
```

Push to the linked hosted project only when explicitly requested:

```bash
npm run supabase:push
```

The repo keeps the DB setup in one squashed initial migration:

- `20260606130000_init_rewind_schema.sql`

The search setup uses `extensions.vector(768)`, cosine HNSW indexes on event and frame embeddings, trigger-maintained `search_tsv`, GIN indexes for full-text/entities, and time/device helper indexes. The RPC pulls event-vector, frame-vector, text, and recent candidates separately, applies filters first, then merges scores so semantic search and database-style search both stay usable.

The vector search path follows current pgvector/Supabase guidance for this scale:

- HNSW is the default ANN index for low-latency, high-recall reads.
- `vector_cosine_ops` matches Gemini embeddings and the backend normalizes vectors before storage.
- `hnsw.ef_search=100`, `hnsw.iterative_scan=strict_order`, and larger scan guardrails are set inside the search RPC so filtered user/status queries can recover enough candidates.
- Search fetches more candidates than the final limit, then hybrid-ranks semantic similarity plus full-text rank.
- Search applies a DB-side relevance gate before returning results. Pure vector-only matches need a cosine similarity of at least `0.64`; searches with an explicit time filter can use `0.56`; exact full-text, entity, or location evidence can pass without relying on vague semantic similarity alone.
- Recency is a tie-breaker inside relevance buckets, not part of the embedding and not a global boost.
- Relative date search is resolved outside embeddings. `today`, `yesterday`, `this week`, `last week`, `this month`, `last month`, and `last N days/weeks/months` become explicit UTC time ranges using the client timezone.

Local Supabase uses the same migrations. Run Docker/OrbStack first, then:

```bash
npm run supabase:start
npm run supabase:reset
supabase status -o env
```

Copy the local service-role key into `.env.backend` for manual non-Docker runs.

Because `.env.backend` is loaded as the backend source of truth, edit `.env.backend` directly for persistent backend settings. Edit `.env.web` for phone app settings such as `BACKEND_URL`.

## Model Key

Set these in `.env.backend`:

```bash
MODEL_API_KEY=...
EMBEDDING_MODE=text_only
TEXT_EMBEDDING_MODEL=gemini-embedding-2
IMAGE_EMBEDDING_MODEL=gemini-embedding-2
LIVE_MODEL_NAME=gemini-2.5-flash-native-audio-preview-12-2025
```

`MODEL_API_KEY` is required for Live sessions and embeddings. `EMBEDDING_MODE` is the behavior switch: keep `text_only` for the cheapest path, or use `text_and_image` to index selected rewind frames too.

Model defaults are code constants for this MVP:

- `TEXT_EMBEDDING_MODEL=gemini-embedding-2`: current Gemini multimodal embedding default, used for rewind event text.
- `IMAGE_EMBEDDING_MODEL=gemini-embedding-2`: same embedding space for selected image frames in `text_and_image`.
- `EMBEDDING_DIMENSION=768`: smaller/faster pgvector index with good retrieval quality and lower storage than 1536/3072.
- `FRAME_EMBEDDING_MAX_PER_REWIND=12`: bounded indexing cost per rewind while preserving enough visual evidence for short captures.

The agent prompt is intentionally passive and optimized for a realtime voice loop:

- It uses short, explicit sections and two narrow tools only.
- Native audio sessions use Google Live `v1alpha` plus `proactivity.proactiveAudio=true`, so irrelevant background audio can be ignored.
- Gemini server-side activity detection stays enabled, with low media resolution and audio/video turn coverage so recent video context is available when speech is vague.
- The phone sends client time, timezone, and UTC offset during `session.hello`; the prompt uses that context for relative date phrases such as `today`, `this week`, and `last week`. Latitude/longitude is collected only after a `rewind.save_request`, then sent in the out-of-band commit upload.
- `create_rewind` is only emitted after explicit save/remember/capture/bookmark/log intent. The prompt accepts clear variants such as "do not let me forget this" or "record this for later", and generalizes across languages when the user directly asks to preserve the current context without listing non-English examples.
- Privacy is stricter than recall flexibility: ambient conversation, "look at this", "this is interesting", surprise, narration, or uncertain phrases should not create rewinds. Ambiguous save intent should stay passive or get a brief clarification.
- A save request must include `rewind_duration_seconds`, a concise title/description, and inferred `entities`; duration is bounded by `session.hello.buffers.rewind.duration_ms` and should be the explicit rolling-buffer duration the user asked for, or the smallest useful replay window ending at the current tool-call anchor. Historical calendar periods belong to search, not create.
- Vague phrases such as `remember where I put this` should resolve `this` from recent camera/audio context. Entities should include concrete visible objects, surfaces, containers, places, readable labels/text, and actions when useful for search.

## Embedding Modes

`EMBEDDING_MODE=text_only`:

- Embeds the rewind event text only.
- Uses title, description, inferred entities, and location hint.
- Phone uploads only frame IDs, timestamps, and purposeful commit metadata.
- Cheapest and best default.

`EMBEDDING_MODE=text_and_image`:

- Embeds the rewind event text.
- Also asks the phone simulator to include transient frame JPEG data in the out-of-band commit upload.
- Backend embeds up to 12 selected frame images with `gemini-embedding-2`. This cap is fixed in code for the hackathon MVP.
- Backend stores frame vectors plus frame IDs/timestamps/metadata. Raw image bytes are discarded before DB insert.
- Event embeddings remain event-level only: Live-inferred title, description, entities, and location. Frame embeddings are used as supporting evidence during retrieval.

Relevant env:

```bash
EMBEDDING_MODE=text_only
```

For frame embeddings:

```bash
EMBEDDING_MODE=text_and_image
```

This path intentionally uses Gemini API features that work with `MODEL_API_KEY`: image understanding through `generateContent`, then multimodal image+text frame embeddings through `gemini-embedding-2`. Google's separate Vertex multimodal embedding model is not used in this local MVP because it needs a different Vertex setup and dimensions.

The selected Live testing model is `gemini-2.5-flash-native-audio-preview-12-2025`. It is a native-audio Live model, so the backend configures audio response modality, output audio transcription, low media resolution, and manual tool handling. If `LIVE_MODEL_NAME` is changed to a non-native-audio Live model, the backend switches back to text response modality.

## Phone Camera Over LAN

Desktop browsers can use camera access on `localhost`. A phone connecting to your Mac over LAN usually needs HTTPS for `getUserMedia`.

Use `mkcert` or another local CA to create a trusted cert, then set:

```bash
WEB_HTTPS=true
WEB_TLS_CERT_PATH=certs/rewind.local.pem
WEB_TLS_KEY_PATH=certs/rewind.local-key.pem
```

For phone-over-LAN testing, set `WEB_HOST=0.0.0.0` and `BACKEND_URL` in `.env.web` to your backend LAN URL. Camera/mic access on a phone usually requires HTTPS for the web app, so set `WEB_HTTPS=true` plus `WEB_TLS_CERT_PATH` and `WEB_TLS_KEY_PATH` when using trusted local certs.

## Environment Notes

- `MODEL_API_KEY` is the only model secret.
- `.env.backend` contains backend secrets and database/model settings.
- `.env.web` contains browser-safe phone app settings only.
- `EMBEDDING_MODE=text_only` embeds stored rewind text only.
- `EMBEDDING_MODE=text_and_image` also asks the phone to include transient frame JPEGs for the fixed 12-frame indexing cap.
