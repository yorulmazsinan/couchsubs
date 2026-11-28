// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Oynanan oyun. PS5'in keşif yanıtı çalışan oyunu çoğu zaman bildirmiyor (running-app-titleid boş); oyun üç yoldan
/// bilinir, öncelik sırasıyla: PS5'in bildirdiği (`setConsole`), kullanıcının elle seçtiği (`choose`) ve okunan satırların
/// art arda aynı hazır paketten gelmesi (son 20 satırın en az 5'i yalnız o pakette bulunan satırsa, `noteLine`). Elle seçim
/// paket çoğunluğunun önüne geçer: paketi olmayan oyunda ortak satırlar başka oyunun paketinden gelip oyunu
/// değiştirmesin (#218). Bilinen oyun ortak havuza giden satırlara eklenir (`LinePool.setGame`); sunucu aynı oyunun
/// satırlarını ayrı pakete toplar.
/// Hiçbiri yoksa çeviri başladıktan iki dakika sonra bir kez "Hangi oyunu oynuyorsunuz?" sorulur (`shouldAsk`).
/// Android'deki GameSense.kt ve Windows'taki CouchSubs.Core/GameSense.cs ile aynı kurallar.
public final class GameSense: @unchecked Sendable {
    /// `remembered`: kullanıcının önceki bir çeviri oturumunda seçtiği oyun (uygulama açık kaldıkça kalır). Kayıtlı
    /// alanlar bu oyunda sessizce uygulanmaz, sorulur: kullanıcı başka oyuna geçip seçimi değiştirmediyse eski oyunun
    /// profili uygulanıyor, yeni oyunda yapılan alan değişiklikleri de eski oyunun profiline kaydediliyordu.
    public enum Source: String, Sendable { case console, pack, user, remembered }

    /// Bakılan son satır sayısı ve tanımak için aynı paketten gelmesi gereken satır sayısı.
    public static let window = 20
    public static let threshold = 5
    /// Çeviri başladıktan bu kadar sonra oyun hâlâ bilinmiyorsa sorulur.
    public static let askAfter: TimeInterval = 120
    /// Oyunu bilinmeyen satırların ortak paketi (server/pool/src/autopack.js GENERAL): bir oyun değildir.
    static let generalPack = "pool-genel"

    private let lock = NSLock()
    private var recent: [String?] = []
    private var titles: [String: String] = [:]
    private var console: RunningGame?
    private var pack: RunningGame?
    private var packId: String?
    private var chosen: RunningGame?
    /// Seçim bir çeviri oturumu sürerken yapıldı; sonraki oturumda `remembered` sayılır.
    private var chosenWhileRunning = false
    /// Seçim önceki bir oturumdan kaldı (`remembered`).
    private var carried = false
    private var running = false
    private var asked = false
    /// Bu oturumda "telefon aranmıyor" satırı yazıldı (`shouldLogPhoneIdle`).
    private var phoneIdleLogged = false

    public init() {}

    /// Havuza giden oyun: PS5'in bildirdiği, yoksa kullanıcının seçtiği, yoksa paketten tanınan.
    public var current: RunningGame? { lock.withLock { console ?? chosen ?? pack } }

    public var source: Source? {
        lock.withLock { console != nil ? .console : chosen != nil ? (carried ? .remembered : .user) : pack != nil ? .pack : nil }
    }

    /// Paket aramasının sınırlanacağı oyun (`GamePackLibrary.limit(toGame:)`): kullanıcı elle seçtiyse ve PS5 bir oyun
    /// bildirmiyorsa seçilen oyunun adı; yoksa nil (bütün paketlerde aranır).
    public var packLimit: String? { lock.withLock { console == nil ? chosen?.name : nil } }

    /// Kullanıcının seçtiği oyunun adı (oturum boyunca).
    public var chosenName: String? { lock.withLock { chosen?.name } }

    /// Bir satır gösterildi. `packId`/`title`: satır yalnız tek bir pakette bulunan anahtarla geldiyse o paket
    /// (`GamePackLibrary.takeDistinctiveHit`), motorla çevrildiyse ya da birkaç pakette ortaksa nil. Oyun bu satırla yeni
    /// tanındıysa true.
    @discardableResult
    public func noteLine(packId: String?, title: String?) -> Bool {
        lock.withLock {
            let id = packId.flatMap { $0 == Self.generalPack ? nil : $0 }
            recent.append(id)
            if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
            guard let id else { return false }
            if let title { titles[id] = title }
            guard id != self.packId, recent.filter({ $0 == id }).count >= Self.threshold,
                  let game = RunningGame(name: titles[id] ?? id, titleId: Self.titleId(fromPack: id)) else { return false }
            pack = game
            self.packId = id
            return true
        }
    }

    @discardableResult
    public func noteLine(pack: GamePackLibrary.Info?) -> Bool { noteLine(packId: pack?.id, title: pack?.title) }

