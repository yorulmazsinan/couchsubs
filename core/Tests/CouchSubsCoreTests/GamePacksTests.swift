// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(name)
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class PackKeyTests: XCTestCase {
    /// Windows ve paket hazırlayan Python betiği (canon.py) ile aynı sonuç: Fixtures/golden-vectors.json.
    func testGoldenVectors() throws {
        struct Vector: Decodable { let input: String; let canon: String; let key: String }
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: fixture("golden-vectors.json")))
        XCTAssertEqual(vectors.count, 15)
        for vector in vectors {
            XCTAssertEqual(PackKey.canon(vector.input), vector.canon, vector.input)
            XCTAssertEqual(PackKey.key(vector.input) ?? "", vector.key, vector.input)
        }
    }

    func testTagsLongerThanFortyCharactersStay() {
        XCTAssertEqual(PackKey.stripTags("a <b> c"), "a   c")
        let long = "<" + String(repeating: "x", count: 41) + ">"
        XCTAssertEqual(PackKey.stripTags(long), long)
        XCTAssertEqual(PackKey.stripTags("<" + String(repeating: "x", count: 40) + ">"), " ")
        XCTAssertEqual(PackKey.stripTags("a < b <i> c"), "a < b   c")
        XCTAssertEqual(PackKey.stripTags("<<b>>"), "< >")
    }
}

final class GamePackTests: XCTestCase {
    func testWrappedAndBareFormatsLoad() throws {
        let wrapped = try GamePack.decode(Data(contentsOf: fixture("pack-wrapped.json.gz")), name: "pack-wrapped")
        XCTAssertEqual(wrapped.id, "test-game")
        XCTAssertEqual(wrapped.title, "Test Game")
        XCTAssertEqual(wrapped.entries.count, 5)
        let bare = try GamePack.decode(Data(contentsOf: fixture("pack-bare.json.gz")), name: "pack-bare")
        XCTAssertEqual(bare.id, "pack-bare")
        XCTAssertEqual(bare.title, "pack-bare")
        XCTAssertEqual(bare.entries.count, 2)
    }

    func testPlainJSONIsAccepted() throws {
        let key = PackKey.key("Get back!")!
        let pack = try GamePack.decode(Data("{\"\(key)\": \"Geri çekil!\"}".utf8), name: "plain")
        XCTAssertEqual(pack.entries[PackKey.number(key)!], "Geri çekil!")
    }

    func testBrokenFilesAreRejected() {
        XCTAssertThrowsError(try GamePack.decode(Data("not json".utf8), name: "x"))
        XCTAssertThrowsError(try GamePack.decode(Data([0x1f, 0x8b, 8, 0] + [UInt8](repeating: 7, count: 30)), name: "x"))
        XCTAssertThrowsError(try GamePack.decode(Data("{\"format\":3,\"entries\":{\"0123456789abcdef\":\"x\"}}".utf8), name: "x"))
        XCTAssertThrowsError(try GamePack.decode(Data("{\"bad\":\"x\"}".utf8), name: "x"))
    }

    /// Paketteki Türkçede kalan biçim etiketleri TV'ye gitmez.
    func testTagsAreRemovedFromTurkish() throws {
        let pack = try GamePack.decode(Data(contentsOf: fixture("pack-wrapped.json.gz")), name: "x")
        let key = PackKey.number(PackKey.key("<b><h>SCANNATURI SPECIALE</></> KNIFE")!)!
        XCTAssertEqual(pack.entries[key], "SCANNATURI SPECIALE BIÇAĞI")
    }

    func testLibraryMergesBundledAndUserPacks() throws {
        let bundled = temporaryDirectory()
        let user = temporaryDirectory()
        try FileManager.default.copyItem(at: fixture("pack-bare.json.gz"), to: bundled.appendingPathComponent("a.json.gz"))
        try FileManager.default.copyItem(at: fixture("pack-wrapped.json.gz"), to: bundled.appendingPathComponent("b.json.gz"))
        try Data("bozuk".utf8).write(to: bundled.appendingPathComponent("c.json.gz"))
        let library = GamePackLibrary(bundled: bundled, user: user)
        XCTAssertEqual(library.packs.map(\.title), ["a", "Test Game"])
        XCTAssertEqual(library.packs.map(\.entries), [2, 5])
        // Aynı anahtarda sonraki paket kazanır.
        XCTAssertEqual(library.match("Get Down!")?.text, "Yere yat!")
        XCTAssertEqual(library.match("Get back!")?.text, "Geri çekil!")

        // Kullanıcının klasöründeki aynı kimlikli paket uygulamanınkinin yerine geçer ve sonra okunur.
        let key = PackKey.key("Get Down!")!
        let override = "{\"format\":1,\"id\":\"test-game\",\"title\":\"Test Game 2\",\"entries\":{\"\(key)\":\"Yat yere!\"}}"
        try Data(override.utf8).write(to: user.appendingPathComponent("test.json"))
        library.reload()
        XCTAssertEqual(library.packs.map(\.title), ["a", "Test Game 2"])
        XCTAssertEqual(library.packs.map(\.builtIn), [true, false])
        XCTAssertEqual(library.match("Get Down!")?.text, "Yat yere!")
        XCTAssertNil(library.match("Who is that?"))
    }

