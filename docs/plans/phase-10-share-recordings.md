---
type: "plan"
phase: 10
status: "in progress"
tags:
  - "plan/phase-10"
---
# Phase 10 · Sharing recordings for research

Goal: a person who chooses to can send the raw recordings of the speaker tests they keep to the owner's storage,
so they can be used for research and for tuning the thresholds. It is off until they turn it on, they can turn it
off again, and they can delete what they sent.

**This is the first network code in the app.** The owner decided it on 2026-11-14: Cloudflare R2 for storage,
opt-in. The rule "Offline and private" in [CLAUDE.md](../../CLAUDE.md) changes with this phase to name the one
exception. Everything else stays on the device, and with sharing off the app makes no network request at all.

## What is sent, and what is not

| Sent | Not sent |
|---|---|
| Each run's recording and the noise-floor recording of a kept speaker test (the files phase 9 writes) | Anything from a test that was not kept, a quick check, a seat measurement, a room scan |
| A manifest: sweep, delays, each run's check, splices, phone movement, the report, sample rate, date (day only), device model, iOS version, app version, the kind of audio route, speaker position, system kind | The names the person typed (room, system), the route's name (it can hold a person's or a device's name), the time of day, anything that identifies the person or the phone |
| A random identifier made for this installation, so its uploads can be found and deleted | An Apple identifier, an account, an advertising or vendor identifier, location |

The recordings can hold voices: the room is recorded while the sweep plays and before it. The consent screen says
so in plain words.

## The service

A Cloudflare Worker in front of one R2 bucket, in `cloud/share-worker/`. No third-party code runs in the app: the
app speaks HTTPS with `URLSession`.

| Request | Does |
|---|---|
| `POST /v1/installs` | Makes an installation: returns `{ "installId": "<32 hex>", "token": "<64 hex>" }`. The bucket keeps only a SHA-256 of the token, at `installs/<installId>.json` |
| `PUT /v1/installs/<installId>/examples/<exampleId>/<file>` with `Authorization: Bearer <token>` | Stores one file at `examples/<installId>/<exampleId>/<file>`. `exampleId` is 8 to 64 characters of `[A-Za-z0-9_-]`; `file` is `manifest.json`, `noise-floor.wav` or `run-<1…9>.wav`; a body over 4 MB is refused (413), as is an installation over 300 MB in all (507) |
| `DELETE /v1/installs/<installId>` with the token | Deletes every object of the installation and the installation itself |
| `GET /v1/health` | `{ "ok": true }` |

Errors are JSON `{ "error": "<code>" }` with 400 (bad name), 401 (no or wrong token), 404, 413, 429, 507. Nothing
can be read back through the Worker: the owner reads the bucket with their own Cloudflare credentials.

Limits against abuse, all first guesses: 4 MB a file, 300 MB an installation, and a rate limit on making
installations. The token stops one installation writing into another's folder; it does not prove the request comes
from the app. App Attest would, and is left for when the feature is opened to everyone.

## Who decides what

| Decision | Module | Symbol (contract) |
|---|---|---|
| What a shared manifest holds | `ResoniqStore` | `RecordingManifest.shared()`: the manifest with the names, the route names and the time of day removed |
| Talking to the service | `ResoniqShare` (new Kit module, the only one that may import networking) | `ShareClient` over a `ShareTransport` protocol (`URLSession` in the app, a stub in tests): register, upload a file, delete everything |
| What is waiting to go, and what has gone | `ResoniqShare` | `ShareQueue`: kept examples not yet sent, sent ones, failures to retry; state kept in a small file beside the recordings; only over Wi-Fi (`allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` false) |
| The choice | `ResoniqShare` | `SharePreference`: off by default; turning it on records the consent's date and version; turning it off stops uploads and sends nothing more |
| Where the service is | App | The base URL from the build setting `RESONIQ_SHARE_URL` (in the untracked local xcconfig). Empty means the feature does not exist in that build: no row in Settings, no request |

Rules:

- Sharing needs "Keep recordings" on; turning sharing on turns it on, and says so.
- Nothing is uploaded for a test made before consent unless the person asks ("Send the recordings I already have").
- "Delete what I shared" deletes on the service and forgets the installation; it works with sharing off.
- A failed upload is retried later and never blocks or delays a result; the person is told only in Settings.
- With sharing off or the URL empty, the app opens no connection. A test proves it: the transport is never called.

## Tasks

| # | Task | Module | Model | Status |
|---|---|---|---|---|
| 1 | The Worker, its tests, `wrangler.toml`, and a README with the owner's steps to deploy it | cloud | Sonnet | done |
| 2 | `ResoniqShare`: client, queue, preference, shared manifest, tests with a stub transport | Kit | Opus | todo |
| 3 | App: Settings section, consent screen, wiring to kept tests, privacy manifest, the changed privacy sentences | App | Opus | todo |
| 4 | Review; CLAUDE.md, ARCHITECTURE, module notes, device checklist | — | Fable | todo |

Done when: `make test` and `make build` pass, the Worker's tests pass, and with a local Worker (`wrangler dev`) a
kept test from the simulator arrives in the local bucket and "Delete what I shared" removes it. The deployed
service, a real phone and real Wi-Fi are checked by the owner.

## Notes

Task 1 (the Worker), as built in `cloud/share-worker/`:

- Success answers are `200` with `{ "ok": true }` (PUT, DELETE) or `{ "installId", "token" }` (POST); the contract
  names no success codes. An empty body is refused with 400 `empty_body`; the contract is silent on it.
- Quota is computed by listing the installation's objects on each upload, not kept as a running total, and counted
  again after the write (the file is removed if the installation is now over): uploads that arrive together cannot
  all pass a check made before any was stored. Cost: two Class A lists per 1000 objects. Found by the security
  review of the first commit.
- Registration rate limit: 10 an hour per address, a small counter object in R2 (`ratelimit/<hash>.json`), because
  the Workers Rate Limiting binding is in open beta and Cloudflare's pages do not say it is free. First guess. After
  the security review: an IPv6 address counts as its /64, counter writes are conditional on the etag and retried
  (a burst of parallel registrations is counted), and 500 installations a day are allowed from everyone together.
- Local use: `npx wrangler dev --port 8787 --var RATE_LIMIT_MAX:1000` (a local server sees one address, so the
  default limit of 10 would refuse the eleventh test registration). Base URL `http://localhost:8787`.
- Not verified: a real deployment, R2 behaviour on Cloudflare's side (tests and `wrangler dev` use the local
  simulation), and the free-plan 10 ms CPU limit under a 4 MB upload.

## Open for the owner

- The consent text and the Settings section have no mockup.
- Who may use it: this phase leaves it off in every build that has no `RESONIQ_SHARE_URL`, so only the owner's
  builds can share until that changes.
- A privacy policy page is needed before the feature ships to anyone else.
