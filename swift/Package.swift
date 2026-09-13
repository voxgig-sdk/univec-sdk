// swift-tools-version:5.9
//
// Univec SDK - SwiftPM manifest. The runtime itself is dependency-free
// (Foundation + the vendored Voxgig Struct port under
// Sources/ProjectNameSDK/Struct); declared feature/target deps (if any)
// appear below.
import PackageDescription

let package = Package(
    name: "UnivecSdk",
    // The deployment floor. Without it SwiftPM assumes the oldest macOS the
    // toolchain still targets, and the SDK's AsyncStream-based streaming
    // (EntityBase) fails to compile on macOS with "'AsyncStream' is only
    // available in macOS 10.15 or newer" - linux has no such floor, which
    // is why the generator's own linux runs never saw it. Found by the
    // secrets lane, the first lane to build a full generated swift SDK on
    // the macos CI leg.
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "UnivecSdk", targets: ["UnivecSdk"]),
    ],
    targets: [
        .target(
            name: "UnivecSdk",
            path: "Sources/UnivecSdk"),
        .testTarget(
            name: "Omni",
            path: "Tests/vendor/omni"),
        .testTarget(
            name: "UnivecSdkTests",
            dependencies: ["UnivecSdk", "Omni"],
            path: "Tests/UnivecSdkTests"),
    ]
)
