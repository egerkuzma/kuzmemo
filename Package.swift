// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kuzmemo",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KuzmemoCore", targets: ["KuzmemoCore"]),
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
        .testTarget(
            name: "KuzmemoCoreTests",
            dependencies: ["KuzmemoCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
