---
type: "reference"
tags:
  - "reference/iosar"
---

# RoomPlan and ARKit lessons from iosar (RoomScan)

Distilled for Resoniq phases (a) guided RoomPlan scan, (b) 2D/3D room view with draggable speakers and seat, (c) ARKit/RealityKit placement guidance with persistence, (d) local scan storage. All paths are `iosar: <path>`, relative to `/Users/matovicm/Projects/iosar`. Everything below was read in the code or docs unless marked "inferred" or "not determined". Line numbers are as of the iosar working tree on 2026-11-13 and will drift.

iosar is a Serbian-language internal tool for one device (iPhone 17 Pro Max); it assumes LiDAR and has no non-LiDAR fallback. Its RealityKit use is a single overlay; it has no ARAnchor persistence. Where Resoniq needs those, iosar gives principles, not code.

## 1. File map

### (a) Guided RoomPlan scan, CapturedRoom to own model

- `iosar: RoomScan/Capture/RoomCaptureFlow.swift`
  - `RoomCaptureFlow` (line 10): `UIViewControllerRepresentable` with `finishRequested` / `cancelRequested` bindings.
  - `RoomCaptureHostController` (59): builds `RoomCaptureView(frame: .zero, arSession: hub.session)` (123), runs `captureView.captureSession.run(configuration:)` with `isCoachingEnabled = true` in `viewDidAppear` (165-176), `stopScanning()` (297) ends the scan.
  - Header comment (6-8): RoomPlan gives UI and coaching but no Done button; stopping the session is what triggers processing.
- `iosar: RoomScan/Capture/CaptureCoordinator.swift`
  - `CaptureCoordinator` (65), a `@MainActor` `NSObject` and `RoomCaptureViewDelegate` (needs `NSCoding` stubs, 89-90).
  - `captureView(shouldPresent:error:)` (94) returns false when cancelled or errored, which skips processing.
  - `captureView(didPresent:error:)` (98) guards against a second call, maps errors and an empty scan, and builds `CaptureOutcome`.
  - `CaptureFailure` (28-56): error mapping for `RoomCaptureSession.CaptureError` (`exceedSceneSizeLimit`, `worldTrackingFailure`, `invalidARConfiguration`, `deviceTooHot`, `deviceNotSupported`, `internalError`) plus `emptyScan`.
  - `exportUSDZ` closure (128-130) uses `processedResult.export(to:exportOptions: .mesh)`; `encodeCapture` closure (131-133) uses `JSONEncoder().encode(processedResult)`.
- `iosar: RoomScanKit/Sources/RoomScanKit/Domain/CapturedRoomAdapter.swift`: `CapturedRoomAdapter.map(_:)` turns `CapturedRoom` into `RoomGeometry`. It has no measurement logic and is wrapped in `#if canImport(RoomPlan)`.
- `iosar: RoomScanKit/Sources/RoomScanKit/Domain/SurfaceMapping.swift`: primitive-typed helpers (`widen` float4x4 to double4x4, `makeSurface`, `confidence(fromRaw:)`). It has no RoomPlan types, so it is unit-testable.
- `iosar: RoomScanKit/Sources/RoomScanKit/Domain/RoomGeometry.swift`: `RoomGeometry` with `Surface` and `Object`, `SurfaceKind`, `SurfaceConfidence`, `SurfaceEdge`, `SurfaceCurve`. `Sendable`, not `Codable`.
- `iosar: RoomScanKit/Sources/RoomScanKit/Domain/DimensionCalculator.swift`: `compute(_:)` (11) gives floor area (polygon first, perimeter-square fallback flagged by `floorAreaSource`), median wall height, perimeter, room-aligned bounding box (`floorExtent`, 165), per-wall run (`runLength`, 133), opening counts, quality flags.
- `iosar: RoomScanKit/Sources/RoomScanKit/Domain/Geometry.swift`: `worldCorners` (8), `shoelaceArea`, `polygonPerimeter`, `containsXZ` (point-in-polygon with tolerance), `distanceToSegmentXZ`. These are useful for distance-to-wall readouts.
- `iosar: RoomScanKit/Sources/RoomScanKit/Export/SceneNormalizer.swift`: `SceneNormalizer.frame(for:)` (28), the room-anchored frame. See section 2.
- `iosar: RoomScanKit/Sources/RoomScanKit/Rescan/RoomLayoutRefinement.swift`: `isComplete` / `closures` and the 5 cm `cornerJoinM` rule that decides whether a wall end is closed. This is the one decision for "is this room a closed loop"; worth reading before computing room dimensions from partial scans.
- `iosar: RoomScan/Capture/DeviceCapabilityProbe.swift` (14) and `iosar: RoomScan/RoomScanApp.swift` (68): capability checks, see section 2.
- `iosar: RoomScan/Features/FirstRunView.swift` (168, 252): camera permission request.