    /// İki küçük paket: Elden Ring ve RDR2, ikisinde de "Let's go.".
    private func eldenAndRdr() throws -> GamePackLibrary {
        let directory = temporaryDirectory()
        let common = PackKey.key("Let's go.")!
        let tarnished = PackKey.key("Rise, Tarnished.")!
        let horse = PackKey.key("Easy, girl.")!
        let elden = "{\"format\":1,\"id\":\"elden-ring\",\"title\":\"Elden Ring\",\"entries\":{\"\(common)\":\"Gidelim.\",\"\(tarnished)\":\"Kalk, Lekeli.\"}}"
        let rdr = "{\"format\":1,\"id\":\"rdr-2\",\"title\":\"Red Dead Redemption 2\",\"entries\":{\"\(common)\":\"Hadi gidelim.\",\"\(horse)\":\"Sakin ol kızım.\"}}"
        try Data(elden.utf8).write(to: directory.appendingPathComponent("a.json"))
        try Data(rdr.utf8).write(to: directory.appendingPathComponent("b.json"))
        return GamePackLibrary(bundled: directory, user: nil)
    }

    /// Elle seçilen oyunda satırlar yalnız o oyunun paketinde aranır; paketi yoksa hiç aranmaz. Başka oyunların ortak
    /// satırları ("Let's go.") yanlış çeviri getirmez, oyunu da o pakete kaydırmaz (#218).
    func testChosenGameLimitsTheSearchToItsPack() throws {
        let library = try eldenAndRdr()
        // Seçim yokken bütün paketlerde aranır, aynı satırda sonraki paket kazanır.
        XCTAssertEqual(library.match("Let's go.")?.text, "Hadi gidelim.")

        // Paketi olmayan oyun: hiçbir pakette aranmaz.
        library.limit(toGame: "Marvel's Wolverine")
        XCTAssertNil(library.match("Let's go."))
        XCTAssertNil(library.match("Rise, Tarnished."))
        XCTAssertNil(library.searchScope)
        XCTAssertNil(library.takeDistinctiveHit())

        // Paketi olan oyun: yalnız o paket, Türkçe de o paketin kendisinden.
        library.limit(toGame: "ELDEN RING")
        XCTAssertEqual(library.match("Let's go.")?.text, "Gidelim.")
        XCTAssertEqual(library.match("Rise, Tarnished.")?.text, "Kalk, Lekeli.")
        XCTAssertNil(library.match("Easy, girl."))
        XCTAssertEqual(library.searchScope, "elden-ring")
        XCTAssertEqual(library.takeDistinctiveHit()?.id, "elden-ring")

        // Seçim kalkınca yine bütün paketler.
        library.limit(toGame: nil)
        XCTAssertEqual(library.match("Easy, girl.")?.text, "Sakin ol kızım.")
    }

    /// GameChoice elle seçimi paketlere bildirir; PS5 oyun bildirince sınır kalkar.
    @MainActor
    func testGameChoiceLimitsPacksToTheChosenGame() throws {
        let library = try eldenAndRdr()
        let choice = GameChoice(defaults: try XCTUnwrap(UserDefaults(suiteName: "game-choice-\(UUID().uuidString)")))
        choice.packs = library
        choice.start(console: nil) { false }
        choice.choose("Marvel's Wolverine")
        XCTAssertNil(library.match("Let's go."))
        for _ in 0..<6 { choice.noteLine(fromPack: true, packs: library) }
        XCTAssertEqual(choice.game?.name, "Marvel's Wolverine")
        choice.consoleReported(RunningGame(titleId: "PPSA01234", name: "Red Dead Redemption 2"))
        XCTAssertEqual(library.match("Let's go.")?.text, "Hadi gidelim.")
        choice.stop()
    }

    func testMissingDirectoriesGiveAnEmptyLibrary() {
        let library = GamePackLibrary(bundled: nil, user: URL(fileURLWithPath: "/nonexistent/packs"))
        XCTAssertEqual(library.packs, [])
        XCTAssertNil(library.match("Get Down!"))
    }

