// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CamHold",
    platforms: [.macOS(.v13)],
    targets: [
        // Tiny Objective-C shim that turns NSException into NSError, so Swift
        // can safely call AVFoundation setters that raise (e.g.
        // setActiveVideoMinFrameDuration on devices that reject it).
        .target(name: "CamHoldObjC"),
        .executableTarget(
            name: "CamHold",
            dependencies: ["CamHoldObjC"],
            // Info.plist is app-bundle metadata, not a SwiftPM resource (and
            // SwiftPM forbids it as a top-level resource). `build.sh` copies it
            // into CamHold.app/Contents/Info.plist; for the bare `swift build`
            // executable we embed it into the __TEXT,__info_plist section so the
            // binary still carries NSCameraUsageDescription for camera TCC.
            exclude: ["Resources"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CamHold/Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(name: "CamHoldTests", dependencies: ["CamHold"])
    ]
)