### (b) 2D plan and 3D view

- `iosar: RoomScanKit/Sources/RoomScanKit/Review/ScanReview.swift`: `FloorPlan` and `PlanObject` (248-269), `floorPlan(of:)` (274). Produces a plan in scene metres (x right, y = scene z): floor outline (or joined wall segments), opening segments along their walls, RoomPlan boxes with `yaw = atan2(-m[2], m[0])`.
- `iosar: RoomScan/Features/FloorPlanView.swift`: SwiftUI `Canvas` plan; `PlanLayout` (about 143) maps plan metres to view points, centred and scaled to fit; objects drawn with rotation about their centre. Starting point for the 2D view, not a drag UI.
- `iosar: RoomScan/Features/MeshPreviewSceneBuilder.swift` and `iosar: RoomScan/Features/MeshPreviewView.swift`: SceneKit 3D scene with a `MeshPreviewCamera` framed from the content's bounding sphere, so gesture limits scale with room size. iosar uses SceneKit here, not RealityKit.
- No drag-to-place code and no distance-to-wall readout exist in iosar. Inferred: `Geometry.distanceToSegmentXZ` over wall segments from `ScanReview.floorPlan` is the cheap route.

### (c) ARKit and RealityKit guidance, persistence

- `iosar: RoomScan/Capture/ARFrameHub.swift`: `ARFrameHub` (33) owns the one `ARSession`, is its delegate on a dedicated serial queue, fans out frame and mesh observers, exposes `isDelivering`, `verifyDelegate` (139), `setAttemptsRelocalization`, `setInterruptionHandler`.
- `iosar: RoomScan/Capture/SessionDelegateProxy.swift` (26): forwarding proxy in front of RoomPlan's session delegate. Documents why it is off by default.
- `iosar: RoomScan/Capture/WorldMapSaver.swift`: `save(into:timeout:)` (53), `currentWorldMap(of:)` (143, continuation wrapper over `getCurrentWorldMap`), `archive` (157, `NSKeyedArchiver` with secure coding, off the main actor), snapshot as HEIC (166), `sweepLeftovers` (176).
- `iosar: RoomScanKit/Sources/RoomScanKit/Capture/WorldMapRecord.swift`: `WorldMapRecord` (7, Codable record `worldmap.json`), `MappingTrack` (best and last status), `isUsable` (`status >= .extending`), `install(from:into:worldToScene:)` which moves the map into the scan folder and re-expresses the start pose in the scene frame.
- `iosar: RoomScan/Rescan/RescanCaptureController.swift`
  - `runSession(relocalizing:)` (702): `ARWorldTrackingConfiguration` with `initialWorldMap`, `.sceneDepth`, `options: []`.
  - `relocalize()` (585).
  - `RescanRoomCapture` (1046): RoomPlan on an already relocalized session via `RoomCaptureSession(arSession:)`, `stop(pauseARSession: false)`, `RoomBuilder(options: [.beautifyObjects])` on the end data.
  - `startRoomPlanIfDue` (817) and `stopRoomPlanAfterCorners` (848).