    /// Yalnız tek bir gömülü paketle kitaplık: paketler birleşince ortak satırlarda ("Get down!") sonraki paket kazanır.
    private func bundledOnly(_ file: String) throws -> GamePackLibrary {
        let directory = temporaryDirectory()
        let source = try bundledTestPack(file)
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(file))
        return GamePackLibrary(bundled: directory, user: nil)
    }

    /// Uygulamayla gelen paketler (Mafia, GTA V, RDR2) birlikte yüklenir ve hızlı aranır.
    func testBundledPacksLoad() throws {
        _ = try bundledTestPack("gta-v.json.gz")
        let all = GamePackLibrary(bundled: GamePackLibrary.bundledDirectory, user: nil)
        let start = Date()
        let ids = all.packs.map(\.id)
        let elapsed = Date().timeIntervalSince(start)
        print("paket yükleme: \(Int(elapsed * 1000)) ms, \(all.packs.reduce(0) { $0 + $1.entries }) satır")
        XCTAssertEqual(ids, ["assassins-creed-shadows", "call-of-duty-modern-warfare-2019", "death-stranding-2", "elden-ring", "gta-v", "mafia-the-old-country", "marvels-spider-man-2", "red-dead-redemption-2"])
        XCTAssertTrue(all.packs.allSatisfy(\.builtIn))
        // Biçim 2 (parçalar ve imzalar) yüklemeyi Release'te ~%30 uzatıyor; Debug derlemede ve yüklü makinede daha yavaş.
        XCTAssertLessThan(elapsed, 30)

        let library = try bundledOnly("mafia-the-old-country.json.gz")
        let mafia = library.packs.first { $0.id == "mafia-the-old-country" }
        XCTAssertEqual(mafia?.title, "Mafia: The Old Country")
        XCTAssertGreaterThan(mafia?.entries ?? 0, 18000)
        XCTAssertEqual(mafia?.builtIn, true)
        XCTAssertEqual(library.match("You fucked up now, boy!")?.text, "Şimdi ayvayı yedin, evlat!")
        XCTAssertEqual(library.match("It’s his mother, she passed.")?.text, "Annesi vefat etti.")
        XCTAssertEqual(library.match("MARIA: Get Down!")?.text, "MARIA: Yere yat!")
        XCTAssertEqual(library.match("Get Down!\nMinchia! You shouldn't be allowed to ride!")?.text,
                       "Yere yat!\nMinchia! Sana at sürmeyi yasaklamak lazım!")
        let lookups = Date()
        for _ in 0..<1000 { _ = library.match("You fucked up now, boy!") }
        print("1000 arama: \(Int(Date().timeIntervalSince(lookups) * 1000)) ms")
    }

    /// Her gömülü paket kendi başına açılır, en az beklenen satırı taşır ve bilinen satırlar (anahtarlar canon.py ile
    /// hesaplandı) boş olmayan Türkçeye çıkar.
    func testEachBundledPackHasItsLines() throws {
        let expected: [(file: String, id: String, title: String, minimum: Int, keys: [String])] = [
            ("mafia-the-old-country.json.gz", "mafia-the-old-country", "Mafia: The Old Country", 18000,
             ["e7f18c8f6d1083ab", "15014c246455f36c"]),
            // "Are you listening to me?", "Cool, I'll see you later.", "Take out the Lost."
            ("gta-v.json.gz", "gta-v", "Grand Theft Auto V", 150_000,
             ["e43b873bf7992f8f", "cc57fc6e0542ca05", "aaa1a152be96d47f"]),
            // "Can't see where I'm going.", "I'm not afraid to fight you.", "Burn the tobacco fields"
            ("red-dead-redemption-2.json.gz", "red-dead-redemption-2", "Red Dead Redemption 2", 150_000,
             ["7fab2b68b3726a28", "3484a8ef3d8c7fc7", "bc0c9435160e8723"]),
            // "The Tarnished will soon return.", "Let it be Margit the Fell!", "Roundtable Hold"
            ("elden-ring.json.gz", "elden-ring", "Elden Ring + Shadow of the Erdtree", 37000,
             ["fd7b2bef9d7e5fe1", "d9e5d9f200bbd946", "d5017888c04251a9"]),
            // "More like sell yourself. It's the worst.", "You got any advice?", "Focus! Hunters! Lots of them!"
            ("marvels-spider-man-2.json.gz", "marvels-spider-man-2", "Marvel's Spider-Man 2", 2000,
             ["40236a7f701ea389", "ee2428652bc9ceb2", "e829f8ce088898b8"]),
        ]
        let directory = try bundledTestPack("gta-v.json.gz").deletingLastPathComponent()
        for pack in expected {
            let data = try Data(contentsOf: directory.appendingPathComponent(pack.file))
            let decoded = try GamePack.decode(data, name: GamePackLibrary.baseName(directory.appendingPathComponent(pack.file)))
            XCTAssertEqual(decoded.id, pack.id)
            XCTAssertEqual(decoded.title, pack.title)
            XCTAssertGreaterThan(decoded.entries.count, pack.minimum, pack.id)
            for key in pack.keys {
                let turkish = decoded.entries[try XCTUnwrap(PackKey.number(key))] ?? ""
                XCTAssertFalse(turkish.isEmpty, "\(pack.id) \(key)")
                XCTAssertFalse(turkish.contains("~"), "\(pack.id) \(key): \(turkish)")
            }
        }
    }

    /// Assassin's Creed Shadows, Death Stranding 2, Modern Warfare (2019), Elden Ring ve Marvel's
    /// Spider-Man 2 paketleri de uygulamayla gelir.
    func testMoreBundledPacksLoad() throws {
        _ = try bundledTestPack("assassins-creed-shadows.json.gz")
        let library = GamePackLibrary(bundled: GamePackLibrary.bundledDirectory, user: nil)
        let expected: [(id: String, title: String, minimum: Int)] = [
            ("assassins-creed-shadows", "Assassin's Creed Shadows", 39000),
            ("death-stranding-2", "Death Stranding 2: On the Beach", 23000),
            ("call-of-duty-modern-warfare-2019", "Call of Duty: Modern Warfare (2019)", 50000),
            ("elden-ring", "Elden Ring + Shadow of the Erdtree", 37000),
            ("marvels-spider-man-2", "Marvel's Spider-Man 2", 2000),
        ]
        for game in expected {
            let pack = library.packs.first { $0.id == game.id }
            XCTAssertEqual(pack?.title, game.title, game.id)
            XCTAssertGreaterThan(pack?.entries ?? 0, game.minimum, game.id)
            XCTAssertEqual(pack?.builtIn, true, game.id)
        }
        XCTAssertEqual(library.match("NAOE: Yagoro? What are you doing here?")?.text, "NAOE: Yagoro? Burada ne yapıyorsun?")
        // Sahne notu ("[laughs]") ekranda kalsa da kalmasa da aynı satır bulunur.
        let gnats = "Her yerdeler, biliyorsun, sinekler gibi! Ne arıyorsan bulacaksın. Naoe'me her zaman güvenebilirim."
        XCTAssertEqual(library.match("They are everywhere, you know, like gnats! Whatever it is, you will find it. I can always count on my Naoe.")?.text, gnats)
        XCTAssertEqual(library.match("They are everywhere, you know, like gnats! [laughs] Whatever it is, you will find it. I can always count on my Naoe.")?.text, gnats)
        XCTAssertEqual(library.match("Terminal Fort Knot is in danger. A voidout would kill them all!")?.text,
                       "Terminal Fort Knot tehlikede. Bir boşluk patlaması hepsini öldürür!")
        XCTAssertEqual(library.match("Requesting air drop on my position!")?.text, "Konumuma hava ikmali talep ediyorum!")
        XCTAssertEqual(library.match("The Tarnished will soon return.")?.text, "Lekeli yakında geri dönecek.")
        XCTAssertEqual(library.match("Margit, the Fell Omen")?.text, "Margit, Uğursuz Alâmet")
        XCTAssertEqual(library.match("Spider-Man: Focus! Hunters! Lots of them!")?.text, "Spider-Man: Odaklan! Avcılar! Çok fazlalar!")
    }
}

