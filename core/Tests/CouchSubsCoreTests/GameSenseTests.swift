// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

/// Yapay zekâya giden oyun adı kararlı oyundur (`GameSense.current`), son eşleşen paket değil: Android'deki
/// GameSenseTest ve Windows'taki GameSenseTests ile aynı örnekler (#27).
final class GameSenseTests: XCTestCase {
    private let gta = (id: "gta-v", title: "Grand Theft Auto V")
    private let rdr = (id: "rdr-2", title: "Red Dead Redemption 2")

    /// Tek bir yabancı satır oyunu değiştirmez; son 20 satırın 5'i başka paketten gelince oyun o olur.
    func testOneStrayLineDoesNotChangeTheGame() {
        let sense = GameSense()
        for _ in 0..<5 { sense.noteLine(packId: gta.id, title: gta.title) }
        XCTAssertEqual(sense.current?.name, gta.title)
        XCTAssertFalse(sense.noteLine(packId: rdr.id, title: rdr.title))
        XCTAssertEqual(sense.current?.name, gta.title)
        for _ in 0..<3 { XCTAssertFalse(sense.noteLine(packId: rdr.id, title: rdr.title)) }
        XCTAssertEqual(sense.current?.name, gta.title)
        XCTAssertTrue(sense.noteLine(packId: rdr.id, title: rdr.title))
        XCTAssertEqual(sense.current?.name, rdr.title)
    }

    /// Paketle tanınmayan oyunda ad gitmez; kullanıcı seçtiyse onun seçtiği, PS5 bildirdiyse PS5'in bildirdiği gider.
    func testWithoutAStableGameTheChosenNameOrNothingIsSent() {
        let sense = GameSense()
        for _ in 0..<4 { sense.noteLine(packId: rdr.id, title: rdr.title) }
        XCTAssertNil(sense.current)
        sense.choose(gta.title)
        XCTAssertEqual(sense.current?.name, gta.title)
        sense.setConsole(RunningGame(name: "Mafia: The Old Country"))
        XCTAssertEqual(sense.current?.name, "Mafia: The Old Country")
    }

    /// Elle seçilen oyun paket çoğunluğunun önüne geçer, PS5'in bildirdiğinin önüne geçmez; paket araması yalnız elle
    /// seçim geçerliyken o oyunla sınırlanır (#218).
    func testChosenGameBeatsThePackButNotTheConsole() {
        let sense = GameSense()
        sense.choose("Marvel's Wolverine")
        for _ in 0..<5 { sense.noteLine(packId: rdr.id, title: rdr.title) }
        XCTAssertEqual(sense.current?.name, "Marvel's Wolverine")
        XCTAssertEqual(sense.source, .user)
        XCTAssertEqual(sense.packLimit, "Marvel's Wolverine")
        sense.setConsole(RunningGame(name: "Mafia: The Old Country"))
        XCTAssertEqual(sense.current?.name, "Mafia: The Old Country")
        XCTAssertEqual(sense.source, .console)
        XCTAssertNil(sense.packLimit)
    }
}