- `iosar: RoomScanKit/Sources/RoomScanKit/Rescan/RescanRelocalization.swift`: pure state machine `starting, relocalizing, aligning, aligned, refused, cancelled`; `sessionToScene(worldToScene:correction:aboutCamera:)` (166) is the single session-to-scene transform.
- `iosar: RoomScan/Rescan/RescanOverlay.swift` (19): the only RealityKit code. `ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)` with `view.session = controller.hub.session` (shares the one session), `AnchorEntity(world: .zero)` whose transform is set to the scene-to-session matrix, wire boxes, a pulsing floor disc 0.5 m wide as the standpoint marker, `SceneEvents.Update` subscription. This is the closest iosar has to "footprint on the floor".
- `iosar: docs/superpowers/specs/2026-10-31-guided-rescan-design.md` section 5 (relocalization) and `iosar: docs/superpowers/specs/2026-10-20-own-arsession-design.md` (shared session).

### (d) Saving scans locally

- `iosar: RoomScanKit/Sources/RoomScanKit/Persistence/ScanStore.swift`: single `index.json` beside scan folders, written atomically; the folders are the truth and the index is a cache (rebuilt from folders if missing or corrupt; undecodable records preserved verbatim; orphans moved, never deleted).
- `iosar: RoomScanKit/Sources/RoomScanKit/Persistence/ArtifactWriter.swift` (names such as `capture.json`) and `iosar: RoomScanKit/Sources/RoomScanKit/Common/AtomicFile.swift` (`ScanFileProtection`, line 52: class `.completeUntilFirstUserAuthentication`, `createDirectory`, atomic replace and write).
- `iosar: docs/export-schema.md`: the versioned `scene.json` contract (`SceneDocument`, `iosar: RoomScanKit/Sources/RoomScanKit/Export/ParametricExporter.swift`, `schemaVersion = 2` at 513).

## 2. Patterns to reuse

### Session setup and lifecycle

- RoomPlan UI is a UIKit view. Wrap `RoomCaptureView` in a `UIViewControllerRepresentable`; start it in `viewDidAppear`, not `viewDidLoad`; stop it in `viewWillDisappear` (`iosar: RoomScan/Capture/RoomCaptureFlow.swift` 165-176, 190-193).
- Guard the start with a `hasStopped` flag. `viewDidAppear` can fire again after a sheet is dismissed, and re-running RoomPlan restarted LiDAR for a coordinator that had already finished (comment at 169-172, audit item CO2).
- Finish with the delegate pair. `shouldPresent` returns false for a cancelled scan so nothing is processed; `didPresent` is guarded by a `hasFinished` flag. An empty `walls` array is a failure (`emptyScan`), not a success.
- Hand the result to the rest of the app as a value (`CaptureOutcome`) and let the coordinator drop its references; the coordinator lives as long as the representable (`CaptureCoordinator.swift` 124-145).
- Anything taken from the live session (mesh snapshot, world map) is taken before `captureSession.stop()` and bounded by a timeout so it can never block stopping. A timeout means a missing artifact, never a broken scan (`RoomCaptureFlow.swift` 343-362 inside `stopScanning`; `WorldMapSaver.timeout` is 3 s, marked provisional in the code).
- RoomPlan as a second phase on an existing session: `RoomCaptureSession(arSession:)`, then `session.stop(pauseARSession: false)` so tracking keeps running, then wait for `didEndWith` (5 s timeout, fall back to the last live room), then rebuild with `RoomBuilder(options: [.beautifyObjects])` (`RescanCaptureController.swift` 1046-1110). Do not issue a new `session.run` before RoomPlan has ended (re-review N1, comment at 842-844).

### Sharing one ARSession with RoomCaptureSession

