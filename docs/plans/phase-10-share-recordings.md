---
type: "plan"
phase: 10
status: "done"
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
| 2 | `ResoniqShare`: client, queue, preference, shared manifest, tests with a stub transport | Kit | Opus | done |
| 3 | App: Settings section, consent screen, wiring to kept tests, privacy manifest, the changed privacy sentences | App | Opus | done |
| 4 | Review; CLAUDE.md, ARCHITECTURE, module notes, device checklist | — | Fable | done: see "Review" below |

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

Tasks 2 and 3 (the Kit module and the app), as built:

**The shared manifest, field by field** (`RecordingManifest.shared()`; `SharedManifestTests` lists every stored field
by reflection and fails when one is added, so each new field gets decided here):

| Field | Shared | Why |
|---|---|---|
| `schemaVersion`, `kind` | Kept | Needed to read the file; say nothing about anyone |
| `createdAt` | The day only | The calendar day where the person is, written as midnight UTC: no time of day, and no time zone (which would hint at where they live). The day is kept to order a dataset and to see a change of app version |
| `sampleRate`, `playback` | Kept | Measurement |
| `device.model` | Kept | The hardware identifier (`iPhone18,2`): its microphone is what the thresholds are tuned for. Millions of phones share it. The device's given name is never read anywhere in the app |
| `device.systemName`, `systemVersion`, `appVersion` | Kept | The audio stack and the analysis that made the report |
| `audioRoute.output`, `.input` | Kind only | The kind (AirPlay, Bluetooth, built-in microphone…) changes the measurement; the name ("Anna's AirPods", "Living Room") can hold a person's or a device's name |
| `speaker.position`, `.channel` | Kept | Measurement |
| `speaker.make`, `.model`, `.unitID` | Left out | Never written yet; free text or a serial once they are. To be decided when something writes them |
| `system.name` | Left out | Typed by the person |
| `system.kind` | Kept | Stereo pair, soundbar…: part of the measurement |
| `room` | Left out | Its only field is the name the person typed |
| `sweep`, `noiseFloor`, `runs` | Kept | The measurement itself: parameters, file names (`run-1.wav`), sample counts, delays, checks, splices, phone movement, clock ratios |
| `report` | Kept | Made from the runs alone (`SpeakerDiagnosis` takes no names); the test checks the encoded report holds no name |
| `label.value`, `.how`, `.confidence` | Kept | What a label says (never written yet) |
| `label.givenBy` | Left out | A person |

The folder's name (`2026-11-14_153012_left_…`) holds the time of day, so it is never sent: each queued test gets a
fresh random 32-hex `exampleId`, kept in the queue's state.

**Requests the app makes, and when.** None in a build without `RESONIQ_SHARE_URL`: `ShareSetup` returns nil and
no transport exists. With it and sharing off: none (`ShareQueueTests` runs every entry point against a transport
that fails the test on any call, and a mutation that drops the consent check makes it fail). With sharing on: when
a kept test's recording is on disk, `POST /v1/installs` if no installation is kept, then `PUT manifest.json`,
`noise-floor.wav`, `run-1.wav` … one file at a time; the same at launch and on each return to the foreground for
what is due; `DELETE /v1/installs/<id>` on "Delete what I shared", only if an installation is kept.

**What differs from the plan, and the choices made:**

- **Foreground uploads, not a background session.** A background `URLSession` needs app-delegate wiring
  (`handleEventsForBackgroundURLSession`) and delegate callbacks, and a kept test is a few megabytes, seconds on
  Wi-Fi. The person keeps a test, the result is on screen, and the upload runs while they read it. If they close
  the app first, the upload stops and is tried again the next time Resoniq opens (or comes back to the
  foreground). Nothing is said outside Settings.
- **`waitsForConnectivity` is false.** With no Wi-Fi a request fails at once and the test waits for its backoff,
  rather than holding a task open for minutes.
- **Retries happen at moments, not on a timer**: launch, return to the foreground, and each kept test. A failed
  test waits 1 minute, doubling to 6 hours (first guess), or the service's `Retry-After` if longer.
- **"Delete what I shared" clears the whole queue**, waiting tests included, not only the sent list: after a delete
  nothing kept before goes again unless the person asks ("Send the recordings I already have"). Sharing itself is
  left as it was. It may use cellular (the only request that may): someone who wants their recordings gone should
  not need Wi-Fi.
- **A 401 or 404 on upload** forgets the installation, registers once, and sends that example whole again (what it
  had stored went with the old installation); refused again, the queue stops until sharing is turned on again or
  the person deletes. The Worker answers 401 for an installation deleted on the service.
