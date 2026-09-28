// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kuzmemo",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KuzmemoCore", targets: ["KuzmemoCore"]),
        .executable(name: "Kuzmemo", targets: ["Kuzmemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        // The fallback recording chord (Carbon hot key, no extra permissions) and its recorder in settings.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.1.0"),
    ],
    targets: [
        // UI-free domain, storage, time and LLM-contract logic. Everything here is unit-tested.
        .target(
            name: "KuzmemoCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .treatAllWarnings(as: .error),
            ]
        ),
        // Speech recognition: WhisperKit behind the `Transcriber` protocol. WhisperKit is not Sendable, so it stays
        // inside an actor and only sample arrays and strings cross the boundary.
        .target(
            name: "KuzmemoSTT",
            dependencies: [
                "KuzmemoCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                // WhisperKit's classes are not Sendable; this one target wraps them behind an actor and
                // therefore builds in Swift 5 language mode. Everything else is Swift 6.
                .swiftLanguageMode(.v5),
            ]
        ),
        // The menu-bar app: SwiftUI + AppKit shell around KuzmemoCore.
        .executableTarget(
            name: "Kuzmemo",
            dependencies: [
                "KuzmemoCore", "KuzmemoSTT",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "KuzmemoSTTTests",
            dependencies: ["KuzmemoSTT", "KuzmemoCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "KuzmemoCoreTests",
            dependencies: ["KuzmemoCore"],
            exclude: ["Golden/phrases.jsonl", "Golden/cassettes"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