    /// PS5'in bildirdiği oyun (keşif yanıtı; bilinmiyorsa nil). PS5 elle seçilenden başka bir oyun bildirirse elle seçim
    /// eskimiştir ve silinir: yoksa PS5 bildirmeyi bırakınca (bağlantı kopunca) eski oyun geri gelir, paket araması da
    /// yine yalnız onun paketinde yapılır (#227 sonrası "oyun değişince eski oyunda kalıyor").
    public func setConsole(_ game: RunningGame?) {
        lock.withLock {
            console = game
            if let reported = game?.name, let picked = chosen?.name, GameName.key(reported) != GameName.key(picked) { chosen = nil }
        }
    }

    /// Kullanıcının seçimi ("Hangi oyunu oynuyorsunuz?" ya da "Değiştir"); nil seçimi siler.
    public func choose(_ name: String?) {
        lock.withLock {
            chosen = RunningGame(name: name)
            chosenWhileRunning = running
            carried = false
            asked = true
        }
    }

    /// Yeni çeviri oturumu: paket penceresi ve soru sıfırlanır; kullanıcının seçimi uygulama açık kaldıkça kalır. Önceki
    /// oturumda yapılan seçim bu oturumda `remembered` olur; çeviri dururken yapılan seçim (Ayarlar'da oyun profili
    /// seçildi) bu oturum içindir, `user` kalır.
    public func startSession() {
        lock.withLock {
            recent.removeAll()
            pack = nil
            packId = nil
            console = nil
            asked = false
            phoneIdleLogged = false
            carried = chosen != nil && chosenWhileRunning
            running = true
        }
    }

    /// Çeviri oturumu bitti.
    public func endSession() {
        lock.withLock { running = false }
    }

    /// Kart gösterilmeli mi: ayar açık, bu oturumda sorulmadı, oyun hiçbir yoldan bilinmiyor ve çeviri iki dakikadır sürüyor.
    public func shouldAsk(runningFor seconds: TimeInterval, enabled: Bool) -> Bool {
        lock.withLock {
            enabled && !asked && console == nil && pack == nil && chosen == nil && seconds >= Self.askAfter
        }
    }

    /// Kart gösterildi ya da "Sorma"ya basıldı: bu oturumda bir daha sorulmaz.
    public func markAsked() {
        lock.withLock { asked = true }
    }

    /// GTA 6 telefonu yalnız oyun GTA 6 olarak bilinince aranır. Telefon çevirisi açık, çeviri iki dakikadır sürüyor ve
    /// oyun hiçbir yoldan bilinmiyorsa oturumda bir kez true: günlüğe `phoneIdleLog` yazılır (#1443: telefon hiç
    /// aranmıyordu, günlükte tek satır yoktu). Windows ve Android ile aynı kural.
    public func shouldLogPhoneIdle(runningFor seconds: TimeInterval, readsPhone: Bool) -> Bool {
        lock.withLock {
            guard readsPhone, !phoneIdleLogged, console == nil, pack == nil, chosen == nil, seconds >= Self.askAfter else { return false }
            phoneIdleLogged = true
            return true
        }
    }

    public static let phoneIdleLog = "telefon aranmıyor: oynanan oyun bilinmiyor (PS5 bildirmedi, okunan satırlar bir oyun paketiyle eşleşmedi); GTA 6 telefonu için ana ekrandan oyunu seçin"
    /// Oyun okunan satırlardan tanındı (paketler kapalıyken de, #1443).
    public static func recognizedLog(_ name: String) -> String { "oyun okunan satırlardan tanındı: \(name)" }

    /// Xbox'ta son seçilen oyunun saklandığı ad (`lastGames` kaydında; Xbox'un adından bağımsız, Xbox'a özel).
    public static let xboxConsole = "Xbox"

    /// Xbox çevirisi başladı. Xbox çalışan oyunu bildirmez: oyun başka yoldan bilinmiyorsa kullanıcının Xbox için son
    /// seçtiği oyun (`lastChosen`) kendiliğinden kullanılır (`remembered`; ana ekranda görünür, değiştirilebilir). Hiç
    /// seçim yoksa oyuna özel okumalar (GTA 6 telefonu) kapalı kalır. Günlüğe yazılacak tek satırı döndürür (Windows,
    /// Android ile aynı metin).
    @discardableResult
    public func startXbox(lastChosen: String?) -> String {
        lock.withLock {
            if console == nil, chosen == nil, pack == nil, let game = RunningGame(name: lastChosen) {
                chosen = game
                carried = true
                chosenWhileRunning = true
                asked = true
            }
            guard let name = (console ?? chosen ?? pack)?.name else { return Self.xboxUnknownLog }
            return Self.xboxRecalledLog(name)
        }
    }