- **A file over 4 MB** (inclusive limit, from the Worker) is never sent; that test is marked refused, the others go
  on. So are 413 and 400.
- **Consent has a version** (`SharePreference.currentConsentVersion`, 1): when the consent words change, raising it
  turns sharing off until the person confirms again.
- **The consent screen's confirming button** is the design system's primary pill at the foot of the sheet
  ("Share"), with Cancel at the top leading corner as a sheet's bar has it (HIG). A top-trailing text link would be
  the HIG's other placement; the design system has one primary action per screen, and this is it.
- **The queue's state** is `Documents/.share-queue.json` (hidden from Files, excluded from backup): folder names,
  example ids, sent files, attempts. No token: the token and installation id are one Keychain item, this device
  only, which survives deleting the app so a reinstall can still delete what was shared.
- **Debug-only local networking**: `Info.plist` is preprocessed (`INFOPLIST_PREPROCESS`), and an
  `#if RESONIQ_LOCAL_NETWORKING` block adds `NSAllowsLocalNetworking`; the definition is set for Debug only. The
  built Release `Info.plist` was checked: no `NSAppTransportSecurity` key. `ShareConfiguration` refuses http to
  any host but `localhost` and `127.0.0.1`.
- **Privacy sentences changed**: Settings' privacy line and the Keep recordings sentence (both say "unless you turn
  on sharing below" only in a build that has sharing), the microphone permission string, the Aim screen's footer,
  the Diagnose "microphone denied" text ("stays on this iPhone unless you choose to share your recordings"), and the
  store-unavailable screen ("Your results are kept on this phone", instead of "Everything stays"). Left as they were,
  because they stay true: the camera string (scans never leave), the live spectrum's and the seat measurement's
  microphone texts (those are never shared).
- **Privacy manifest**: `NSPrivacyCollectedDataTypeAudioData` and `NSPrivacyCollectedDataTypeOtherDiagnosticData`,
  each `Linked` false, `Tracking` false, purposes `AppFunctionality` and `Other` (Apple's list has no "product
  improvement"; tuning the measurements is improving a feature, the research dataset is "other"). The random
  installation id is not declared as a data type: it identifies an installation's uploads, not a person or a
  device. The owner may prefer to declare it.
- **No schema migration.** The manifest's route, system and room names became optional; the JSON on disk is the same.

**First guesses**: the backoff (1 min to 6 h), the request timeout (60 s) and resource timeout (10 min), the consent
words, the status sentences.

**Not verified**: the real Worker (the reviewer's `wrangler dev` run), a phone, real Wi-Fi and cellular, what
iOS does to a foreground upload when the app is suspended, the Keychain store (it has no Mac test), VoiceOver on
the new rows and sheet, the largest text sizes on the consent sheet.

## Review

**Run end to end against the local Worker (2026-11-14).** With `RESONIQ_SHARE_URL` pointing at `wrangler dev`, a
simulated speaker test kept in the simulator with sharing on arrived whole: `POST /v1/installs`, then
`manifest.json`, `noise-floor.wav` and `run-1…3.wav`, each 200. The stored manifest held no name: the routes as a
kind only, the day at midnight UTC, the device as `iPhone18,1`. `LocalWorkerTests` (opt-in, `RESONIQ_SHARE_LOCAL_URL`)
runs the real client and transport against the same Worker: register, upload, a forged token refused with 401,
delete, and the token dead afterwards.

**Found by that run.** An app with no code signature (what `make build` makes for the simulator) cannot write to
the data-protection Keychain, so the token could not be kept. The queue then reported a service error and made a
new installation on every retry, leaving one behind each time. Now the installation is deleted again while its
token is in hand, the queue stops with `tokenNotKept`, and Settings says so. To see sharing work in the simulator
the app must be signed (`CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`); on a phone it always is.

**Found by the security review of the Worker's commits.** The quota is counted again after a write; an IPv6
address counts as its /64; counter writes are conditional on the etag; the limit for everyone is spread over
eight counters and fails closed.

**Not run.** "Delete what I shared" from the app's own button (the simulator could not be tapped without
installing a tool); the deployed Worker; a phone; Wi-Fi against mobile data.

## Open for the owner

- The consent text and the Settings section have no mockup.
- Who may use it: this phase leaves it off in every build that has no `RESONIQ_SHARE_URL`, so only the owner's
  builds can share until that changes.
- A privacy policy page is needed before the feature ships to anyone else.
