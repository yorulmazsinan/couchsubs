// swift-tools-version: 6.2
// SPDX-License-Identifier: AGPL-3.0-only

// Gerçek kare gerileme seti (scripts/regression-frames.sh). Çekirdek yolu COUCHSUBS_CORE ile değişir: betik aynı
// koşucuyu önceki etiketin çekirdeğine (ayrı worktree) karşı da derler.

import Foundation
import PackageDescription

let core = ProcessInfo.processInfo.environment["COUCHSUBS_CORE"] ?? "../../core"

let package = Package(
    name: "frame-regression",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: core)],
    targets: [
        .executableTarget(name: "frame-regression", dependencies: [.product(name: "CouchSubsCore", package: "core")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
