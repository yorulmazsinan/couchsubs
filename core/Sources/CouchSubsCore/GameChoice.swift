// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation

/// Mac ve iPhone uygulamasının "oynanan oyun" durumu (`GameSense` üzerine): ekrandaki "Oynanan oyun: X · Değiştir",
/// iki dakika sonra çıkan "Hangi oyunu oynuyorsunuz?" kartı ve kullanıcının seçimi. Seçim oturum boyunca geçerlidir ve
/// PS5'in adıyla saklanır; aynı PS5'te sonraki oturumda kartın ilk önerisi olur. Android'de GameSense.kt'deki
/// GameChoice, Windows'ta AppController aynı kurallarla çalışır.
@MainActor
public final class GameChoice: ObservableObject {
    /// Havuza giden oyun (bilinmiyorsa nil) ve nereden bilindiği.
    @Published public private(set) var game: RunningGame?
    @Published public private(set) var source: GameSense.Source?
    /// Kart açık.
    @Published public private(set) var asking = false
    /// Xbox'ta çeviri sürüyor ve oyun bilinmiyor: Xbox oynanan oyunu bildirmez; ana ekranda Oyun karosu vurgulanır ve
    /// "oyunu seçin" notu görünür (zorlayıcı kart açılmaz). Oyun seçilince kalkar.
    @Published public private(set) var xboxNeedsGame = false

    public let sense = GameSense()
    /// Oyun değişti (uygulama `LinePool.setGame`e bağlar).
    public var onChange: (RunningGame?) -> Void = { _ in }
    /// Oyun ya da nereden bilindiği her yayımlanışta (aynı oyun paketten sonra elle seçilince de): `GameAreas.follow`.
    public var onPublish: (RunningGame?, GameSense.Source?) -> Void = { _, _ in }
    /// Günlük satırı (uygulama `SubtitleLog.write`a bağlar).
    public var onLog: (String) -> Void = { _ in }
    /// Kurulu paketlerin oyun adları (öneriler için).
    public var packTitles: () -> [String] = { [] }
    /// Hazır paketler: kullanıcı elle oyun seçince satırlar yalnız o oyunun paketinde aranır (`GameSense.packLimit`).
    public var packs: GamePackLibrary? {
        didSet { packs?.limit(toGame: sense.packLimit) }
    }

    static let rememberedKey = "lastGames"
    /// Kart açık mı diye bakma aralığı.
    static let checkInterval: Duration = .seconds(15)

    private let defaults: UserDefaults
    private var console: String?
    private var xbox = false
    private var timer: Task<Void, Never>?
    /// Günlüğe son yazılan paket sınırı (`GameName.key`).
    private var loggedLimit: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Çeviri başladı. `console`: PS5'in adı (son oyun bununla hatırlanır); `xbox`: Xbox oturumu (son oyun
    /// `GameSense.xboxConsole` adıyla hatırlanır ve oyun bilinmiyorsa kendiliğinden kullanılır); `enabled`: soru ayarı ve
    /// ortak havuz açık mı.
    public func start(console: String?, xbox: Bool = false, enabled: @escaping @MainActor () -> Bool) {
        sense.startSession()
        self.xbox = xbox
        self.console = xbox ? GameSense.xboxConsole : console
        if xbox { onLog(sense.startXbox(lastChosen: lastPlayed)) }
        publish()
        timer?.cancel()
        let started = Date()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkInterval)
                guard let self, !Task.isCancelled else { return }
                if self.sense.shouldAsk(runningFor: Date().timeIntervalSince(started), enabled: enabled()) {
                    self.sense.markAsked()
                    self.asking = true
                    return
                }
            }
        }
    }

    /// Çeviri durdu: kart kapanır.
    public func stop() {
        sense.endSession()
        xbox = false
        xboxNeedsGame = false
        timer?.cancel()
        timer = nil
        asking = false
    }

    /// Ekrana bir satır geldi; `fromPack`: hazır paketten. Satırın yalnız tek pakette bulunan anahtarı varsa o pakete
    /// bir oy sayılır; son 20 satırın 5'i aynı paketten gelince oyun o paketin oyunudur.
    public func noteLine(fromPack: Bool, packs: GamePackLibrary) {
        let hit = packs.takeDistinctiveHit()
        guard sense.noteLine(pack: fromPack ? hit : nil) else { return }
        asking = false
        publish()
    }

    /// PS5'in keşif yanıtındaki oyun (yoksa nil).
    public func consoleReported(_ game: RunningGame?) {
        sense.setConsole(game)
        publish()
    }

    /// Kullanıcı bir oyun seçti ya da adını yazdı.
    public func choose(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        sense.choose(name)
        if let console {
            var saved = remembered
            saved[console] = RunningGame(name: name)?.name
            defaults.set(saved, forKey: Self.rememberedKey)
        }
        if xbox, let clean = RunningGame(name: name)?.name { onLog(GameSense.xboxChosenLog(clean)) }
        asking = false
        publish()
    }

    /// "Değiştir": kart elle açılır.
    public func ask() {
        sense.markAsked()
        asking = true
    }

    /// "Sorma": bu oturumda bir daha sorulmaz.
    public func dismiss() {
        sense.markAsked()
        asking = false
    }

    /// Bu PS5'te son seçilen oyun.
    public var lastPlayed: String? { console.flatMap { remembered[$0] } }

    public func suggestions(_ query: String) -> [String] {
        GameCatalog.suggestions(query: query, packs: packTitles(), last: lastPlayed)
    }

    private var remembered: [String: String] {
        defaults.dictionary(forKey: Self.rememberedKey) as? [String: String] ?? [:]
    }

    private func publish() {
        let limit = sense.packLimit
        packs?.limit(toGame: limit)
        // Seçilen oyunda hangi paketlerde aranacağı günlüğe bir kez yazılır (#1355: içe aktarılan paket okunmuyor mu?).
        if limit.map(GameName.key) != loggedLimit {
            loggedLimit = limit.map(GameName.key)
            if let line = packs?.limitLog(forGame: limit) { onLog(line) }
        }
        let current = sense.current
        source = sense.source
        let needs = xbox && current == nil
        if xboxNeedsGame != needs { xboxNeedsGame = needs }
        onPublish(current, source)
        guard current != game else { return }
        game = current
        onChange(current)
    }
}