- Only one `ARSession` can own the camera. Own it yourself and give it to `RoomCaptureView(frame:arSession:)`; keep your own delegate on the `ARSession`, never on the `RoomCaptureSession` (`iosar: docs/superpowers/specs/2026-10-19-roomscan-design.md` around 440-452; `iosar: docs/superpowers/specs/2026-10-20-own-arsession-design.md` sections 1-3).
- `ARFrameHub` is the pattern: a serial `delegateQueue`, observers keyed by id, handlers that return fast and copy values out of the frame, and `isDelivering` as a health flag. Events are an optimisation: every reader must still work from `session.currentFrame` if RoomPlan replaces the delegate (`ARFrameHub.swift` 12-31).
- The same session also backs RealityKit: `ARView(... automaticallyConfigureSession: false)` with `view.session = hub.session` (`RescanOverlay.swift` 22-25). That is how a guidance overlay can sit on the shared session without a second camera owner.
- Do not take back the delegate if RoomPlan replaced it ("sticky delegateLost", `ARFrameHub.swift` 68-70).
- If the app needs its own configuration on RoomPlan's session (iosar adds scene reconstruction), RoomPlan sets its configuration asynchronously: poll `session.configuration` for up to about 1.25 s (5 tries at 250 ms), carry over `frameSemantics`, call `run(config, options: [])`, and treat every failure as "feature missing" (`RoomCaptureFlow.swift` 225-295). Resoniq does not need the mesh; the lesson that matters is `options: []` and carrying `frameSemantics`.

### Converting CapturedRoom to a plain room model

- Destructure once, in one adapter, with no math in it; do all math on the plain model (`CapturedRoomAdapter` doc comment). Widen Float to Double on the way in (`SurfaceMapping.widen`).
- Plain model fields iosar keeps per surface: `id`, `parentID` (opening to wall), `kind` (wall, door with `isOpen`, window, opening, floor), `confidence`, `dimensions` (SIMD3), `transform` (4x4), `polygonCorners`, `completedEdges`, `curve`. Per object: `id`, category string, `confidence`, `dimensions`, `transform`.
- Mark unknown enum values conservatively: unknown confidence becomes `.low`, unknown category becomes `unknown`, via `@unknown default` (`CapturedRoomAdapter.swift` 40-61, `SurfaceMapping.confidence`).
- iosar's adapter drops `StorageType` (cabinet vs shelf), `Surface.Curve` is kept. Resoniq should decide whether it needs `storage` subtype; for speakers and furniture proxies it probably does not (inferred).
- `RoomGeometry` is not `Codable`. Resoniq wants a Codable room model; iosar's `scene.json` (`SceneDocument`) is the Codable one but is large and pipeline-shaped. Copy its conventions (centre-origin 16-number column-major transforms, `dimensions` kept separate, nulls for unmeasured), not the type.

### Coordinate and unit conventions (all verified in iosar docs or code)

- ARKit world: right-handed, +Y up, metres. RoomPlan values are Float, metres (`iosar: docs/export-schema.md` 17-28).
- Every RoomPlan transform is a rigid 4x4 whose translation is the geometry's centre, not a corner or base. A 2.5 m wall at height 1.25 m spans y 0 to 2.5. `dimensions` are local `[x, y, z]`; a wall is `[width, height, thickness]` (export-schema 28, 86). Dimensions can legitimately be zero (flat surfaces have zero thickness).
- `polygonCorners` are in the surface's own plane (local xy, z = 0). They must go through the surface transform before any top-down projection (`Geometry.worldCorners`; found as a real bug, `iosar: docs/manual-test-checklist.md` 68-73).
- Top-down projection uses world (x, z). Plan coordinates are `(x, z)`; object yaw is `atan2(-m[2], m[0])` (`ScanReview.swift` 305).
- Room-anchored frame: `SceneNormalizer` puts the origin at the vertex mean of the floor polygon corners, floor at y = 0, and rotates about Y so the longest straight wall's local x is +X; curved walls are skipped for the axis. The frame is rigid, so measurements do not change. Yaw is only defined up to 180 degrees (export-schema 20-22). Without a floor polygon of at least 3 usable corners the frame is the identity.
- Keep `sceneTransform` (world to scene) with the scan. It lets you return to ARKit world space, which is what a later AR session needs.

