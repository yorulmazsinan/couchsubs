// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

/// Çevrimiçi motor açıkken yerel yedeğin bu sistemde olmaması ana ekranda "Apple çevirisi iOS 26 ister" olarak
/// gösterilmez; motorun gerçek hatası ayrı uyarıda söylenir (GitHub #1322).
final class TranslatorStatusTests: XCTestCase {
    func testLocalOnlyStatusFollowsTheError() {
        XCTAssertEqual(TranslatorStatus.after(nil, onlineActive: false), .ready)
        XCTAssertEqual(TranslatorStatus.after(.needsDownload, onlineActive: false), .needsDownload)
        XCTAssertEqual(TranslatorStatus.after(.unsupported, onlineActive: false), .unsupported)
    }

    func testOnlineEngineFailureIsNotMaskedByMissingFallback() {
        XCTAssertEqual(TranslatorStatus.after(nil, onlineActive: true), .ready)
        XCTAssertEqual(TranslatorStatus.after(.unsupported, onlineActive: true), .ready)
        // Dil paketi indirilirse yedek çalışır: bu durum çevrimiçi motor açıkken de söylenir.
        XCTAssertEqual(TranslatorStatus.after(.needsDownload, onlineActive: true), .needsDownload)
    }
}
