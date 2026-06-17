# CamHold §9d Delta — Slack-Triggered Auto-Hold

Scope: implement the §9d "Slack-triggered auto-hold" feature on top of the
existing CamHold sources at `Sources/CamHold/`, using §6 (CMIO device-master
ownership) and §7 (`ForceUncompressedFormat`) as the format-commit primitive.

---

## A. Inventory — what already exists

Mapped against the §7 / §9a / §9d API surface:

| Capability (note ref) | Symbol in repo | File | Status |
|---|---|---|---|
| `ForceUncompressedFormat` (§7) — pick best format, lock, set `activeFormat`, pin frame durations | `FormatSelector.bestFormat(for:)` + `CameraController.applyBestFormat(to:)` | `FormatSelector.swift`, `CameraController.swift` | **Partial.** Selection scores by pixels × fps × `420v`-preference; it does *not* exclude compressed subtypes (`dmb1`, `avc1`). For a Sony ZV-E10 the 1080p MJPEG entry will still win on the `(pixels, fps)` tuple. Needs an uncompressed-only filter as in §7. The lock + `activeFormat` + min/max frame-duration pinning is correct. |
| Device picker (§9a/§9d implicit) | `CameraEnumerator.devices()` | `CameraEnumerator.swift` | **Exists.** Includes `.external` / `.continuityCamera` on macOS 14+. |
| Persisted-selection store | `Preferences.selectedDeviceID`, `Preferences.autoStart` | `Preferences.swift` | **Exists.** Single-device only — no watched-bundle list yet. |
| Menu-bar controller | `StatusItemController` | `StatusItemController.swift` | **Exists.** Toggle, device list, autostart, quit. No "Auto-hold for app…" submenu. |
| Lifetime-managed `AVCaptureSession` (§9a) | `CameraController.session` (let, on `camhold.session` queue), `currentInput`, `NoopVideoOutput` | `CameraController.swift`, `NoopVideoOutput.swift` | **Exists.** Session is held for the lifetime of the controller; `start()` / `stop()` pattern is reusable for the auto-hold edges. `sessionPreset` is **not** explicitly set to `.inputPriority`; the comment in `configureAndRun` argues AVFoundation switches modes implicitly when `activeFormat` is assigned. §7 calls this out as risky — should set `.inputPriority` explicitly. |
| App lifecycle / accessory mode | `AppDelegate`, `main.swift` (`LSUIElement` + `setActivationPolicy(.accessory)`) | `AppDelegate.swift`, `main.swift`, `Resources/Info.plist` | **Exists.** |

---

## B. Inventory — what is missing

All five items called out in §9d are absent from the current tree:

1. **CMIO property-listener wiring.**
   - No import of `CoreMediaIO` anywhere (`grep` for `CMIOObject*`, `kCMIO*` is empty).
   - Need `CMIOObjectAddPropertyListenerBlock` registration on
     `kCMIODevicePropertyDeviceIsRunningSomewhere` per watched device, on a
     dedicated serial dispatch queue, with stored opaque listener handles for
     deregistration on quit / device-removed.
   - Need a helper to map an `AVCaptureDevice.uniqueID` → `CMIODeviceID` by
     scanning `kCMIOHardwarePropertyDevices` and matching
     `kCMIODevicePropertyDeviceUID`. (Not directly exposed by AVFoundation.)

2. **Process-table scan / running-app check by bundle ID.**
   - §9d describes `proc_listallpids` + `proc_pidpath` + `CFBundle` lookup.
   - On modern macOS (10.6+), `NSRunningApplication.runningApplications(withBundleIdentifier:)`
     is the simpler equivalent and is verified reachable from `AppKit` (already imported).
     Recommend using it instead of the BSD walk; fall back to `proc_listallpids`
     only if a watched bundle ID is for a non-LSUIApplication helper. The
     §9d snippet's `proc_*` path remains a valid implementation.