    public static let xboxUnknownLog = "Xbox: oyun tanınmadı, oyuna özel okumalar (telefon) kapalı"
    public static func xboxRecalledLog(_ name: String) -> String { "Xbox: son seçilen oyun kullanılıyor: \(name)" }
    public static func xboxChosenLog(_ name: String) -> String { "Xbox: oyun elle seçildi: \(name)" }

    /// Kimliğiyle toplanmış otomatik paket ("pool-ppsa01234", "pool-cusa00419-00") oyunun kimliğini taşır.
    static func titleId(fromPack id: String) -> String? {
        guard id.hasPrefix("pool-") else { return nil }
        return RunningGame.normalizedTitleId(String(id.dropFirst(5)).replacingOccurrences(of: "-", with: "_"))
    }
}

/// Oyun adının karşılaştırma anahtarı (sunucudaki server/pool/src/games.js gameKey ile aynı): küçük harf, aksansız,
/// noktalama yok, Roma rakamı sayıya, bilinen uzun adlar kısaltmaya. "Grand Theft Auto VI" ve "GTA 6" → "gta 6".
public enum GameName {
    static let aliases: [(String, String)] = [
        ("grand theft auto", "gta"), ("call of duty", "cod"), ("red dead redemption", "rdr"), ("ea sports fc", "fc"),
        ("ea sports", ""),
    ]
    static let roman: [String: String] = [
        "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10", "xi": "11",
        "xii": "12", "xiii": "13", "xiv": "14", "xv": "15", "xvi": "16",
    ]

    public static func key(_ value: String) -> String {
        // Marka işaretleri önce atılır (NFKD "™"yi "TM" yapar).
        let marks = value.replacingOccurrences(of: "[™®©]", with: " ", options: .regularExpression)
        let folded = marks.decomposedStringWithCompatibilityMapping.lowercased()
        var text = ""
        var previous: Character?
        for scalar in folded.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .spacingMark
                || scalar.properties.generalCategory == .enclosingMark { continue }
            if "'’`".unicodeScalars.contains(scalar) { continue }
            var character = Character(scalar == "ı" ? "i" : scalar)
            if character == "&" {
                text += " and "
                previous = " "
                continue
            }
            let alphanumeric = character.isLetter || character.isNumber
            if !alphanumeric { character = " " }
            // "gta6" → "gta 6" (harf ve rakam ayrılır).
            if let previous, alphanumeric, (previous.isLetter && character.isNumber) || (previous.isNumber && character.isLetter) {
                text += " "
            }
            text.append(character)
            previous = character
        }
        let rawWords = text.split(separator: " ").map(String.init)
        // Preserve literal franchise letters but keep established Roman sequel keys.
        let megaManX = rawWords.count >= 3 && Array(rawWords.prefix(3)) == ["mega", "man", "x"]
        var words = rawWords.enumerated().map { index, word in
            let next = index + 1 < rawWords.count ? rawWords[index + 1] : ""
            let literal = (word == "x" && ((megaManX && index == 2) || next == "men"))
                || (word == "v" && next == "rally")
            return literal ? word : (roman[word] ?? word)
        }
        if words.first == "the", words.count > 1 { words.removeFirst() }
        var joined = " " + words.joined(separator: " ") + " "
        for (long, short) in aliases {
            joined = joined.replacingOccurrences(of: " \(long) ", with: short.isEmpty ? " " : " \(short) ")
        }
        let result = joined.split(separator: " ").joined(separator: " ")
        return String(result.prefix(80)).trimmingCharacters(in: .whitespaces)
    }
}

/// "Hangi oyunu oynuyorsunuz?" kartının önerileri: son oynanan, kurulu paketlerin oyunları ve popüler oyunlar.
public enum GameCatalog {
    /// Paketi olmayan ama çok oynanan ya da yeni çıkan oyunlar (Android ve Windows'ta aynı liste).
    public static let popular: [String] = [
        "Grand Theft Auto VI", "Grand Theft Auto V", "Red Dead Redemption 2", "Ghost of Yōtei", "Marvel's Spider-Man 2",
        "Death Stranding 2: On the Beach", "Elden Ring", "Elden Ring Nightreign", "Assassin's Creed Shadows",
        "Call of Duty: Black Ops 7", "Call of Duty: Black Ops 6", "Battlefield 6", "EA Sports FC 26",
        "Mafia: The Old Country", "The Last of Us Part II Remastered", "God of War Ragnarök", "Cyberpunk 2077",
        "Hogwarts Legacy", "Resident Evil Requiem", "Silent Hill f", "Metal Gear Solid Delta: Snake Eater", "Borderlands 4",
        "Kingdom Come: Deliverance II", "Clair Obscur: Expedition 33", "Final Fantasy VII Rebirth", "Stellar Blade",
        "Black Myth: Wukong", "Baldur's Gate 3", "Horizon Forbidden West", "Alan Wake 2",
        "Indiana Jones and the Great Circle", "Dying Light: The Beast", "Ghost of Tsushima", "Star Wars Outlaws",
        "The Witcher 3: Wild Hunt", "Monster Hunter Wilds", "Split Fiction", "Hollow Knight: Silksong",
        "Marvel's Wolverine", "Assassin's Creed Mirage", "Assassin's Creed Valhalla", "Assassin's Creed Odyssey",
        "Assassin's Creed Origins", "Call of Duty: Modern Warfare III", "Call of Duty: Modern Warfare II",
        "Call of Duty: Warzone", "Resident Evil 4", "Resident Evil Village", "Resident Evil 2", "Resident Evil 3",
        "Resident Evil 7: Biohazard", "Silent Hill 2", "The Last of Us Part I", "God of War",
    ]

