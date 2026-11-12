// swift-tools-version: 6.2
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "RemotePlay",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "RemotePlay", targets: ["RemotePlay"]),
    ],
    targets: [
        // scripts/build-chiaki-macos.sh (macOS dilimi) ve scripts/build-chiaki-ios.sh (iPhone/iPad dilimleri) ile üretilir
        // (chiaki-ng libchiaki + statik bağımlılıklar).
        .binaryTarget(name: "CChiaki", path: "../third-party/build/CChiaki.xcframework"),
        .target(
            name: "RemotePlay",
            dependencies: ["CChiaki"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("z"),
                // libchiaki CoreServices'i yalnız macOS'ta kullanır (takion.c, TARGET_OS_OSX).
                .linkedFramework("CoreServices", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(name: "rp-smoke", dependencies: ["RemotePlay"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RemotePlayTests", dependencies: ["RemotePlay", "CChiaki"], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
