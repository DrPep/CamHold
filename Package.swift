// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CamHold",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CamHold",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CamHoldTests", dependencies: ["CamHold"])
    ]
)