3. **`NSWorkspace` launch / terminate observers.**
   - Not wired. Need to subscribe on
     `NSWorkspace.shared.notificationCenter` to
     `didLaunchApplicationNotification` (arm hold pre-`getUserMedia`, see §9d
     "Timing caveat") and `didTerminateApplicationNotification` (release).
     These are independent of the CMIO `IsRunningSomewhere` edges and work
     together: `didLaunch` arms eagerly, the CMIO edge is the fallback for
     apps already running when CamHold starts.

4. **Preferences UI for a watched-bundle-ID list.**
   - `Preferences` stores only one device ID and an autostart bool.
   - Add: `watchedBundleIDs: [String]` (default `["com.tinyspeck.slackmacgap"]`),
     persisted as a `[String]` in `UserDefaults`.
   - Add UI: a "Auto-hold for apps…" submenu in `StatusItemController` with
     check-marked entries for each watched ID, plus an "Add Application…" item
     that opens `NSOpenPanel` filtered to `.app` bundles and reads
     `CFBundleIdentifier` from the chosen bundle's `Info.plist`.

5. **Self-edge guard against CamHold's own device-master ownership.**
   - When CamHold itself triggers an `IsRunningSomewhere` true edge (because
     the user manually started a hold, or because the auto-hold session just
     started), the CMIO listener will fire on our own queue. Without a guard
     this recurses: arm → start session → CMIO edge → arm again.
   - Need: read `kCMIODevicePropertyDeviceMaster` (deprecated since macOS 12,
     renamed `kCMIODevicePropertyDeviceControl` — see Risks) and short-circuit
     the listener if the returned PID equals `getpid()`. Also keep an
     in-process `isAutoHoldActive` flag as a belt-and-braces second guard,
     because the master PID is only set while we hold the
     `lockForConfiguration`, not for the entire `AVCaptureSession` lifetime.

---

## C. CoreMediaIO reachability from Swift

Verified empirically (`swift -` on this machine, macOS SDK in $PATH):

```swift
import CoreMediaIO
// All of these resolve without a bridging header:
_ = kCMIODevicePropertyDeviceIsRunningSomewhere   // = 'gone' (UInt32)
_ = kCMIODevicePropertyDeviceMaster               // = 'mast' (deprecated 12.0)
_ = kCMIODevicePropertyDeviceControl              // replacement
let _: (CMIOObjectID,
        UnsafePointer<CMIOObjectPropertyAddress>,
        DispatchQueue?,
        @escaping CMIOObjectPropertyListenerBlock) -> OSStatus
    = CMIOObjectAddPropertyListenerBlock
```

`CMIOObjectGetPropertyData`, `CMIOObjectPropertyAddress`,
`kCMIOObjectPropertyScopeWildcard`, `kCMIOObjectPropertyElementMain`,
`kCMIOHardwarePropertyDevices`, `kCMIODevicePropertyDeviceUID` are likewise
imported as Swift symbols.

`proc_listallpids` / `proc_pidpath` are available via `import Darwin`. Note
that Swift imports `proc_listallpids`'s buffer arg as
`UnsafeMutableRawPointer?` (untyped), so the pid buffer must be passed as
`buf.withMemoryRebound(to: UInt8.self, …)` or constructed via
`UnsafeMutableBufferPointer<pid_t>` and cast — minor but worth noting.

**Conclusion:** no Objective-C bridging header is required. The existing
`Package.swift` (a vanilla SwiftPM executable target) needs no module-map
changes; we only add `import CoreMediaIO` (and `import Darwin` if we go the
`proc_*` route) inside the new sources.

---

## D. Files to edit