final class PackLookupTests: XCTestCase {
    private let pack: [String: String] = [
        PackKey.key("Get Down!")!: "Yere yat!",
        PackKey.key("Who is that?")!: "O da kim?",
        PackKey.key("Don Torrisi wants you.")!: "Don Torrisi seni istiyor.",
        PackKey.key("Get back!")!: "Geri çekil!",
    ]

    private func match(_ text: String) -> PackMatch? {
        PackLookup.match(text) { line in PackKey.key(line).flatMap { pack[$0] } }
    }

    func testWholeLineIgnoresCaseSpacingAndPunctuation() {
        XCTAssertEqual(match("GET DOWN!!")?.text, "Yere yat!")
        XCTAssertEqual(match("  Who   is\nthat?  ")?.text, "O da kim?")
        XCTAssertNil(match("Get out!"))
        XCTAssertNil(match(""))
    }

    func testSpeakerLabelIsKeptAndVoiced() {
        let found = match("ENZO: Don Torrisi wants you.")
        XCTAssertEqual(found?.text, "ENZO: Don Torrisi seni istiyor.")
        XCTAssertEqual(found?.spoken, [SpokenLine(speaker: "ENZO", english: "Don Torrisi wants you.", turkish: "Don Torrisi seni istiyor.")])
        XCTAssertEqual(match("Cesare: Get down!")?.text, "Cesare: Yere yat!")
        XCTAssertNil(match("ENZO: Get out!"))
    }

    func testEachLineIsLookedUpWhenTheWholeIsMissing() {
        XCTAssertEqual(match("ENZO: Get down!\nMARIA: Who is that?")?.text, "ENZO: Yere yat!\nMARIA: O da kim?")
        XCTAssertEqual(match("- Get down!\n- Who is that?")?.text, "- Yere yat!\n- O da kim?")
        // Bir satır bile eksikse paket kullanılmaz.
        XCTAssertNil(match("Get down!\nWho are you?"))
    }

