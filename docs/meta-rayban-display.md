# Meta Ray-Ban Display Prototype

This project targets the Meta Ray-Ban Display Web Apps path for the MVP glasses experience. The native iOS Display SDK path is useful later, but the web path lets us keep the hackathon prototype simple: one local backend, one phone simulator, one glasses display simulator, and the same cached frame references.

## Current Platform Notes

- Meta's Device Access Toolkit v0.7 announcement says Display support is in developer preview and can render images, text, videos, and buttons on Meta Ray-Ban Display glasses.
- Meta's Web Apps toolkit describes Meta Ray-Ban Display Web Apps as standard HTML, CSS, and JavaScript rendered on the glasses.
- The Web Apps constraints are a 600x600 viewport, D-pad/EMG navigation through arrow-key style focus, no touch input, dark high-contrast UI, and reachable `.focusable` elements.
- On real glasses, a web app must be hosted at a publicly available HTTPS URL, then added in the Meta AI app under Display Glasses settings -> App connections -> Web apps.

Primary references:

- https://github.com/facebook/meta-wearables-dat-ios/discussions/178
- https://github.com/facebook/meta-wearables-dat-ios
- https://github.com/facebookincubator/meta-wearables-webapp

## Repository Layout

```txt
apps/glasses/  Meta Ray-Ban Display web UI
apps/web/      Browser phone simulator and local phone frame cache UI
```

The glasses UI lives in `apps/glasses/public/glasses.html`. The shared browser result/frame compiler lives in `apps/glasses/public/rewind-frame-cache.js`; the phone simulator loads that same helper so phone and glasses playback compile result frames consistently.

## UX Scope

The glasses do not show a camera stream. The user already sees the world through the lenses.

The display only shows:

1. Source text returned by the agent/search flow.
2. The top ranked memory.
3. A moving playback of local cached phone frames for that top memory.

The page background is black on purpose. On the additive glasses display, black pixels read as transparent, so the UI should behave like a floating HUD: minimal luminous text, small translucent backplates only where readability needs them, and cached frames placed directly onto the transparent display plane.

When the phone simulator receives live `agent.media`, `rewind.search_started`, or `rewind.search_results` messages, it broadcasts them to the glasses simulator through `BroadcastChannel`. Manual search in `glasses.html` uses the same `POST /v1/rewinds/search` backend endpoint as the phone search box.

## Local Run

Start the backend:

```bash
npm run docker:backend
```

Start the browser app server:

```bash
npm run web
```

Open both:

```txt
http://localhost:8788/phone.html
http://localhost:8788/glasses.html
http://localhost:8788/glasses-sim.html
```

Recommended local flow:

1. Open `phone.html` and click `Start Streaming`.
2. Save a memory by voice, for example `remember where I left this pen`.
3. Open `glasses-sim.html` to see the HUD blended over a simulated world view, or `glasses.html` to inspect the raw 600x600 display surface.
4. Search by voice on the phone, or type a query in the glasses simulator.
5. The glasses display should show source text, the top result, and animated cached frames.

Use arrow keys and Enter in `glasses.html` to approximate the Meta Ray-Ban Display D-pad/EMG navigation model.

`glasses-sim.html` loads `glasses.html` in an iframe and applies `mix-blend-mode: screen`, which makes the black HUD background disappear over the world layer. Its optional camera button lets you preview the overlay over your webcam feed without requesting camera access on page load.

## Real Glasses Notes

Localhost is only for desktop browser testing. For real Meta Ray-Ban Display testing, host the glasses app at a public HTTPS URL and add that URL through the Meta AI app's Web apps flow. Keep the Rewind backend reachable from that hosted app, and do not expose local service-role keys or `.env` files.