### Persistence format

- iosar stores two things per scan: RoomPlan's own encoding (`capture.json`, `JSONEncoder().encode(CapturedRoom)`) and its own normalised document (`scene.json`, version 2). Resoniq inference: store the room model plus `worldToScene`, and optionally the raw `capture.json` as a re-derivation source.
- `capture.json` encoding facts: RoomPlan writes enums as one-key objects (`{"high":{}}`, `{"door":{"isOpen":true}}`); the real file also carries an undocumented `coreModel` field and still round-trips through `JSONDecoder().decode(CapturedRoom.self, ...)` (`iosar: docs/manual-test-checklist.md` 68-70; `iosar: RoomScanKit/Sources/RoomScanKit/Rescan/CapturedRoomFile.swift` 36-46, `iosar: RoomScanKit/Tests/RoomScanKitTests/CapturedRoomEncodingTests.swift`).
- Version the file (`schemaVersion`), write unmeasured values as explicit `null`, and let readers accept missing new optional fields (export-schema 11, 13-15).
- Reject non-finite values per surface rather than writing NaN; count what was omitted (`omitted` block in export-schema).
- World map: three files next to the scan (`worldmap.arexperience`, `worldmap.json`, `worldmap-start.heic`); the record is written last so it only names files that exist; the move into the scan folder is whole-or-nothing and failure never loses the scan (`WorldMapRecord.install`). The record stores the start pose in the scene frame.
- Local storage: one index file as a cache over self-describing folders, atomic writes, explicit file protection class, orphan sweep that only moves (`ScanStore.swift` header 6-17, `AtomicFile.swift` 49-53).

### Relocalization and persisting positions across sessions

- Save the world map at scan stop, before `stop()`, from the same session RoomPlan ran on. Track `worldMappingStatus` on every frame and judge the map by the best status reached, not the status at stop. ARKit's status describes the area around the phone's current position, so the frame at stop often reads `limited` after a well-mapped room (`WorldMapSaver.swift` 7-15; `WorldMapRecord.swift` 22-27; scan C73EEBFE).
- A map is usable only if the best status reached `extending` or `mapped` (`WorldMapRecord.isUsable`); iosar attributes this to Apple guidance.
- Relocalize with `ARWorldTrackingConfiguration.initialWorldMap`, `options: []`, and `sessionShouldAttemptRelocalization` returning true (the hub returns false by default; flip it with `setAttemptsRelocalization(true)`). Never pass `.resetTracking` after relocalization; it throws the relocalized frame away (`guided-rescan-design.md` 5.2).
- Do not trust relocalization alone. iosar runs a "referee": it waits for tracking `.normal`, records a 3 s window of depth, and registers it against the saved walls; the result is a rigid correction (`FrameCorrection`: translation plus heading) and the accepted/refused verdict. `sessionToScene` then applies one transform to everything drawn or measured. Fixed hint times: hint after 20 s, retry offered after 45 s (`RescanRules`).
- iosar has no ARAnchor persistence. Inferred recommendation for Resoniq: store speaker and seat positions in the room-anchored scene frame, never in raw world coordinates, and convert with the saved `worldToScene` plus a relocalization correction at session start.
- RealityKit placement overlay: put one `AnchorEntity(world: .zero)` at the root and set its transform to the scene-to-session matrix; children are then authored in room coordinates (`RescanOverlay.swift` 121-130).

### Capability checks and fallback