    /// Altyazının bloğuna düşen köşe yazısı (GTA V'te bölge adı, kamera ipucu) atlanır; tek başına eşleşme sayılmaz.
    func testOverlayLineNextToTheSubtitleIsSkipped() {
        XCTAssertEqual(match("San Andreas\nWho is that?")?.text, "O da kim?")
        XCTAssertEqual(match("Get down!\nFirst Person • zoom")?.text, "Yere yat!")
        XCTAssertEqual(match("Get down!\nMirror Park\nWho is that?")?.text, "Yere yat!\nO da kim?")
        XCTAssertNil(match("San Andreas\nMirror Park"))
        XCTAssertNil(match("Get down!\nwho are you"))
        XCTAssertTrue(PackLookup.isOverlay("LOSNN"))
        XCTAssertFalse(PackLookup.isOverlay("Listen to me,"))
        XCTAssertFalse(PackLookup.isOverlay("Hey, Franklin!"))
    }

    /// Uzun satırdaki "•" OCR lekesidir: satır köşe yazısı sayılıp atlanmaz, yalnız ikinci satırın Türkçesi gelmez (#245).
    func testLongLineWithStrayBulletIsNotAnOverlay() {
        XCTAssertFalse(PackLookup.isOverlay("I have a business meeting there with a colleague• Not that it's anything to do"))
        XCTAssertNil(match("I have a business meeting there with a colleague• Not that it's anything to do\nWho is that?"))
    }

    func testEachSentenceIsLookedUpWhenTheLineIsMissing() {
        let found = match("ENZO: Get down! Who is that?")
        XCTAssertEqual(found?.text, "ENZO: Yere yat! O da kim?")
        XCTAssertEqual(found?.spoken.map(\.speaker), ["ENZO", "ENZO"])
        XCTAssertEqual(match("Get down! Get back!")?.text, "Yere yat! Geri çekil!")
        XCTAssertNil(match("Get down! Who are you?"))
    }

    func testWholeLineWinsOverParts() {
        let custom = [PackKey.key("Get down! Get back!")!: "Eğil ve geri çekil!", PackKey.key("Get Down!")!: "Yere yat!"]
        let found = PackLookup.match("Get down! Get back!") { PackKey.key($0).flatMap { custom[$0] } }
        XCTAssertEqual(found?.text, "Eğil ve geri çekil!")
    }

    /// OCR'ın bozduğu etiket ("-GAETANO:", "M]:", "li LUCA:") da atılıp aranır; ekranda olduğu gibi kalır.
    func testGarbledSpeakerLabelIsStripped() {
        XCTAssertEqual(match("-GAETANO: Don Torrisi wants you.")?.text, "- GAETANO: Don Torrisi seni istiyor.")
        XCTAssertEqual(match("- GAETANO: Don Torrisi wants you.")?.text, "- GAETANO: Don Torrisi seni istiyor.")
        XCTAssertEqual(match("M]: Get down!")?.text, "M]: Yere yat!")
        XCTAssertEqual(match("li LUCA: Who is that?")?.text, "li LUCA: O da kim?")
        XCTAssertEqual(match("SEBASTIAN Who is that?")?.text, "SEBASTIAN O da kim?")
        XCTAssertNil(match("I told you: get out!"))
    }

    /// Paket betiğiyle aynı gevşek etiket kuralı (Fixtures/fuzzy-vectors.json).
    func testLooseLabelVectors() throws {
        let vectors = try FuzzyVectors.load()
        for vector in vectors.looseLabels {
            let found = PackLookup.looseLabel(vector.input)
            XCTAssertEqual(found?.label, vector.label, vector.input)
            XCTAssertEqual(found?.body, vector.body, vector.input)
        }
    }

    /// Tam anahtar tutmazsa her parça önce tam, sonra bulanık aranır; tam satır her zaman önce gelir.
    func testNearestIsTriedOnlyAfterExactParts() {
        var asked: [String] = []
        let nearest: (String) -> String? = { line in
            asked.append(line)
            return line == "Who iz that?" ? "O da kim?" : nil
        }
        let found = PackLookup.match("ENZO: Get down! Who iz that?", find: { PackKey.key($0).flatMap { self.pack[$0] } },
                                     nearest: nearest)
        XCTAssertEqual(found?.text, "ENZO: Yere yat! O da kim?")
        XCTAssertEqual(PackLookup.match("GET DOWN!!", find: { PackKey.key($0).flatMap { self.pack[$0] } }, nearest: { _ in "x" })?.text,
                       "Yere yat!")
        XCTAssertFalse(asked.contains("Get down!"))
    }
}

