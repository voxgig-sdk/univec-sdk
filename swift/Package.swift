// swift-tools-version:5.9
//
// Univec SDK - SwiftPM manifest. The runtime itself is dependency-free
// (Foundation + the vendored Voxgig Struct port under
// Sources/ProjectNameSDK/Struct); declared feature/target deps (if any)
// appear below.
import PackageDescription

let package = Package(
    name: "UnivecSdk",
    products: [
        .library(name: "UnivecSdk", targets: ["UnivecSdk"]),
    ],
    targets: [
        .target(
            name: "UnivecSdk",
            path: "Sources/UnivecSdk"),
        .testTarget(
            name: "UnivecSdkTests",
            dependencies: ["UnivecSdk"],
            path: "Tests/UnivecSdkTests"),
    ]
)
