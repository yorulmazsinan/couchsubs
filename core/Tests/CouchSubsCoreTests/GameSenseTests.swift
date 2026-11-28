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
        // PS5 başka oyun bildirdiyse elle seçim eskidi: PS5 bildirmeyi bırakınca eski seçim geri gelmez (paketten tanınan gelir), arama sınırlanmaz.
        sense.setConsole(nil)
        XCTAssertEqual(sense.current?.name, rdr.title)
        XCTAssertNil(sense.packLimit)
    }

    /// PS5 elle seçilen oyunu bildirirse (adı aynı) seçim kalır.
    func testSameGameFromTheConsoleKeepsTheChoice() {
        let sense = GameSense()
        sense.choose("GTA 5")
        sense.setConsole(RunningGame(name: "Grand Theft Auto V"))
        sense.setConsole(nil)
        XCTAssertEqual(sense.current?.name, "GTA 5")
        XCTAssertEqual(sense.packLimit, "GTA 5")
    }

    /// #1443: telefon çevirisi açıkken oyun iki dakikada tanınmazsa oturumda bir kez "telefon aranmıyor" yazılır; oyun
    /// biliniyorsa ya da telefon kapalıysa yazılmaz (Windows GameSenseTests, Android GameSenseTest ile aynı).
    func testPhoneIdleIsLoggedOncePerSessionWhileTheGameIsUnknown() {
        let sense = GameSense()
        sense.startSession()
        XCTAssertFalse(sense.shouldLogPhoneIdle(runningFor: 60, readsPhone: true))
        XCTAssertFalse(sense.shouldLogPhoneIdle(runningFor: 130, readsPhone: false))
        XCTAssertTrue(sense.shouldLogPhoneIdle(runningFor: 130, readsPhone: true))
        XCTAssertFalse(sense.shouldLogPhoneIdle(runningFor: 145, readsPhone: true))
        sense.startSession()
        sense.choose("GTA 6")
        XCTAssertFalse(sense.shouldLogPhoneIdle(runningFor: 130, readsPhone: true))
        XCTAssertTrue(GameSense.phoneIdleLog.hasPrefix("telefon aranmıyor: oynanan oyun bilinmiyor"))
    }

    /// Xbox çalışan oyunu bildirmez: Xbox için son seçilen oyun kendiliğinden kullanılır (hatırlanan; değiştirilebilir),
    /// hiç seçim yoksa oyun bilinmez ve günlüğe tek satır yazılır (Windows GameSenseTests, Android GameSenseTest ile aynı).
    func testXboxStartUsesTheLastChosenGameOrLogsThatTheGameIsUnknown() {
        let fresh = GameSense()
        fresh.startSession()
        XCTAssertEqual(fresh.startXbox(lastChosen: nil), "Xbox: oyun tanınmadı, oyuna özel okumalar (telefon) kapalı")
        XCTAssertNil(fresh.current)
        fresh.choose("Grand Theft Auto VI")
        XCTAssertEqual(GameName.key(fresh.current?.name ?? ""), "gta 6")
        XCTAssertEqual(GameSense.xboxChosenLog("Grand Theft Auto VI"), "Xbox: oyun elle seçildi: Grand Theft Auto VI")

        let returning = GameSense()
        returning.startSession()
        XCTAssertEqual(returning.startXbox(lastChosen: "Grand Theft Auto VI"), "Xbox: son seçilen oyun kullanılıyor: Grand Theft Auto VI")
        XCTAssertEqual(returning.current?.name, "Grand Theft Auto VI")
        XCTAssertEqual(returning.source, .remembered)
        XCTAssertFalse(returning.shouldAsk(runningFor: 600, enabled: true))
        // Kullanıcı değiştirebilir.
        returning.choose("Red Dead Redemption 2")
        XCTAssertEqual(returning.current?.name, "Red Dead Redemption 2")
        XCTAssertEqual(returning.source, .user)

        // Bu çalışmada zaten seçilmiş oyun kayıtlı olanın önüne geçer.
        let running = GameSense()
        running.choose("Elden Ring")
        running.startSession()
        running.startXbox(lastChosen: "Grand Theft Auto VI")
        XCTAssertEqual(running.current?.name, "Elden Ring")
    }

    func testLiteralRomanLettersDoNotCollideWithNumberedSequels() {
        XCTAssertEqual(GameName.key("Mega Man X"), "mega man x")
        XCTAssertNotEqual(GameName.key("Mega Man X"), GameName.key("Mega Man 10"))
        XCTAssertEqual(GameName.key("X-Men"), "x men")
        XCTAssertEqual(GameName.key("V-Rally"), "v rally")
        XCTAssertEqual(GameName.key("Mega Man X2"), "mega man x 2")
        XCTAssertEqual(GameName.key("GTA V"), "gta 5")
        XCTAssertEqual(GameName.key("Grand Theft Auto V Enhanced"), "gta 5 enhanced")
        XCTAssertEqual(GameName.key("GTA V Premium Edition"), "gta 5 premium edition")
        XCTAssertEqual(GameName.key("Final Fantasy X HD"), "final fantasy 10 hd")
        XCTAssertEqual(GameName.key("Mega Man X HD"), "mega man x hd")
        XCTAssertEqual(GameName.key("X-Men Origins: Wolverine"), "x men origins wolverine")
        XCTAssertEqual(GameName.key("V-Rally 4"), "v rally 4")
        XCTAssertEqual(GameName.key("Final Fantasy X"), "final fantasy 10")
    }

    /// #353: canlı listedeki RDR2 ve Spider-Man 2 asıl paketle "(ek satırlar)" paketi olarak iki kez görünüyordu; tek karo
    /// olur, satırlar toplanır, iki kimlik birlikte açılıp kapanır. Asıl paketi olmayan ek paket kendi karosunda kalır.
    func testPackShelfFoldsExtraLinesIntoMainPack() {
        let packs = [
            GamePackLibrary.Info(id: "marvels-spider-man-2", title: "Marvel's Spider-Man 2", entries: 2349, builtIn: false),
            GamePackLibrary.Info(id: "pool-marvels-spider-man-2", title: "Marvel's Spider-Man 2 (ek satırlar)", entries: 425, builtIn: false),
            GamePackLibrary.Info(id: "pool-rdr-2", title: "Red Dead Redemption 2 (ek satırlar)", entries: 481, builtIn: false),
            GamePackLibrary.Info(id: "red-dead-redemption-2", title: "Red Dead Redemption 2", entries: 195_430, builtIn: true),
            GamePackLibrary.Info(id: "pool-ppsa09999", title: "Ghost of Yōtei (ek satırlar)", entries: 40, builtIn: false),
        ]
        let shelf = GameCatalog.packShelf(packs)
        XCTAssertEqual(shelf.map(\.id), ["marvels-spider-man-2", "red-dead-redemption-2", "pool-ppsa09999"])
        XCTAssertEqual(shelf[0].entries, 2774)
        XCTAssertEqual(shelf[0].packIds, ["marvels-spider-man-2", "pool-marvels-spider-man-2"])
        XCTAssertEqual(shelf[1].title, "Red Dead Redemption 2")
        XCTAssertEqual(shelf[1].entries, 195_911)
        XCTAssertTrue(shelf[1].titles.contains("Red Dead Redemption 2 (ek satırlar)"))
        XCTAssertEqual(shelf[2].packIds, ["pool-ppsa09999"])
    }
}