/// Paket betiğinin (common.py) ürettiği ortak deneme verisi.
struct FuzzyVectors: Decodable {
    struct Signature: Decodable { let input: String; let folded: String; let damaged: Bool; let length: Int?; let bits: Int?; let bloom: String? }
    struct Pair: Decodable { let query: String; let entry: String; let bits: Int; let similarity: Double }
    struct Loose: Decodable { let input: String; let label: String?; let body: String? }
    struct Edit: Decodable { let input: String; let count: Int; let contains: [String]; let first: [String]; let last: [String] }
    struct Evidence: Decodable { let both: Int; let inQuery: Int; let inEntry: Int; let bits: Int; let query: Double; let entry: Double }
    struct Thresholds: Decodable { let minimumEvidence: Double; let cleanMissing: Int; let editLength: [Int] }
    let signatures: [Signature]
    let similarities: [Pair]
    let looseLabels: [Loose]
    let edits: [Edit]
    let evidence: [Evidence]
    let thresholds: Thresholds

    static func load() throws -> FuzzyVectors {
        try JSONDecoder().decode(FuzzyVectors.self, from: Data(contentsOf: fixture("fuzzy-vectors.json")))
    }
}

final class PackFuzzyTests: XCTestCase {
    /// İkinci tur düzeltmeler (yutulan harf, benzeyen harf, iki karışıklık) Android ve Windows'la aynı küme; arama
    /// anahtarları metinlerinkiyle aynı.
    func testEditVectors() throws {
        let vectors = try FuzzyVectors.load()
        XCTAssertEqual(vectors.thresholds.editLength, [PackFuzzy.editLength.minimum, PackFuzzy.editLength.maximum,
                                                       PackFuzzy.editLength.pairs])
        XCTAssertEqual(vectors.thresholds.minimumEvidence, PackFuzzy.minimumEvidence)
        XCTAssertEqual(vectors.thresholds.cleanMissing, PackFuzzy.cleanMissing)
        XCTAssertGreaterThanOrEqual(vectors.edits.count, 5)
        for vector in vectors.edits {
            let edits = PackFuzzy.edits(vector.input)
            XCTAssertEqual(edits.count, vector.count, vector.input)
            XCTAssertEqual(Array(edits.prefix(5)), vector.first, vector.input)
            XCTAssertEqual(Array(edits.suffix(5)), vector.last, vector.input)
            for expected in vector.contains { XCTAssertTrue(edits.contains(expected), expected) }
            XCTAssertEqual(PackFuzzy.editKeys(vector.input), Set(edits.compactMap(PackKey.canonNumber)), vector.input)
            XCTAssertTrue(Set(edits).isDisjoint(with: PackFuzzy.variants(vector.input)), vector.input)
        }
        for vector in vectors.evidence {
            let z = PackFuzzy.evidence(both: vector.both, inQuery: vector.inQuery, inEntry: vector.inEntry, bits: vector.bits)
            XCTAssertEqual(z.query, vector.query, accuracy: 1e-9)
            XCTAssertEqual(z.entry, vector.entry, accuracy: 1e-9)
        }
    }