- `RoomCaptureSession.isSupported` is a static Bool and is the iosar gate: the root view shows a "no LiDAR" message when false (`RoomScanApp.swift` 68-72). It is false on every simulator.
- `DeviceCapabilityProbe.probe` also asks `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)` and `supportsFrameSemantics(.sceneDepth)` / `.smoothedSceneDepth`. Every answer comes from a system API, never from the device model; the capability set is a Codable struct (`DeviceCapabilities`).
- Camera permission: `NSCameraUsageDescription` is set through `INFOPLIST_KEY_` in the Xcode project; the app asks with `AVCaptureDevice.requestAccess(for: .video)` in first-run, and the scan view relies on it (`FirstRunView.swift` 168, 252). No `UIRequiredDeviceCapabilities` key was found in the project.
- Fallback for devices without LiDAR: none in iosar (single-device tool). Resoniq's manual-entry path is new work. Reusable idea: the plain room model has `null` for what was not measured and no inferred shapes; a manually entered room can fill the same model with a source flag (inferred recommendation).

### Test seams

- Keep RoomPlan out of the Kit: the Kit target compiles on macOS 15 and iOS; `CapturedRoomAdapter` sits behind `#if canImport(RoomPlan)`; math lives in primitive-typed helpers.
- A real recorded capture is a committed fixture (`iosar: RoomScanKit/Tests/RoomScanKitTests/Fixtures/real-capture.json`: 6 walls, 1 door, 1 window, 5 objects). Tests decode it with `JSONDecoder` into `CapturedRoom` to run the adapter on a simulator or Mac (tag `.iosAdapter`, see `CapturedRoomEncodingTests.swift`). Pulling a capture from a phone without Xcode: `xcrun devicectl device copy from ... --source Documents/scans/<id>/capture.json` (manual-test-checklist 65-69).
- UI tests: a DEBUG-only harness gives the simulator a fake root and a fresh artifact directory (`iosar: RoomScan/Common/UITestHarness.swift` 9-19), activated by a launch argument; the Release build compiles an inert stub. `RescanCaptureController.Feed` has a `.live` and a `.scripted(Script)` case that replaces camera, tracking and the referee with scripted values (`RescanCaptureController.swift` 51-55, 598).
- The state machines (`RescanRelocalization`, `RescanGuide`) are pure Swift driven by events, so the logic is tested without ARKit (`iosar: RoomScanKit/Tests/RoomScanKitTests/RescanRelocalizationTests.swift`).
- Static HUD previews over a stand-in for the camera exist for the simulator (`DSComponentGallery`, `NewScanView.swift` 552).

## 3. Pitfalls and lessons learned

