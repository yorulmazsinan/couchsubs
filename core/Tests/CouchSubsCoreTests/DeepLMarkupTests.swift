// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Windows: CouchSubs.Translation.Tests/DeepLTranslatorTests (aynı kurallar).
final class DeepLMarkupTests: XCTestCase {
    // Phantom Blade Zero: "Soul" adı DeepL'e etiketle korunarak gider; "began" "Pegan" olmuyordu (2026-11-13).
    func testGlossaryNamesAreWrappedAndTextEscaped() throws {
        XCTAssertEqual(DeepLMarkup.wrap("Soul began <now> & here.", glossary: .builtIn), "<x>Soul</x> began &lt;now&gt; &amp; here.")
        XCTAssertNil(DeepLMarkup.wrap("Sell your soul.", glossary: .builtIn))
        let terms = try Glossary.parse(#"{ "terms": { "skill tree": "yetenek ağacı" } }"#)
        XCTAssertEqual(DeepLMarkup.wrap("Open the Skill Tree.", glossary: terms), "Open the <x>yetenek ağacı</x>.")
    }

    func testUnwrapRestoresPlainText() {
        XCTAssertEqual(DeepLMarkup.unwrap("<x>Soul</x> savaşmaya başladı &amp; &lt;koştu&gt;."), "Soul savaşmaya başladı & <koştu>.")
    }

    func testCacheKeyFollowsTheGlossaryOnlyForLinesWithTerms() {
        XCTAssertEqual(DeepLMarkup.cacheKey("Run.", glossary: .builtIn), "Run.")
        XCTAssertTrue(DeepLMarkup.cacheKey("Soul, run.", glossary: .builtIn).hasPrefix(Glossary.builtIn.fingerprint))
    }
}
