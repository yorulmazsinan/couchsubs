// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// Telefon uygulaması uzun oyunda (40-45 dk) kendiliğinden kapanıyordu ve iz bırakmıyordu (YouTube bildirimi):
/// sağlık satırı ve durdurulmadan biten oturumun kaydı.
final class SessionHealthTests: XCTestCase {
    func testLineNamesDurationMemoryWarningsAndHeat() {
        XCTAssertEqual(SessionHealth.line(minutes: 40, memoryMB: 812, availableMB: 310, memoryWarnings: 2, thermal: 2),
                       "oturum 40 dk; bellek 812 MB (boş 310 MB); bellek uyarısı 2; ısı yüksek")
        XCTAssertEqual(SessionHealth.line(minutes: -1, memoryMB: 300, availableMB: nil, memoryWarnings: 0, thermal: 0),
                       "oturum 0 dk; bellek 300 MB; bellek uyarısı 0; ısı normal")
        XCTAssertEqual(SessionHealth.thermalName(1), "orta")
        XCTAssertEqual(SessionHealth.thermalName(3), "kritik")
        XCTAssertEqual(SessionHealth.thermalName(6), "kritik")
    }

    func testMarkLeftBehindIsReportedOnceAndClearedMarkIsNot() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "session-health-\(UUID())"))
        XCTAssertNil(SessionHealth.unexpectedEnd(SessionHealth.loadMark(defaults)))

        let mark = SessionHealth.Mark(startedAt: Date(timeIntervalSince1970: 100),
                                      lastLine: "oturum 40 dk; bellek 812 MB; bellek uyarısı 1; ısı yüksek")
        SessionHealth.saveMark(mark, defaults)
        XCTAssertEqual(SessionHealth.loadMark(defaults), mark)
        XCTAssertEqual(SessionHealth.unexpectedEnd(SessionHealth.loadMark(defaults)),
                       "Önceki çeviri oturumu durdurulmadan bitti (ön planda); son durum: oturum 40 dk; bellek 812 MB; bellek uyarısı 1; ısı yüksek")

        SessionHealth.saveMark(SessionHealth.Mark(startedAt: Date(), background: true), defaults)
        XCTAssertEqual(SessionHealth.unexpectedEnd(SessionHealth.loadMark(defaults)),
                       "Önceki çeviri oturumu durdurulmadan bitti (arka planda); son durum: ilk 10 dk içinde")

        SessionHealth.saveMark(nil, defaults)
        XCTAssertNil(SessionHealth.loadMark(defaults))
    }

    func testFootprintIsMeasured() {
        XCTAssertGreaterThan(SessionHealth.footprintMB(), 0)
    }
}
