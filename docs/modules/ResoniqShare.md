---
type: "module"
spec_module: "share"
phase: 10
status: "active"
tags:
  - "module"
---
# ResoniqShare

The opt-in sharing of kept recordings ("Share recordings for research"): the client of the owner's service, the queue of kept tests waiting to go, the person's choice, and the one `URLSession` in the repository. It is the **only module that may use the network**; `NetworkUseTests` reads every other Kit module and the app and fails on any networking API. Depends on `ResoniqStore` (the recordings on disk and `RecordingManifest.shared()`). Plan: [phase-10-share-recordings.md](../plans/phase-10-share-recordings.md); the service is `cloud/share-worker/`.

Paths are relative to `ResoniqKit/Sources/ResoniqShare/`.

## Conventions

- **Nothing without consent, by structure.** A build with no usable `RESONIQ_SHARE_URL` gets nil from `ShareConfiguration` and `ShareSetup.queue`, so no transport, credentials or queue exist. With one, the queue reads `isAllowed` (the live `SharePreference.isOn`) before every request; `kept(_:)` and `queueExisting()` do nothing while it is off; `stop()` cancels the request in flight.
- **Requests are values.** `ShareClient` builds `ShareRequest`s (method, URL, `Authorization` and `Content-Type` only, body, whether a cellular network is allowed); a `ShareTransport` sends them. Tests read the requests a stub received.
- **The contract** (`docs/plans/phase-10-share-recordings.md`, "The service", and the Worker's notes): `POST /v1/installs`, `PUT /v1/installs/<installId>/examples/<exampleId>/<file>` with the bearer token, `DELETE /v1/installs/<installId>` with the token. Any 2xx is success (the Worker answers 200); a 404 on delete counts as deleted. Names are checked before a request (`isExampleID`, `isFileName`).
- **The example id** is 32 random hex digits made when a test is queued (`newExampleID()`), kept in the queue's state; never the folder's name, which holds the time of day.
- **Wi-Fi only** for registration and uploads; only `DELETE` may use cellular or Low Data Mode (`allowsExpensiveNetwork`).
- **Foreground uploads.** No background session: uploads run while the app is open; one cut off is sent again at the next launch or return to the foreground.
- **Failures** wait `retryDelay(afterAttempts:)` (1 min doubling to 6 h), or the service's `Retry-After` if longer; a drain ends at the first failure. 401/404 on upload: forget the installation, register once, send the example whole again; refused again: stop (`ShareProblem.rejected`). 507: stop (`overQuota`). A token the device cannot keep (the Keychain refuses it, as it does for an unsigned simulator build): the new installation is deleted again while the token is in hand and the queue stops (`tokenNotKept`), so a retry never leaves an installation behind. 413, 400, or a file over 4 MB before sending: that test is `refused`, the others go on. A stop is lifted by "Delete what I shared" or by turning sharing on again.

## Public interface

| Symbol | Where | Holds |
|---|---|---|
| `ShareConfiguration` | `ShareConfiguration.swift` | `init?(baseURLString:)`: https with a host, or http to `localhost`/`127.0.0.1`; nil for empty, blank, an unexpanded `$(…)`, a query, credentials or another scheme. `infoKey` `ResoniqShareURL`, `main(bundle:)` |
| `ShareSetup.queue(configuration:recordings:transport:credentials:isAllowed:)` | `ShareSetup.swift` | The queue, or nil before the transport and credentials closures are called |
| `ShareRequest`, `ShareResponse`, `ShareTransport`, `ShareTransportFailure` | `ShareTransport.swift` | The request as values (`Method`, `Body` `.none`/`.data`/`.file`), the answer (status, body, `retryAfter`), the protocol, "no answer" |
| `ShareClient` | `ShareClient.swift` | `register()`, `upload(_:file:example:installation:)`, `delete(_:)`, all `throws(ShareError)`; `maximumFileSize` (4 MB, inclusive), `isExampleID`, `isFileName`, `newExampleID()` |
| `ShareError` | `ShareClient.swift` | `badName` 400, `unauthorized` 401, `notFound` 404, `tooLarge` 413, `rateLimited(retryAfter:)` 429, `overQuota` 507, `server(status:)`, `unreachable`, `badResponse`, `cancelled` |
| `ShareInstallation` | `ShareClient.swift` | `installId` (32 hex), `token` (64 hex) |
| `ShareCredentialStore`, `KeychainShareCredentials`, `MemoryShareCredentials` | `ShareCredentials.swift` | `load`, `save`, `delete`. The Keychain item: generic password, service `com.matovic.resoniq.share`, the id and token together as JSON, after first unlock, this device only, not synchronizable (it outlives the app's deletion, so "Delete what I shared" still works after a reinstall) |
| `SharePreference` | `SharePreference.swift` | `isOn` (the flag and `currentConsentVersion` both), `consent` (date, version), `turnOn(consentedAt:)`, `turnOff()`; keys `shareRecordings`, `shareRecordings.consentDate`, `shareRecordings.consentVersion`. Reading writes nothing |
| `ShareQueue` (actor) | `ShareQueue.swift` | `kept(_:)`, `queueExisting()`, `forget(_:)`, `forgetMissing()`, `start()`, `send()`, `sharingTurnedOn()`, `stop()`, `deleteShared()`, `status()`, `updates` (an `AsyncStream<ShareStatus>`); `stateFile(for:)` (`<Documents>/.share-queue.json`), `retryDelay(afterAttempts:)` |
| `ShareStatus`, `ShareProblem` | `ShareQueue.swift` | sent, waiting, refused, not queued, the last problem (`unreachable`, `serviceError`, `overQuota`, `rejected`, `refused`, `tokenNotKept`) |
| `HTTPShareTransport` | `HTTPShareTransport.swift` | Two ephemeral sessions (Wi-Fi only; any network for delete): no cookies, cache or credential store, `waitsForConnectivity` false, TLS 1.2+, fixed headers `User-Agent: Resoniq`, `Accept: application/json`, `Accept-Language: en`; `.file` bodies through `upload(for:fromFile:)` |

## What one kept test sends

In order, after a `POST /v1/installs` if no installation is kept: `manifest.json` (`RecordingManifest.shared()` of the manifest on disk, see [ResoniqStore](ResoniqStore.md)), `noise-floor.wav`, `run-1.wav` … `run-N.wav`, each a `PUT` with `Authorization: Bearer <token>` and `Content-Type` `application/json` or `audio/wav`.

## Tests

`ResoniqKit/Tests/ResoniqShareTests/`, 55 tests, about a second.

- `ShareQueueTests`: with sharing off, keeping, launching, asking for the old ones and turning on never reach a transport that fails the test on any call; with no URL, no queue, and the transport and credentials closures are never called; with sharing on, exactly `POST` then the five `PUT`s, the token and nothing else, no folder name in any URL; the manifest sent is the shared one and the audio the files on disk; old recordings only when asked; sharing off mid-example stops before the next request and resumes from the next file; `stop()` cancels a request in flight without counting a failure; forget and missing folders; a test discarded while registering is not sent; backoff and `Retry-After`; 401 and 404 re-register once then stop; a new installation resends the example whole; 507 stops and is not retried; 413 and a file over 4 MB refuse only that test; delete, delete with nothing, a failed delete changes nothing, delete lifts a stop; the state survives a relaunch and holds no token.
- `ShareClientTests`, `ShareConfigurationTests`, `SharePreferenceTests`, `MemoryCredentialsTests`: each request against the contract, status mapping, names refused before a request, malformed registrations, URLs, the preference off by default and side-effect free, a consent to older words not counting.
- `HTTPShareTransportTests`: the real `URLSession` transport against `StubService` (a `URLProtocol`): configuration, headers, a 300 kB body streamed from a file, statuses, no connection, the whole queue end to end.
- `NetworkUseTests`: no other Kit module and no app file names `URLSession`, `URLRequest`, `URLProtocol`, `Network`, `WebKit` and the like; the app names `HTTPShareTransport` only in its composition.

## Limits

- `KeychainShareCredentials` has no test on the Mac (it would need the data-protection keychain and an entitlement); it is used only on the phone.
- Against the real Worker: not run here; the reviewer's `wrangler dev` run and the owner's deployment are the checks.
- No App Attest: the token stops one installation writing another's folder; it does not prove a request comes from the app.
- What a discarded test had already stored stays on the service until "Delete what I shared" (the contract has no per-example delete).