| File | Change |
|---|---|
| `Sources/CamHold/FormatSelector.swift` | Add `bestUncompressedFormat(for:targetDims:fps:)` paralleling §7. Keep the existing `bestFormat` for the manual-hold path or migrate it. Filter on `subtype ∈ {2vuy, yuvs, 420v, 420f, BGRA}`. |
| `Sources/CamHold/CameraController.swift` | (i) Set `session.sessionPreset = .inputPriority` explicitly in `configureAndRun` (§7 caveat). (ii) Expose a non-toggle `armAutoHold(for:)` / `releaseAutoHold()` pair so the auto-hold path doesn't fight `isRunning` semantics — or add an internal `holdMode: .manual / .auto / .idle` enum. (iii) Track `isAutoHoldActive` for the self-edge guard. |
| `Sources/CamHold/Preferences.swift` | Add `watchedBundleIDs: [String]` (get/set via `UserDefaults.array(forKey:)` with default `["com.tinyspeck.slackmacgap"]`). Add `autoHoldEnabled: Bool`. |
| `Sources/CamHold/StatusItemController.swift` | Add "Auto-hold when these apps open the camera" toggle + submenu listing `prefs.watchedBundleIDs`, with add/remove items. Refresh on `watchedBundleIDsChanged` notification. |
| `Sources/CamHold/AppDelegate.swift` | Instantiate the new `AutoHoldCoordinator` (see §E), wire its `start()` after `statusItem.install()`, and `stop()` it from `applicationWillTerminate`. |
| `Sources/CamHold/Resources/Info.plist` | No code change required for the listener itself, but if we add a "force uncompressed for these apps" surface we may want a `LSApplicationCategoryType` of `public.app-category.utilities` (cosmetic). No new entitlements. |

---

## E. Files to add

| New file | Responsibility |
|---|---|
| `Sources/CamHold/CMIODevice.swift` | Thin Swift wrapper: enumerate CMIO devices, resolve `AVCaptureDevice.uniqueID → CMIODeviceID`, read/write `IsRunningSomewhere` and `DeviceMaster`/`DeviceControl`, with `OSStatus`-throwing helpers. |
| `Sources/CamHold/CMIORunningListener.swift` | Owns one `CMIOObjectAddPropertyListenerBlock` registration per watched `CMIODeviceID` on a private serial queue (`camhold.cmio.listener`). Publishes `(deviceID, isRunningSomewhere)` edges via a callback. Stores listener blocks for clean deregistration. |
| `Sources/CamHold/BundleProcessProbe.swift` | `func isAnyAppRunning(withBundleID:) -> Bool` using `NSRunningApplication.runningApplications(withBundleIdentifier:)` as the primary path, with a `proc_listallpids` fallback for non-LSUIApplication helpers if needed. |
| `Sources/CamHold/WorkspaceAppObserver.swift` | Wraps `NSWorkspace.shared.notificationCenter` for `didLaunchApplicationNotification` / `didTerminateApplicationNotification`, filters by a live set of bundle IDs, emits `(bundleID, .launched / .terminated)` events on the main queue. |
| `Sources/CamHold/AutoHoldCoordinator.swift` | The §9d state machine. Inputs: workspace launch/terminate edges, CMIO `IsRunningSomewhere` edges, current device-master PID, `prefs.watchedBundleIDs`, `prefs.autoHoldEnabled`, manual-hold state. Outputs: `CameraController.armAutoHold(for:)` / `releaseAutoHold()`. Implements the self-edge guard (skip if current master == `getpid()` OR `isAutoHoldActive`). |
| `Tests/CamHoldTests/FormatSelectorTests.swift` | Cover the new uncompressed-only ranking with synthetic `AVCaptureDevice.Format` doubles where possible (or skip-on-CI guard). |
| `Tests/CamHoldTests/AutoHoldCoordinatorTests.swift` | State-machine tests with stubbed CMIO/workspace inputs. No real camera required. |

---

## F. Risks

1. **Privacy-indicator behaviour (the user-visible regression).**
   - The §9a "always-on helper" lights the green camera LED / menu-bar dot
     for the entire login session. §9d's whole point is to *avoid* that by
     only holding when a watched app is active.
   - Risk: if `releaseAutoHold()` is not invoked on every terminal edge
     (Slack quits, Slack closes its `getUserMedia` track without quitting,
     watched-bundle list changes, device unplugged, system sleep), the
     indicator stays lit and the user perceives it as a bug worse than the
     original one we're fixing.
   - Mitigations: drive release from **both** the CMIO `IsRunningSomewhere
     → false` edge **and** the `NSWorkspace.didTerminateApplication` edge,
     whichever comes first; treat them as idempotent. Also release on
     `AVCaptureDeviceWasDisconnected`. Add a watchdog that, every N seconds
     while auto-hold is active, re-checks `isAnyAppRunning(...)` for the
     watched IDs and tears down if none are present (covers the Slack
     "released the track but stayed running" case where neither edge fires).

