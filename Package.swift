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
        // The menu-bar app: SwiftUI + AppKit shell around KuzmemoCore.
        .executableTarget(
            name: "Kuzmemo",
            dependencies: ["KuzmemoCore"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("ExistentialAny"),
            ]
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
