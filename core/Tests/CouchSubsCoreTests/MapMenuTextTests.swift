// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// Harita ekranının görev listesi ve kartı (#1365): arayüz etiketleri ("GOAL" → "Hedef"), görev başlığında özel ad
/// ("Kingpin Bowling'i Soy"), satır başındaki görev simgesi ("KM") ve güveni düşük okuma. Ortak deneme dosyası
/// Fixtures/map-menu-text.json (Windows MapMenuTextTests.cs, Android MapMenuTextTest.kt aynı).
final class MapMenuTextTests: XCTestCase {
    private struct Case: Decodable { let text: String; let expected: String? }
    private struct Badge: Decodable { let text: String; let box: [Double]; let expected: String; let left: Double }
    private struct Unsure: Decodable { let text: String; let confidence: Double?; let expected: Bool }
    private struct Vectors: Decodable {
        let labels: [Case]
        let missionTitles: [Case]
        let badges: [Badge]
        let unsure: [Unsure]
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("map-menu-text.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testLabelsAndMissionTitles() throws {
        let v = try vectors()
        for item in v.labels { XCTAssertEqual(UiCommands.translateLabel(item.text), item.expected, item.text) }
        for item in v.missionTitles { XCTAssertEqual(UiCommands.missionTitle(item.text), item.expected, item.text) }
    }

    func testBadgesAreNotText() throws {
        for item in try vectors().badges {
            let box = TextBox(left: item.box[0], top: item.box[1], right: item.box[2], bottom: item.box[3])
            let line = ScreenTranslation.withoutBadge(TextLine(item.text, box: box, confidence: 1))
            XCTAssertEqual(line.text, item.expected, item.text)
            XCTAssertEqual(line.box?.left ?? -1, item.left, accuracy: 1e-3, item.text)
            XCTAssertEqual(line.box?.right ?? -1, item.box[2], accuracy: 1e-9, item.text)
        }
    }

    func testUnsureReadsAreHeld() throws {
        for item in try vectors().unsure {
            XCTAssertEqual(ScreenTextNoise.isUnsure(TextLine(item.text, confidence: item.confidence)), item.expected, item.text)
        }
    }

    /// Menüdeki alanda güvensiz satır adaydan çıkar (çeviriye gitmez), simge satırın başından atılır; menü dışında
    /// dokunulmaz.
    @MainActor
    func testMenuCandidateDropsUnsureRowsAndBadges() {
        let region = CropRegion(top: 0, bottom: 0.6, left: 0, right: 0.4)
        let reading = Reading(lines: [
            TextLine("KM Collect Chemicals for Kyle", box: TextBox(left: 0.1, top: 0.30, right: 0.8, bottom: 0.36), confidence: 1),
            TextLine("scarch rol the onuin Ape", box: TextBox(left: 0.1, top: 0.40, right: 0.8, bottom: 0.46), confidence: 0.5),
            TextLine("Check out the Mud Club", box: TextBox(left: 0.1, top: 0.50, right: 0.8, bottom: 0.56), confidence: 1),
        ])
        let menu = RegionWatcher.candidate(reading, in: region, auto: true, menu: true)
        XCTAssertEqual(menu.unsure, ["scarch rol the onuin Ape"])
        XCTAssertFalse(menu.paragraphs.joined(separator: " ").contains("scarch"))
        XCTAssertFalse(menu.paragraphs.joined(separator: " ").contains("KM"))
        XCTAssertTrue(menu.paragraphs.joined(separator: " ").contains("Collect Chemicals for Kyle"))
        let outside = RegionWatcher.candidate(reading, in: region, auto: true, menu: false)
        XCTAssertTrue(outside.unsure.isEmpty)
    }
}
