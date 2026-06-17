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
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CamHoldTests", dependencies: ["CamHold"])
    ]
)
