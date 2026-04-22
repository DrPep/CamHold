# CamHold

A minimal macOS menu-bar app that "holds" a camera open by running an
`AVCaptureSession` with a no-op `AVCaptureVideoDataOutput`. Useful for keeping
a USB/virtual camera warm, preventing auto-sleep/renegotiation, or reserving
it from other apps.

## Requirements

- macOS 13 or later
- Swift 5.9+ toolchain (ships with Xcode 15 / recent Command Line Tools)

## Build

### Option A — Swift Package Manager (recommended)

```sh
swift build -c release
.build/release/CamHold    # runs, but see "Camera permission" below
```

The `Info.plist` in `Sources/CamHold/Resources/` ships with the package but
SPM does **not** stitch it into the executable's `__info_plist` section by
default; on first camera access macOS will still prompt, but to get a stable
TCC identity (so the permission persists across rebuilds) wrap the binary in
a proper `.app` bundle — see Option B.

### Option B — Build a signed `.app` bundle

```sh
./build.sh
open build/CamHold.app
```

This compiles directly with `swiftc`, copies `Info.plist` into
`Contents/Info.plist`, and ad-hoc code-signs the bundle. Override the SDK or
target with env vars:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk \
MACOSX_TARGET=arm64-apple-macos13 \
./build.sh
```

### Option C — Xcode project

If you want a distributable signed build, create an Xcode macOS **App**
target, drag `Sources/CamHold/*.swift` in, and set under **Signing &
Capabilities**:

- App Sandbox → Camera ✅
- Hardened Runtime → Camera ✅

Then in **Info**:

- `NSCameraUsageDescription`
- `LSUIElement` = `YES` (menu-bar only, no Dock icon)
- `LSMinimumSystemVersion` = `13.0`

## Camera permission

macOS will prompt the first time the session starts. If you denied it, reset
with:

```sh
tccutil reset Camera com.example.CamHold
```

(use the `CFBundleIdentifier` you shipped with).

## Tests

```sh
swift test
```

The single test (`FormatSelectorTests`) skips gracefully on CI machines
without a camera.

## File layout

```
CamHold/
├── Package.swift
├── build.sh                           # swiftc fallback + .app bundler
├── README.md
├── Sources/CamHold/
│   ├── main.swift                     # NSApplication boot
│   ├── AppDelegate.swift              # lifecycle
│   ├── StatusItemController.swift     # NSStatusItem + NSMenu
│   ├── CameraController.swift         # AVCaptureSession lifecycle
│   ├── CameraEnumerator.swift         # AVCaptureDevice discovery
│   ├── FormatSelector.swift           # "best" format picker (unit-testable)
│   ├── NoopVideoOutput.swift          # drain frames, drop them
│   ├── Preferences.swift              # UserDefaults persistence
│   └── Resources/Info.plist
└── Tests/CamHoldTests/
    └── FormatSelectorTests.swift
```

## Implementation notes (deltas from the design doc)

The original design has two calls that are iOS-only. Both were adjusted for
macOS; behavior is preserved:

1. **`AVCaptureDeviceFormat` → `AVCaptureDevice.Format`.** Swift 4 renamed the
   Obj-C class to a nested type.
2. **`.inputPriority` session preset and `isVideoBinned` property are
   `API_UNAVAILABLE(macos)`.** On macOS, assigning `device.activeFormat`
   automatically puts the session into input-priority mode (see header docs
   for `AVCaptureSessionPresetInputPriority`), so we simply drop the preset
   assignment. `isVideoBinned` was part of the tiebreaker score; without it
   the score falls back to (pixels, fps, pixel-format preference), which is
   still deterministic and picks a sensible format on every Mac camera I
   tested.

All other modules match the design 1:1.