    /// Ortak deneme paketi (Fixtures/pack-fuzzy.json.gz, paket betiğiyle yapıldı): tek harf hatası, yutulan harf, iki
    /// karışıklık, konuşmacı adı ve OCR izli uzun satır bulunur; pakette olmayan benzer satırlar ("Who sent him?",
    /// "We need to talk about your sister.") başka satıra eşlenmez. Android ve Windows aynı vakalarla aynı sonucu verir.
    func testSharedFuzzyPackCases() throws {
        struct Cases: Decodable {
            struct Case: Decodable { let screen: String; let turkish: String? }
            let warmUp: String
            let cases: [Case]
        }
        let fixtures = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: fixture("pack-fuzzy-cases.json")))
        let directory = temporaryDirectory()
        try FileManager.default.copyItem(at: fixture("pack-fuzzy.json.gz"), to: directory.appendingPathComponent("pack-fuzzy.json.gz"))
        let library = GamePackLibrary(bundled: directory, user: nil)
        XCTAssertNotNil(library.match(fixtures.warmUp))
        XCTAssertEqual(library.searchScope, "fuzzy-test")
        for item in fixtures.cases {
            XCTAssertEqual(library.match(item.screen)?.text, item.turkish, item.screen)
        }
    }

    /// İmza Windows ve paket betiğiyle bit bit aynı.
    func testSignatureVectors() throws {
        let vectors = try FuzzyVectors.load()
        XCTAssertGreaterThan(vectors.signatures.count, 10)
        for vector in vectors.signatures {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: PackFuzzy.folded(vector.input))
            XCTAssertEqual(String(view), vector.folded, vector.input)
            XCTAssertEqual(PackFuzzy.damaged(vector.input), vector.damaged, vector.input)
            let signature = PackFuzzy.signature(vector.input)
            XCTAssertEqual(signature?.length, vector.length, vector.input)
            XCTAssertEqual(signature.map { PackFuzzy.bits(forLength: $0.length) }, vector.bits, vector.input)
            XCTAssertEqual(signature?.bytes.map { String(format: "%02x", $0) }.joined(), vector.bloom, vector.input)
        }
        for pair in vectors.similarities {
            let query = PackFuzzy.bloom(PackFuzzy.trigramHashes(PackFuzzy.folded(pair.query)), bits: pair.bits)
            let entry = PackFuzzy.bloom(PackFuzzy.trigramHashes(PackFuzzy.folded(pair.entry)), bits: pair.bits)
            XCTAssertEqual(PackFuzzy.similarity(query, entry, offset: 0, bits: pair.bits), pair.similarity, accuracy: 1e-9, pair.query)
        }
    }

    /// Yalnız Mafia paketiyle kitaplık (birleşik kitaplıkta ortak satırlarda başka oyunun çevirisi kazanabilir).
    private func library(_ file: String) throws -> GamePackLibrary {
        let directory = temporaryDirectory()
        let source = try bundledTestPack(file)
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(file))
        return GamePackLibrary(bundled: directory, user: nil)
    }

    /// Kullanıcılardan gelen gerçek ıskalamalar (Mafia: The Old Country, OCR hatalı, parça parça ve etiketi bozuk
    /// satırlar): paket betiğinin Python karşılığıyla aynı Türkçe ya da hiç eşleşme (başka oyunların satırları).
    func testRealOcrMissesMatchLikeThePackScript() throws {
        struct Cases: Decodable {
            struct Case: Decodable { let screen: String; let turkish: String? }
            let warmUp: String
            let cases: [Case]
        }
        let fixtures = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: fixture("pack-matches.json")))
        XCTAssertGreaterThanOrEqual(fixtures.cases.count, 50)
        let library = try library("mafia-the-old-country.json.gz")
        XCTAssertNil(library.searchScope)
        XCTAssertNotNil(library.match(fixtures.warmUp))
        XCTAssertEqual(library.searchScope, "mafia-the-old-country")
        let start = Date()
        for item in fixtures.cases {
            XCTAssertEqual(library.match(item.screen)?.text, item.turkish, item.screen)
        }
        let elapsed = Date().timeIntervalSince(start) / Double(fixtures.cases.count)
        print("Mafia bulanık arama: satır başına \(String(format: "%.2f", elapsed * 1000)) ms")
    }

    /// Hiç tam eşleşme olmadan bulanık arama yapılmaz (hangi oyunun oynandığı belli değil).
    func testNoFuzzySearchBeforeTheGameIsKnown() throws {
        let library = try library("mafia-the-old-country.json.gz")
        let garbled = "GAETANO: All this will bébehind u soon: Uötil'then don't let any of these båétards getpyou, alrightiz:t"
        XCTAssertNil(library.match(garbled))
        XCTAssertNotNil(library.match("You fucked up now, boy!"))
        XCTAssertEqual(library.match(garbled)?.text,
                       "GAETANO: " + (library.match("All this will be behind us soon. Until then don’t let any of these bastards get to you, alright?")?.text ?? "-"))
    }

    /// Oynanan oyunun adı yapay zekâya gider: tam eşleşme olana dek yok, sonra eşleşen paketin başlığı.
    func testScopeTitleIsThePlayedGame() throws {
        let library = try library("mafia-the-old-country.json.gz")
        XCTAssertNil(library.scopeTitle)
        XCTAssertNotNil(library.match("You fucked up now, boy!"))
        let title = try XCTUnwrap(library.scopeTitle)
        XCTAssertFalse(title.isEmpty)
        XCTAssertEqual(title, library.packs.first?.title)
    }

    /// Biçim 2: oyunun ayrı gösterdiği [delay] parçaları, cümleler ve Türkçesi İngilizcesiyle aynı satırlar.
    func testVersionTwoSegmentsAreFound() throws {
        let library = try library("mafia-the-old-country.json.gz")
        XCTAssertNotNil(library.match("Che buono."))
        XCTAssertEqual(library.match("ENZO: Che buono.")?.text, "ENZO: Che buono.")
        XCTAssertNotNil(library.match("then clear the way for someone who does."))
        XCTAssertNotNil(library.match("I see. Well, please pass on my apologies for missing our appointment last week."))
        let data = try Data(contentsOf: bundledTestPack("mafia-the-old-country.json.gz"))
        let pack = try GamePack.decode(data, name: "mafia-the-old-country")
        XCTAssertGreaterThan(pack.segments.count, 10000)
        XCTAssertGreaterThan(pack.fuzzy?.count ?? 0, 20000)
    }

    /// GTA V oyuncularının gerçek ıskalamaları: kısa satırda tek harf hatası, yutulmuş kesme işareti, köşe yazısı,
    /// iki satırlık altyazının yalnız bir satırı ve başına çöp eklenmiş okuma da paketten bulunur.
    func testGtaOcrReadsAreFound() throws {
        let library = try library("gta-v.json.gz")
        XCTAssertNotNil(library.match("Are you listening to me?"))
        func same(_ screen: String, as line: String, file: StaticString = #filePath, lineNumber: UInt = #line) {
            let expected = library.match(line)?.text
            XCTAssertNotNil(expected, line, file: file, line: lineNumber)
            XCTAssertEqual(library.match(screen)?.text, expected, screen, file: file, line: lineNumber)
        }
        same("Somebody help rne!", as: "Somebody help me!")
        same("Yeah, well, well see.", as: "Yeah, well, we'll see.")
        same("You cant put a price on freedom.", as: "You can't put a price on freedom.")
        same("LOSNN\nI told him to leave it, Trevor.", as: "I told him to leave it, Trevor.")
        same("I can't do crap with this deathship right", as: "I can't do crap with this deathship right on top of me! Bring it down, T!")
        same("San Andreas LOSNN but it does mean he's got money to pay people who help him.",
             as: "but it does mean he's got money to pay people who help him.")
        XCTAssertNil(library.match("The quick brown fox jumps over the lazy dog near the river bank."))
        XCTAssertNil(library.match("Sauvage gentleman of the western plains"))
    }

    /// İki altyazı yan yana tek satır okununca yalnız birinin Türkçesi gösterilmez (ikinci cümle düşerdi); köşe yazısı
    /// ve çöp eklenmiş okuma yine bulunur.
    func testTwoSubtitlesReadAsOneLineAreNotHalfTranslated() throws {
        let library = try library("gta-v.json.gz")
        XCTAssertNotNil(library.match("Are you listening to me?"))
        let pairs = [
            ("Hey, look. Good shit on those contracts you been workin' on.", "But listen, I got some other work."),
            ("I'm calling it. Don't burn your eyes out.", "Bye, Dad."),
        ]
        for (first, second) in pairs {
            let alone = try XCTUnwrap(library.match(first)?.text, first)
            let found = library.match("\(first) \(second)")?.text
            XCTAssertNotEqual(found, alone, "\(first) \(second)")
            if let found, let other = library.match(second)?.text {
                XCTAssertTrue(found.contains(alone) && found.contains(other), found)
            }
        }
        XCTAssertEqual(PackFuzzy.clauses("Mirror Park Errr. Your broke. Call me back, okay? Bye, Dad."),
                       ["Mirror Park Errr.", "Your broke.", "Call me back,", "okay? Bye, Dad."])
        XCTAssertEqual(PackFuzzy.clauses("to escape... if we're able. You said seriously. nis seriously."),
                       ["to escape...", "if we're able.", "You said seriously. nis seriously."])
        XCTAssertNotNil(library.match("Your vehicle? Sorry, we can't get that sorted at this time. San Andreas"))
        XCTAssertNotNil(library.match("Vinewood Hills Just not my junk, okay? I'm already scarred down there."))
    }

    /// En büyük pakette (GTA V) bulanık arama da hızlı.
    func testFuzzySearchIsFastInTheLargestPack() throws {
        let library = try library("gta-v.json.gz")
        XCTAssertNotNil(library.match("Are you listening to me?"))
        let lines = ["Wh4t the fück are y0u doing here, man? Get öut of my house!", "Mich ael, I tbink we need to tälk about this",
                     "Yöu know what, Franklin? You're a good kid, but you gotta lısten", "Lâmar, get in the c ar, we're late!"]
        let start = Date()
        for _ in 0..<25 { for line in lines { _ = library.match(line) } }
        let elapsed = Date().timeIntervalSince(start) / 100
        print("GTA V bulanık arama: satır başına \(String(format: "%.2f", elapsed * 1000)) ms")
        // Bulunamayan satırda tek yönlü kapsama için daha geniş boy aralığı da taranır. Sürüm derlemesinde ~10 ms; sınır
        // hata ayıklama derlemesinde arka plan önceliğiyle (heavy-job) bütün testler birlikteyken ölçülen ~80 ms'ye göre.
        XCTAssertLessThan(elapsed, 0.12)
    }
}

/// Gerçek gömülü paketin yolu. Paketler depoda değil (özel R2, scripts/fetch-packs.py); inmemişse (dış katkıcı, yerel
/// geliştirici) gerçek paket testleri atlanır. CI paket sırlarıyla indirir ve bu testleri koşar.
func bundledTestPack(_ file: String) throws -> URL {
    guard let directory = GamePackLibrary.bundledDirectory,
          FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
        throw XCTSkip("gerçek paket yok (\(file)); scripts/fetch-packs.py ile indirilir")
    }
    return directory.appendingPathComponent(file)
}