1. Taking the `RoomCaptureSession` delegate suppresses RoomPlan's coaching overlay (measured on device, 2026-10-20). Take only the `ARSession` delegate. Source: `iosar: RoomScan/Capture/SessionDelegateProxy.swift` 4-10.
2. RoomPlan may install its own `ARSession.delegate` after `run`. Events are never load-bearing; log `delegate kept|replaced` at +1 s and +5 s. Source: `ARFrameHub.swift` 18-22, 135-175.
3. Holding `ARFrame`, `capturedImage` or depth buffers past a delegate call makes ARKit log "retaining N ARFrames" and stop delivering, which also stalls RoomPlan. Copy values out before the first `await`. Sources: `ARFrameHub.swift` 23-30; `iosar: docs/audit/2026-10-23-review-app.md` around 140; `iosar: docs/manual-test-checklist.md` 123.
4. RoomPlan's mesh anchors: its own configuration reports non-zero `sceneReconstruction` yet emits no `ARMeshAnchor`; only installing your own mesh-enabled configuration produced anchors. This is measured behavior, not documented contract, and RoomPlan may reclaim it. Source: `RoomCaptureFlow.swift` 216-224.
5. `.resetTracking` would move the world origin and desynchronise anything captured earlier on the same session; use `options: []`. Sources: `RoomCaptureFlow.swift` 216-224; `guided-rescan-design.md` 5.2.
6. RoomPlan reconfigures the shared session when it runs. After it stops, re-apply your own configuration (without `initialWorldMap`, to a session that is already tracking). Source: `RescanCaptureController.swift` 697-713.
7. `viewDidAppear` can fire twice; a restart after finish loses the second result silently. Source: `RoomCaptureFlow.swift` 169-173 (audit CO2).
8. `currentFrame` after `stop()` is not guaranteed; take snapshots before it. Source: comment in `stopScanning`, `RoomCaptureFlow.swift` 343.
9. World map judged by last frame status wrongly refused good maps; judge by best status. Source: `WorldMapRecord.swift` 22-27 (scan C73EEBFE, probe 2026-11-08).
10. An archived world map is tens of MB; fetch on the main actor, archive and write off it, release the map immediately, keep only its size. `getCurrentWorldMap` completion must be `@Sendable`. Source: `WorldMapSaver.swift` 19-21, 141-162.
11. Interleaving `getCurrentWorldMap` with RoomPlan's stop was an unknown risk in the research (R3); iosar calls it before `stop()` and bounds it by a timeout. Whether that was ever observed to interfere: not determined. Source: `iosar: docs/research/2026-10-31-guided-rescan.md` 543.
12. `polygonCorners` are plane-local (xy, z = 0). Projecting them straight to world xz gave zero floor area and a silent fallback. Source: `iosar: docs/manual-test-checklist.md` 68-73.
13. Transform translation is the geometry's centre; importers that extrude from it are half a height off. Dimensions may be zero. Source: `iosar: docs/export-schema.md` 28.
14. The room frame's yaw is only known up to 180 degrees, so a room can arrive facing the other way. Do not give the orientation user-visible meaning. Source: export-schema 21.
15. Curved walls: the sweep axis, sign and zero reference of `Surface.Curve` are unverified; only `radius` and flat width are reliable. Source: export-schema, `walls[].curve` row.
16. `completedEdges` was `[]` on every recorded capture; "closed" is decided by the app (a wall end within 5 cm of another wall's end), not read from RoomPlan alone. Source: export-schema `completedEdges` row; `RoomLayoutRefinement`.
17. Partial and corner scans are normal: low-confidence surfaces, incomplete walls, openings with no parent wall and a missing floor polygon. Report what was seen; do not estimate. When no floor polygon exists, the perimeter-square fallback area is an estimate and iosar withholds it from exports. Sources: export-schema 7-9, 71; `iosar: docs/scanning-guide.md` section 7.
18. Plane accuracy: RoomPlan's wall plane was within 2 cm of the dominant measured level on 56 of 65 hosts; on a window the plane can sit on the glass. Source: `iosar: docs/research/2026-10-30-measured-relief.md` 33, 125-128 (a research result, only for the rooms measured).
19. LiDAR is weakest on black glossy surfaces and glass (TVs, windows); below roughly 0.3 m the LiDAR is under minimum range; room light affects tracking and labels, not LiDAR geometry. The documented upper range is not measured. Source: `iosar: docs/scanning-guide.md` 5, "What this guide cannot promise".
20. A scan failure should map to specific messages: scene too large, tracking lost, device too hot, device unsupported. Source: `CaptureCoordinator.swift` 28-56.
21. Tracking interruptions: the session reports `sessionWasInterrupted`; iosar's rescan pauses and relocalizes again against the same map on resume. Sources: `ARFrameHub.swift` 209-215; `RescanCaptureController.swift` 303-318.
22. `ARFrame` poll fallback needed: pose at about 60 Hz is delivered while tracking; `eventStaleness` of 1 s is the code's provisional threshold. Source: `ARFrameHub.swift` 37-40.
23. Not ARKit-specific but cost iosar real time: Swift 6.4 (Xcode 27.1) Release builds miscompiled a large async function ("freed pointer was not the last allocation"); the fix was to extract the loop. Source: `iosar: docs/research/2026-10-25-task-alloc-crash.md`. Also, on-device timings were first taken on a Debug build; measure on Release (`iosar: docs/audit/2026-10-23-review-app.md` PF17).
24. Heat: long scans plus other heavy work raise thermal state; RoomPlan reports `deviceTooHot` as a capture error. iosar's thermal budgeting is its own machinery and is not worth porting (see section 4).

## 4. Not worth porting

- Object segmentation, detection and Core ML: `RoomScan/Capture/CoreMLObjectDetector.swift`, `FrameSampler`, `RoomScanKit/.../Detection`, `Measurement`, `Surfaces`.
- 3D twin and mesh reconstruction: TSDF, marching cubes, `ObjectTwin`, `FurnitureFit`, `Sweep`, `MeshCollector`, `DepthFrameCollector`, `FrameRecording`.
- Cloud and editor upload, pairing, live stream (`LiveStream/`, `RelayUploadPlan`).
- Pipeline, atlas and caching machinery: `PipelineDefinition`, `ProcessingPipeline` stages, atlas notes, `scoreboard.json`, benchmarks.
- The guided rescan planner and guide (`RescanPlanner`, `RescanGuide`, `RescanPlan`, face and wall region targets): too tied to photo-capture goals. Only the relocalization state machine, referee idea and overlay technique transfer.
- Thermal and storage governors (`ThermalPolicy`, `CaptureStats`), diagnostics recorders, `ProbeLog`.
- The design system (`RoomScan/DesignSystem`) and Serbian copy: Resoniq has its own.
- Wall deviation / architectural elements (beams, niches): not needed for room acoustics at this stage (inferred).

## 5. Minimum iOS versions and API availability

- iosar's current floor is iOS 27.0 (`IPHONEOS_DEPLOYMENT_TARGET = 27.0` in `iosar: RoomScan.xcodeproj/project.pbxproj`, `platforms: [.iOS("27.0"), .macOS("15.0")]` in `iosar: RoomScanKit/Package.swift`). Its code contains no `@available` or `#available` gates for RoomPlan or ARKit.
- The original design chose iOS 17.0 as "the exact floor at which every API this design uses becomes unconditional": `Surface.Category.floor`, `CapturedRoom.floors`, `CapturedRoom.sections`, `StorageType` (`iosar: docs/superpowers/specs/2026-10-19-roomscan-design.md` line 22, 174-183). The floor was later raised; the guided-rescan spec (line 468) states the target as 26.0.
- `RoomCaptureView(frame:arSession:)` and `RoomCaptureSession(arSession:)`: iOS 17 (own-arsession-design section 1 says this was verified in the iPhoneOS 27.1 SDK `RoomPlan.swiftinterface`; I did not re-check the SDK).
- `RoomCaptureSession.CaptureError.objectNotDetected` is iOS 17.4+, which is why iosar matches by name to keep compiling against the 17.0 floor (`iosar: RoomScan/ObjectScan/ObjectCaptureController.swift` 247; that is ObjectCapture, not RoomPlan).
- Which APIs actually force iOS 27: not determined. The code that touches RoomPlan and ARKit (everything listed above) is 17-era API as documented in iosar; the raise to 26 and 27 appears tied to other features (inferred: object capture, Core ML, Foundation Models, toolchain, design choices). The Kit also builds on macOS 15 for fast tests.
- Swift toolchain: Swift 6 language mode in the Kit, Swift 5 mode in the app (`iosar: CLAUDE.md`); Xcode 27.1 SDK.
- Hardware: `RoomCaptureSession.isSupported` requires LiDAR (iosar's own startup text says iPhone 12 Pro and later Pro models and iPad Pro; this is iosar's copy, not verified against Apple).
- Not determined from iosar: availability of `ARWorldMap` / `getCurrentWorldMap` versions (the code uses them unconditionally at iOS 27), RealityKit `ARView` deprecation status on iOS 26+ or 27+, any RoomPlan API added after iOS 17. Check the iOS 27.1 SDK interfaces directly before relying on them.
