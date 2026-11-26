// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Arayüz sözlüğü: tuş çubuğu komutu sözlükteki biçimiyle ("Hedef belirle"), menü etiketi özgünün biçimiyle Türkçe
/// kurallarıyla ("İSTATİSTİKLER", "KIYAFETLER"). Ortak vakalar Fixtures/ui-commands.json (Windows UiCommandsTests.cs ve
/// Android UiCommandsTest.kt aynı dosyayı okur).
final class UiCommandsTests: XCTestCase {
    private struct Case: Decodable { let text: String; let expected: String? }
    private struct Vectors: Decodable {
        let translate: [Case]
        let translateLabel: [Case]
        let translateLabelLoosely: [Case]
        let withoutKeyGlyph: [Case]
    }

    func testSharedCasesMatchWindowsAndAndroid() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("ui-commands.json")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        let checks: [(String, [Case], (String) -> String?)] = [
            ("translate", vectors.translate, UiCommands.translate),
            ("translateLabel", vectors.translateLabel, UiCommands.translateLabel),
            ("translateLabelLoosely", vectors.translateLabelLoosely, UiCommands.translateLabelLoosely),
            ("withoutKeyGlyph", vectors.withoutKeyGlyph, { UiCommands.withoutKeyGlyph($0) }),
        ]
        for (name, cases, function) in checks {
            XCTAssertGreaterThanOrEqual(cases.count, 5, name)
            for item in cases { XCTAssertEqual(function(item.text), item.expected, "\(name)(\"\(item.text)\")") }
        }
    }
}
