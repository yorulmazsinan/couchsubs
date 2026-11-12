// swift-tools-version: 6.2
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "CouchSubsCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "CouchSubsCore", targets: ["CouchSubsCore"]),
    ],
    targets: [
        .target(name: "CouchSubsCore", resources: [.copy("Resources/obs-overlay.html"), .copy("Resources/glossary-en-tr.json"), .copy("Resources/ai-models.json"), .copy("Resources/packs")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "tv-smoke", dependencies: ["CouchSubsCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CouchSubsCoreTests", dependencies: ["CouchSubsCore"], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
