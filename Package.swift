// swift-tools-version: 6.2
import PackageDescription

let analysisSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

// The app target uses approachable concurrency: everything is MainActor
// unless marked otherwise. Audio and analysis code opts out explicitly.
let appSettings: [SwiftSetting] = analysisSettings + [
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "Voice",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VoiceAnalysis", targets: ["VoiceAnalysis"]),
        .executable(name: "Voice", targets: ["VoiceApp"]),
        .executable(name: "voice-cli", targets: ["VoiceCLI"]),
    ],
    targets: [
        .target(name: "VoiceAnalysis", swiftSettings: analysisSettings),
        .executableTarget(
            name: "VoiceApp",
            dependencies: ["VoiceAnalysis"],
            swiftSettings: appSettings
        ),
        .executableTarget(
            name: "VoiceCLI",
            dependencies: ["VoiceAnalysis"],
            swiftSettings: analysisSettings
        ),
        .testTarget(
            name: "VoiceAnalysisTests",
            dependencies: ["VoiceAnalysis"],
            swiftSettings: analysisSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