    /// Öneriler (en çok `limit`): önce son oynanan, sonra paketlerin oyunları, sonra popüler oyunlar; aynı oyun bir kez.
    /// Arama yazılmışsa adı ya da anahtarı aramayı içerenler, adı aramayla başlayanlar önde.
    public static func suggestions(query: String, packs: [String], last: String?, limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var all: [String] = []
        for name in [last].compactMap({ $0 }) + packs + popular {
            let key = GameName.key(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            all.append(name)
        }
        let wanted = GameName.key(query)
        guard !wanted.isEmpty else { return Array(all.prefix(limit)) }
        let found = all.filter { GameName.key($0).contains(wanted) }
        let first = found.filter { GameName.key($0).hasPrefix(wanted) }
        return Array((first + found.filter { !GameName.key($0).hasPrefix(wanted) }).prefix(limit))
    }

    /// Paket listesinden oyun adları (ortak havuz paketi bir oyun değildir; asıl paketi olan oyunun "(ek satırlar)"
    /// paketi de ayrı oyun değildir, server/pool/src/autopack.js packTitle).
    public static func packGames(_ packs: [GamePackLibrary.Info]) -> [String] {
        packs.filter { $0.id != GameSense.generalPack && !$0.title.hasSuffix("(ek satırlar)") }.map(\.title)
    }

    /// Havuzdan her gece üretilen ek paketin adındaki ek (server/pool/src/games.js EXTRA_SUFFIX).
    public static let extraSuffix = " (ek satırlar)"

    /// Paketler ekranındaki karolar: oyunun asıl paketi ve havuzdan gelen "(ek satırlar)" paketi tek karoda birleşir
    /// (#353: RDR2 ve Spider-Man 2 iki kez görünüyordu). Asıl paketi olmayan ek paket kendi karosunda kalır. Sıra korunur.
    public static func packShelf(_ packs: [GamePackLibrary.Info]) -> [PackShelfItem] {
        packShelf(packs, id: \.id, title: \.title, entries: \.entries)
    }

    public static func packShelf<T>(_ packs: [T], id: (T) -> String, title: (T) -> String, entries: (T) -> Int) -> [PackShelfItem] {
        var items: [PackShelfItem] = []
        var index: [String: Int] = [:]
        for pack in packs where !title(pack).hasSuffix(extraSuffix) {
            let key = GameName.key(title(pack))
            if index[key] == nil { index[key] = items.count }
            items.append(PackShelfItem(id: id(pack), title: title(pack), entries: entries(pack), packIds: [id(pack)], titles: [title(pack)]))
        }
        for pack in packs where title(pack).hasSuffix(extraSuffix) {
            let base = String(title(pack).dropLast(extraSuffix.count))
            if let at = index[GameName.key(base)] {
                let main = items[at]
                items[at] = PackShelfItem(id: main.id, title: main.title, entries: main.entries + entries(pack),
                                          packIds: main.packIds + [id(pack)], titles: main.titles + [title(pack)])
            } else {
                items.append(PackShelfItem(id: id(pack), title: title(pack), entries: entries(pack), packIds: [id(pack)], titles: [title(pack)]))
            }
        }
        // Asıl paketler önce, eşi olmayan ek paketler sonda; listedeki ilk sıraya geri dönülür.
        let order = Dictionary(packs.enumerated().map { (id($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
        return items.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }
}

/// Paketler ekranında bir oyun: kimliği ve adı asıl paketin; satır sayısı ve kimlikler ek paketle birlikte.
public struct PackShelfItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let entries: Int
    /// Karo açılıp kapanınca hepsi birlikte değişir.
    public let packIds: [String]
    /// Okuma hattının kullandığı paket adı bunlardan biriyse karo "Oynanıyor" olur.
    public let titles: [String]

    public init(id: String, title: String, entries: Int, packIds: [String], titles: [String]) {
        self.id = id
        self.title = title
        self.entries = entries
        self.packIds = packIds
        self.titles = titles
    }
}
