# Repository Guidelines

- Keep this repo optimized for direct local app testing through the backend at `http://localhost:8787` and the separate phone simulator at `http://localhost:8788/phone.html`.
- Do not add automated tests, smoke tests, test runners, or test scripts unless explicitly requested.
- When validating changes, prefer `npm run typecheck`, `/health`, container status, and direct manual use of the running prototype.
- Keep setup simple for the hackathon MVP: real Gemini-backed behavior only, no mock agent or mock embedding fallback.