2. **Recursion via self-master.**
   - `CMIOObjectAddPropertyListenerBlock` callbacks fire for *all*
     `IsRunningSomewhere` transitions, including the one CamHold itself
     causes by starting its no-op session. Without a guard, the coordinator
     re-enters `armAutoHold` every time it starts a session.
   - Mitigation hierarchy:
     1. Coordinator-level `isAutoHoldActive` flag (cheapest, in-process).
     2. CMIO `DeviceMaster`/`DeviceControl` PID compared to `getpid()` —
        but note this PID is only populated while `lockForConfiguration` is
        held, not for the full session lifetime, so it cannot be the sole
        guard.
     3. Coalesce listener edges on the listener queue (drop a `true` edge
        that arrives while we already believe the device is running and we
        own the session).

3. **Listener thread-safety.**
   - `CMIOObjectAddPropertyListenerBlock` invokes the block on the
     dispatch queue we pass in. `AVCaptureSession` configuration must
     happen off the main thread but on a stable serial queue
     (CamHold uses `camhold.session`).
   - Risk: re-entering session configuration from the CMIO queue while the
     `camhold.session` queue is mid-`beginConfiguration`/`commitConfiguration`
     deadlocks or corrupts state; AVFoundation is internally serialised but
     we still must not call `lockForConfiguration` from two queues
     concurrently for the same device.
   - Mitigation: the CMIO listener queue **only** posts events; it never
     touches `AVCaptureSession`. The coordinator hops to
     `DispatchQueue.main` to mutate published state and then dispatches
     into `CameraController.sessionQueue` for the actual session work. All
     mutable coordinator state (`isAutoHoldActive`, last-known
     `IsRunningSomewhere` per device, current watched set) lives on a
     single serial queue (`camhold.autohold`) and is read/written via that
     queue only.

4. **Deprecated `kCMIODevicePropertyDeviceMaster`.**
   - macOS 12 renamed it to `kCMIODevicePropertyDeviceControl`. Both
     selectors still resolve at runtime against the same property, but
     using the deprecated name will emit a build warning.
   - Mitigation: define `let kDeviceMasterSelector: CMIOObjectPropertySelector
     = kCMIODevicePropertyDeviceControl` in `CMIODevice.swift` and use it
     everywhere; gate with `@available` only if we ever need to support
     pre-12.

5. **Bundle-ID misidentification.**
   - §9d explicitly warns against matching by process *name* (`Slack`
     collides). Use `CFBundleIdentifier` exclusively. The
     `NSRunningApplication.runningApplications(withBundleIdentifier:)`
     path satisfies this by construction.

6. **Format-selection regression for non-Sony cameras.**
   - The current `FormatSelector.bestFormat` ranks by `(pixels, fps,
     prefer-420v)`. Replacing it wholesale with an uncompressed-only filter
     could regress devices whose top format is *only* available as MJPEG
     (some action cams, capture cards). Decision: keep `bestFormat` as
     the fallback when `bestUncompressedFormat` returns nil, and surface
     a "Force uncompressed" per-device toggle in preferences.

---

## G. Build / packaging impact

- `Package.swift` requires no edits; `CoreMediaIO` and `Darwin` are stdlib
  modules on macOS.
- No new entitlements. `NSCameraUsageDescription` is already present.
  `NSWorkspace` running-application enumeration does **not** require
  any privacy entitlement on non-sandboxed macOS apps; CamHold ships
  unsandboxed (no `App Sandbox` capability in `Package.swift` / Info.plist).
- The existing `build.sh` / `package-dmg.sh` should not need changes.
