# Repository Guidelines

- Keep this repo optimized for direct local app testing through the backend at `http://localhost:8787` and the separate phone simulator at `http://localhost:8788/phone.html`.
- Do not add automated tests, smoke tests, test runners, or test scripts unless explicitly requested.
- When validating changes, prefer `npm run typecheck`, `/health`, container status, and direct manual use of the running prototype.
- Keep setup simple for the hackathon MVP: real Gemini-backed behavior only, no mock agent or mock embedding fallback.
- Backend persistence must be Supabase only. Local development means the Supabase CLI local stack with pgvector, not JSON/file-backed persistence.
- Do not create, deploy, or modify Supabase Edge Functions for this project unless the user explicitly asks for Edge Functions. The current architecture is the local/backend API plus Supabase tables/RPC only.
- Do not probe, query, migrate, push to, deploy to, or otherwise touch the remote Supabase project unless the user explicitly asks for remote database work. Default validation should run locally.
