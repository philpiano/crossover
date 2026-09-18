// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "AudioSplitAngel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AudioSplitAngel", targets: ["AudioSplitAngel"]),
    ],
    targets: [
        // Real-time crossover engine. Plain C: no allocation, no locks, no Swift runtime on the audio thread.
        .target(
            name: "SplitCore",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // SwiftUI app + Core Audio device/aggregate management.
        .executableTarget(
            name: "AudioSplitAngel",
            dependencies: ["SplitCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Accelerate"),
            ]
        ),
        // Deterministic tests for the engine (runs without any audio hardware).
        .executableTarget(
            name: "SplitCoreSelfTest",
            dependencies: ["SplitCore"]
        ),
    ]
)
