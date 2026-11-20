// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Ek alanların çevirisini TV'ye ileten taraf (gerçekte `SubtitleServer`).
public protocol RegionSending: AnyObject {
    /// `text` boşsa alanın kutusu kalkar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?)
    /// Çevirinin içinde kumanda simgeleri varsa (`ButtonIcons`); simgeyi bilmeyen gönderici düz metni yollar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?)
    /// Alanda birbirinden ayrı duran yazı grupları varsa (görev başlığı ve ayrı sütundaki hedef) `blocks` her grubun
    /// çevirisini kendi yeriyle taşır; TV her birini kendi İngilizce yazısının üstüne koyar. Blokları bilmeyen gönderici
    /// birleşik metni yollar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                    blocks: [ScreenTranslation.Item]?)
    func clearRegions()
}

extension RegionSending {
    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight)
    }

    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                           blocks: [ScreenTranslation.Item]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons)
    }
}

extension SubtitleServer: RegionSending {}

/// Ek alanları (görev yazısı, telefon mesajı, bildirim) ana altyazıdan ayrı ve seyrek okur, çevirip TV'ye kendi
/// yerleriyle gönderir (Windows: CouchSubs.Core/RegionWatcher.cs ile aynı kurallar).
///
/// - Ana okuma hattını beklemez, onu da bekletmez: `offer` hemen döner; tur ayrı bir görevde ve düşük öncelikle sürer.
/// - En çok `intervalMs`'te bir tur atılır; önceki tur (okuma ya da çeviri) bitmediyse kare atlanır.
/// - Bölge izi (`RegionCropper.signature`) değişmeyen alan yeniden okunmaz.
/// - Okunan yazı ancak kararlıysa çevrilir: iz bir tur değişmeden kaldıysa ya da iki okuma aynı yazıyı verdiyse (arkası
///   kıpırdayan köşe yazıları). Böylece belirirken yarım okunan yazı çevrilmez.
/// - Yazı değişmedikçe yeniden çevrilmez; boşalan alanın kutusu kalkar.
/// - Paket eşleşmesi ve çeviri motoru ana altyazıyla aynıdır; ama ek alan satırları ortak havuza önerilmez (arayüz
///   yazıları havuzu kirletmesin).
@MainActor
public final class RegionWatcher {
    /// Ek alanlar altyazıyla aynı seri OCR kuyruğunu kullanır. Mac ve iPhone'da saniyede en çok bir tur çalışır.
    public static let defaultIntervalMs = 1000

    /// Otomatik bulunmuş alan varken okuma aralığı en çok bu kadardır (yazı belirdikten ~1 sn içinde Türkçesi).
    public static let autoIntervalMs = 500

    /// Ekrandakinden yalnız biraz farklı (ya da eksik) kararlı okuma en çok bu kadar tur bekletilir; o hâlde kalırsa
    /// gerçekten değişmiş sayılır ve gösterilir (görevin tek sözcüğü değişebilir: "Go to the barn" → "Go to the bank").
    static let holdLimit = 4

    /// Çevirisi saklanan en çok yazı sayısı (oyun görev yazısını arada silip yeniden gösteriyor).
    private static let translationLimit = 64

    private struct State {
        var signature: [UInt8]?
        /// Son okumanın sadeleştirilmiş yazısı; bir sonraki okuma aynıysa yazı kararlıdır.
        var lastRead: String?
        /// Okunmuş ama henüz kararlı sayılmamış yazı.
        var candidate: Candidate?
        /// TV'de şu an çevirisi duran yazı (sadeleştirilmiş); boşsa kutu yok.
        var shown = ""
        /// Gösterilen yazının `Candidate.text`'i.
        var shownText = ""
        /// Gösterilen yazıdaki tuş simgesi sayısı.
        var shownIcons = 0
        /// Son gösterilen (boş olmayan) yazı; alan boşalınca da hatırlanır (yarım okumayı tanımak için).
        var remembered = ""
        /// Bekletilen okuma ve kaç turdur bekletildiği (`holdLimit`).
        var held: String?
        var holds = 0
        /// Son gönderilen çeviri, aynı yazı yeni bir konuma taşındığında yeniden kullanılır.
        var renderedKey: String?
        var renderedText: String?
        var renderedIcons: [IconPlacement]?
        var renderedBox: TextBox?
        var renderedLineHeight: Double?
        var renderedLayout: [Block]?
        /// Gönderilen bloklar ve her birinin `Candidate.blocks` içindeki sırası.
        var renderedBlocks: [(group: Int, item: ScreenTranslation.Item)]?
    }

    /// Alanda ayrı duran bir yazı grubu: `Candidate.paragraphs` içinde `start`'tan başlayan `count` parça, karedeki yeri
    /// ve satır yüksekliği (kareye oranla).
    struct Block: Equatable {
        var start: Int
        var count: Int
        var box: TextBox
        var lineHeight: Double
        /// Otomatik ekran yazısında özgün yazının renkleri ve görünüşü (`TextStyleSampler`); diğerlerinde nil.
        var style: PhoneTextStyle? = nil
        var look: TextLook? = nil
    }

    struct Candidate {
        var paragraphs: [String]
        var box: TextBox?
        var lineHeight: Double?
        var key: String
        /// Her parçadaki kumanda simgeleri (kareden kesilmiş), parçadaki sırasıyla; simge yoksa nil.
        var icons: [[IconSlot]]? = nil
        /// Alanda birden çok ayrı yazı grubu varsa grupları; tek grupta nil (tek kutu).
        var blocks: [Block]? = nil
        /// Yazının sadeleştirilmiş hâli (simgeler dahil, yerleşim hariç); okumaları karşılaştırmak için.
        var text = ""
    }

    /// Sadeleştirilmiş yazı; tuş simgeleri `ButtonIcons.marker` olarak kalır. Simgesi sonradan bulunan okuma
    /// ("SET DESTINATION ✕") eskisinden ayrılsın.
    static func textKey(_ paragraphs: [String]) -> String {
        var parts: [String] = []
        for part in paragraphs.joined(separator: " ").split(separator: ButtonIcons.marker, omittingEmptySubsequences: false) {
            if !parts.isEmpty { parts.append(String(ButtonIcons.marker)) }
            parts.append(TextMatch.normalize(String(part)))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Paragrafların çevirisi (çevrilmeyen parça nil) ve kaçının paketten geldiği.
    struct Translation: Sendable {
        var result: [String?]
        var readyCount: Int
    }

    private let reader: TextReader
    private let translator: TextTranslator
    private let server: RegionSending
    private let intervalMs: Int
    private let now: () -> Int
    private var states: [String: State] = [:]
    private var lastPass: Int?
    private var phoneSession: PhoneRegionSession?
    public var englishPhoneMessages = false
    private var running: Task<Void, Never>?
    private var session = 0
    /// Yalnız kararlı okumaların başarılı çevirileri saklanır.
    private var translations: [String: Translation] = [:]

    /// Oyun paketi: satırın hazır Türkçesi (ana altyazıyla aynı arama).
    public var packLookup: ((String) -> PackMatch?)?
    /// Hedef dil Türkçe: yüksek güvenle Türkçe olan parça çevrilmez, aslı sayılır (#289).
    public var skipsTurkish = true
    /// Kısa İngilizce tuş komutlarını Türkçeye çevirir. Yalnız en → tr için açılır.
    public var translatesUiCommands = false
    public var onLog: ((String) -> Void)?
    /// Otomatik alan okundu ama yazı yok ya da gürültü (`ScreenTextNoise`): alanın kimliği (`ScreenTextDetector.reject`).
    public var onAutoRejected: ((String) -> Void)?
    /// Her okumanın süresi (ms; ölçüm için).
    public var onReadMs: ((Int) -> Void)?
    /// Tamamlanan tur sayısı ve okuma sayısı (ölçüm ve testler için).
    public private(set) var passes = 0
    public private(set) var reads = 0

    public init(reader: TextReader, translator: TextTranslator, server: RegionSending,
                intervalMs: Int = RegionWatcher.defaultIntervalMs, clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) {
        self.reader = reader
        self.translator = translator
        self.server = server
        self.intervalMs = intervalMs
        self.now = clock
    }

    /// Bir tur sürüyor mu.
    public var isBusy: Bool { running != nil }

    /// Her karede çağrılır; tur zamanı geldiyse ve önceki tur bittiyse turu arka planda başlatır, hemen döner.
    public func offer(_ frame: CGImage, areas: [ExtraArea], phone pose: GamePhoneGeometry.Pose? = nil) {
        if let pose {
            if phoneSession == nil { phoneSession = PhoneRegionSession(reader: reader, translator: translator, server: server) }
            phoneSession?.observe(frame, pose: pose)
        } else if phoneSession != nil {
            closePhone()
        }
        guard running == nil else { return }
        let time = now()
        let interval = areas.contains(where: \.auto) ? min(intervalMs, Self.autoIntervalMs) : intervalMs
        let manualDue = (!areas.isEmpty || states.values.contains { !$0.shown.isEmpty })
            && (lastPass.map { time - $0 >= interval } ?? true)
        let phone = phoneSession
        let phoneDue = phone?.beginIfDue(time) ?? false
        guard manualDue || phoneDue else { return }
        if manualDue { lastPass = time }
        let session = self.session
        running = Task { [weak self] in
            guard let self, self.session == session else { return }
            if manualDue { await self.pass(frame, areas: areas) }
            if phoneDue, let phone, self.phoneSession === phone, self.session == session {
                await phone.visit(packLookup: self.packLookup, skipsTurkish: self.skipsTurkish,
                                  english: self.englishPhoneMessages)
            }
            // Bu arada sıfırlandıysa yeni oturumun turuna dokunulmaz.
            if self.session == session { self.running = nil }
        }
    }

    /// Bir tur: kaldırılan alanların kutusu kalkar, her açık alan gerekirse okunur ve kararlı yazısı çevrilir.
    /// Testler doğrudan çağırır.
    public func pass(_ frame: CGImage, areas: [ExtraArea]) async {
        let started = session
        passes += 1
        let ids = Set(areas.map(\.id))
        for (id, state) in states where !ids.contains(id) {
            if !state.shown.isEmpty { server.sendRegion(id: id, text: "", box: nil, lineHeight: nil) }
            states[id] = nil
        }
        for area in areas {
            guard session == started else { return }
            await visit(area, frame: frame, session: started)
        }
    }

    private func visit(_ area: ExtraArea, frame: CGImage, session: Int) async {
        let region = area.region
        let (crop, signature) = await Task.detached(priority: .utility) {
            let crop = RegionCropper.crop(frame, to: region)
            return (crop, RegionCropper.signature(of: crop))
        }.value
        guard session == self.session else { return }
        var state = states[area.id] ?? State()
        let changed = state.signature.map {
            ReadScheduler.changed($0, signature, threshold: ReadScheduler.defaultChangeThreshold)
        } ?? true
        state.signature = signature
        guard changed else {
            // İz bir tur değişmedi: okunan yazı kararlıdır.
            if let candidate = state.candidate {
                state.candidate = nil
                states[area.id] = state
                await commit(candidate, area: area)
            } else {
                states[area.id] = state
            }
            return
        }
        let started = now()
        let reader = self.reader
        let reading = try? await ReadQueue.shared.run { try reader.readLines(crop, deep: false) }
        guard session == self.session else { return }
        guard let reading else {
            // OCR hatası boş alan değildir. Eski kutuyu koru; aynı kareyi sonraki normal turda yeniden oku.
            // Başarısız kare, önceki adayın kararlılığını da doğrulayamaz.
            state.signature = nil
            state.lastRead = nil
            state.candidate = nil
            states[area.id] = state
            return
        }
        reads += 1
        onReadMs?(now() - started)
        let candidate = Self.candidate(reading, in: region, frame: crop, auto: area.auto)
        if state.lastRead == candidate.key {
            state.candidate = nil
            states[area.id] = state
            await commit(candidate, area: area)
        } else {
            state.lastRead = candidate.key
            state.held = nil
            state.holds = 0
            state.candidate = candidate
            states[area.id] = state
        }
    }

    private static func iconCount(_ candidate: Candidate) -> Int {
        candidate.paragraphs.reduce(0) { count, paragraph in count + paragraph.filter { $0 == ButtonIcons.marker }.count }
    }

    /// Okuma bekletilmeli mi (gösterilmeden önce bir iki tur daha okunur):
    /// - Az önce gösterilen yazının başı: yazı belirirken renkli sözcük geç geliyor ("Fly to a" ← "Fly to a drop");
    ///   görev her belirişinde iki kez çevrilip değişiyordu.
    /// - Ekrandakiyle neredeyse aynı ya da onun eksik hâli, ve daha çok simge bulmamış: harita arkada oynarken tuş
    ///   çubuğu "SET DESTINATION ✕ EXIT ○" / "SET DESTINATIPN EXIT ○" diye okunup kutu sürekli değişiyordu.
    /// - Daha çok simge bulmuş ama ekrandakinin bir sözcüğünü simgeyle değiştirmiş ("Find □" ← "Find Donnie").
    private static func shouldHold(_ candidate: Candidate, _ state: State) -> Bool {
        guard !candidate.text.isEmpty else { return false }
        if state.remembered.count > candidate.text.count, state.remembered.hasPrefix(candidate.text + " ") { return true }
        if state.shownText.isEmpty || state.shownText == candidate.text { return false }
        if TextMatch.addsMeaning(candidate.text, to: state.shownText) { return false }
        return iconCount(candidate) <= state.shownIcons
            ? TextMatch.isSimilar(state.shownText, candidate.text, threshold: 0.85) || isPartOf(candidate.text, state.shownText)
            : losesWords(candidate.text, state.shownText)
    }

    private static func matches(_ a: String, _ b: String) -> Bool { a == b || TextMatch.isSimilar(a, b, threshold: 0.75) }

    private static func words(_ text: String) -> [String] {
        text.split(separator: " ").filter { token in token.contains { $0.isLetter || $0.isNumber } }.map(String.init)
    }

    /// Okuma ekrandakinin eksik hâli mi: sözcükleri (biri tanınmayabilir) ekrandakinde sırasıyla geçiyor.
    static func isPartOf(_ reading: String, _ shown: String) -> Bool {
        let part = reading.split(separator: " ").map(String.init)
        let whole = shown.split(separator: " ").map(String.init)
        guard !part.isEmpty, part.count < whole.count else { return false }
        var at = 0, misses = 0
        for word in part {
            guard let found = whole[at...].firstIndex(where: { matches($0, word) }) else {
                misses += 1
                if misses > 1 { return false }
                continue
            }
            at = found + 1
        }
        return at > 0
    }

    /// Okumanın bütün sözcükleri ekrandakinde geçiyor ama ekrandakinin bir sözcüğü kayıp (simge onun yerine okunmuş).
    static func losesWords(_ reading: String, _ shown: String) -> Bool {
        let have = words(reading)
        let whole = words(shown)
        return !have.isEmpty
            && whole.contains { word in !have.contains { matches($0, word) } }
            && have.allSatisfy { word in whole.contains { matches($0, word) } }
    }

    /// Okumadan çevrilecek parçalar: kumanda ipuçları, yazı tanıma çöpleri ve harfsiz göstergeler ("23m", "9") atılır;
    /// satırlar yukarıdan aşağı parçalara toplanır (başlık, cümle, madde). Yazının içindeki kumanda simgeleri `frame`'den
    /// (okunan alan) kesilir; çeviride yerleri korunur.
    /// `auto`: otomatik bulunmuş alan; her yazı grubu (tek grup da) blok olur ve özgün stili çıkarılır.
    static func candidate(_ reading: Reading, in region: CropRegion, frame: CGImage? = nil, auto: Bool = false) -> Candidate {
        let lines = reading.withButtonIcons(frame: frame).withoutButtonPrompts().withoutOcrNoise().lines
            .filter { ScreenTranslation.isWords($0.text) }
            .sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
        var paragraphs = ScreenTranslation.paragraphs(lines)
        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        let boxes = lines.compactMap(\.box)
        let box = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }?.placed(in: place)
        let height = region.bottom - region.top
        let heights = boxes.map { ($0.bottom - $0.top) * height }.sorted()
        let lineHeight = heights.isEmpty ? nil : heights[heights.count / 2]
        var key = textKey(paragraphs)
        var icons = ScreenTranslation.paragraphIcons(lines)
        // Alanda birbirinden ayrı duran yazılar (başlık ile ayrı sütundaki hedef, alt alta iki bildirim) "Ekranı çevir"deki
        // gibi gruplanır; her grubun çevirisi TV'de kendi yerine konur. Tek grupta (ya da yeri bilinmeyen satır varsa)
        // eskisi gibi tek kutu. Anahtar grup yapısını da içerir: aynı yazı farklı gruplanırsa bloklar yeniden kurulur.
        var blocks: [Block]?
        let groups = (auto || lines.count > 1) && !lines.isEmpty && boxes.count == lines.count
            ? ScreenTranslation.groups(from: lines) : []
        if (auto && !groups.isEmpty) || (groups.count > 1 && groups.count < ScreenTranslation.maxGroups) {
            paragraphs = groups.flatMap(\.paragraphs)
            icons = groups.flatMap { $0.icons ?? $0.paragraphs.map { _ in [IconSlot]() } }
            var list: [Block] = []
            var start = 0
            for group in groups {
                var style: PhoneTextStyle?
                var look: TextLook?
                if auto, let frame {
                    // Çeviri özgün yazının stilinde çizilsin: renkler, kalınlık, dar aile, hiza, büyük harf.
                    let own = lines.filter { inside($0.box!, group.box) }
                    (style, look) = TextStyleSampler.sample(frame, box: group.box, lines: own,
                                                            source: group.paragraphs.joined(separator: " "))
                }
                list.append(Block(start: start, count: group.paragraphs.count, box: group.box.placed(in: place),
                                  lineHeight: group.lineHeight * height, style: style, look: look))
                start += group.paragraphs.count
            }
            blocks = list
            key = textKey(paragraphs) + "|" + list.map { String($0.count) }.joined(separator: ",")
        }
        var cut: [[IconSlot]]?
        if let frame, icons.contains(where: { !$0.isEmpty }) {
            cut = icons.map { ButtonIcons.withImages($0, frame: frame) }
        }
        return Candidate(paragraphs: paragraphs, box: box, lineHeight: lineHeight, key: key, icons: cut, blocks: blocks,
                         text: textKey(paragraphs))
    }

    private static func inside(_ line: TextBox, _ group: TextBox) -> Bool {
        let x = (line.left + line.right) / 2, y = (line.top + line.bottom) / 2
        return x >= group.left - 1e-6 && x <= group.right + 1e-6 && y >= group.top - 1e-6 && y <= group.bottom + 1e-6
    }

    /// Kararlı yazı: öncekinden farklıysa çevrilip gönderilir, boşsa kutu kalkar.
    private func commit(_ candidate: Candidate, area: ExtraArea) async {
        guard var state = states[area.id] else { return }
        if area.auto, candidate.key.isEmpty || ScreenTextNoise.isNoise(candidate.paragraphs.joined(separator: " ")) {
            // Kendiliğinden bulunan alanda yazı yok ya da gürültü (sayaç, harita, kısa etiket): çevrilmez, dedektöre
            // bildirilir; o görüntü değişmedikçe alan yeniden önerilmez.
            if !state.shown.isEmpty || !(state.renderedText ?? "").isEmpty {
                server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
            }
            state.shown = candidate.key
            state.shownText = candidate.text
            state.renderedKey = candidate.key
            state.renderedText = ""
            state.renderedBox = nil
            state.renderedLineHeight = nil
            states[area.id] = state
            onAutoRejected?(area.id)
            return
        }
        if state.shown == candidate.key {
            guard state.renderedKey == candidate.key,
                  let renderedText = state.renderedText, !renderedText.isEmpty else { return }
            guard state.renderedBox != candidate.box || state.renderedLineHeight != candidate.lineHeight
                    || state.renderedLayout != candidate.blocks else { return }
            // Aynı yazı kaydı: çeviriler korunur, bloklar yeni yerlerine taşınır (anahtar aynıysa grup sayısı da aynıdır).
            var moved: [(group: Int, item: ScreenTranslation.Item)]?
            if let rendered = state.renderedBlocks, let current = candidate.blocks {
                moved = rendered.map { block -> (group: Int, item: ScreenTranslation.Item) in
                    var item = block.item
                    item.box = current[block.group].box
                    item.lineHeight = current[block.group].lineHeight
                    return (block.group, item)
                }
            }
            server.sendRegion(id: area.id, text: renderedText, box: candidate.box, lineHeight: candidate.lineHeight,
                              icons: state.renderedIcons, blocks: moved?.map(\.item))
            state.renderedBox = candidate.box
            state.renderedLineHeight = candidate.lineHeight
            state.renderedLayout = candidate.blocks
            state.renderedBlocks = moved
            states[area.id] = state
            return
        }
        if Self.shouldHold(candidate, state) {
            if state.held != candidate.key {
                state.held = candidate.key
                state.holds = 0
            }
            state.holds += 1
            if state.holds <= Self.holdLimit {
                // Sonraki tur (iz değişmese de) bu okumayı yeniden dener; o hâlde kalırsa sınırda gösterilir.
                state.candidate = candidate
                states[area.id] = state
                return
            }
        }
        state.held = nil
        state.holds = 0
        let previous = (shown: state.shown, text: state.shownText, icons: state.shownIcons)
        state.shown = candidate.key
        state.shownText = candidate.text
        state.shownIcons = Self.iconCount(candidate)
        states[area.id] = state
        guard !candidate.key.isEmpty else {
            server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
            states[area.id]?.renderedKey = candidate.key
            states[area.id]?.renderedText = ""
            states[area.id]?.renderedIcons = nil
            states[area.id]?.renderedBox = nil
            states[area.id]?.renderedLineHeight = nil
            onLog?("ek alan \(area.name): boşaldı")
            return
        }
        let session = self.session
        let key = Self.translationKey(candidate)
        let cached = translations[key]
        let translation: Translation
        do {
            if let cached { translation = cached }
            else { translation = try await translate(candidate.paragraphs) }
        } catch {
            guard session == self.session else { return }
            if states[area.id]?.shown == candidate.key {
                states[area.id]?.shown = previous.shown
                states[area.id]?.shownText = previous.text
                states[area.id]?.shownIcons = previous.icons
                states[area.id]?.candidate = candidate
            }
            onLog?("ek alan \(area.name): \(SubtitleLog.excerpt(IconText.plain(candidate.paragraphs.joined(separator: " ")))) çevrilemedi (\(error))")
            return
        }
        guard session == self.session, states[area.id]?.shown == candidate.key else { return }
        if cached == nil {
            if translations.count >= Self.translationLimit { translations.removeAll(keepingCapacity: true) }
            translations[key] = translation
        }
        states[area.id]?.remembered = candidate.text
        let translated = translation.result
        let readyCount = translation.readyCount
        // Simgeler çeviride uydurma adlarla korunmuştu (`IconText`); adlar yerlerine konur.
        let prepared = candidate.paragraphs.map(IconText.protect)
        var slots: [IconSlot] = []
        var text: [String] = []
        for (index, source) in candidate.paragraphs.enumerated() {
            let trimmed = (index < translated.count ? translated[index] : nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty || trimmed.contains(ButtonIcons.marker) {
                text.append(IconText.indexed(trimmed.isEmpty ? source : trimmed, offset: slots.count))
            } else {
                text.append(IconText.restore(trimmed, names: prepared[index].names, offset: slots.count))
            }
            if let all = candidate.icons, index < all.count { slots += all[index] }
        }
        // Çevirisi aslıyla aynı (ad, sayı, zaten hedef dilde): kutu gösterilmez.
        let similar = zip(candidate.paragraphs, text).map {
            TextMatch.isSimilar(TextMatch.normalize(IconText.plain($0)), TextMatch.normalize(IconText.plain($1)), threshold: 0.90)
        }
        if similar.allSatisfy({ $0 }) {
            server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
            states[area.id]?.renderedKey = candidate.key
            states[area.id]?.renderedText = ""
            states[area.id]?.renderedIcons = nil
            states[area.id]?.renderedBox = nil
            states[area.id]?.renderedLineHeight = nil
            states[area.id]?.renderedLayout = nil
            states[area.id]?.renderedBlocks = nil
            return
        }
        let origin = cached != nil || readyCount == candidate.paragraphs.count ? "hazır çeviri" : readyCount > 0 ? "hazır çeviri+motor" : "motor"
        onLog?("ek alan \(area.name): \(SubtitleLog.excerpt(IconText.plain(candidate.paragraphs.joined(separator: " ")))) → \(origin)")
        let rendered = IconText.render(text.joined(separator: "\n"), slots: slots)
        let icons = rendered.icons.isEmpty ? nil : rendered.icons
        let blocks = candidate.blocks.map { Self.renderBlocks(candidate, layout: $0, text: text, similar: similar, slots: slots) }
        server.sendRegion(id: area.id, text: rendered.text, box: candidate.box, lineHeight: candidate.lineHeight, icons: icons,
                          blocks: blocks?.map(\.item))
        states[area.id]?.renderedKey = candidate.key
        states[area.id]?.renderedText = rendered.text
        states[area.id]?.renderedIcons = icons
        states[area.id]?.renderedBox = candidate.box
        states[area.id]?.renderedLineHeight = candidate.lineHeight
        states[area.id]?.renderedLayout = candidate.blocks
        states[area.id]?.renderedBlocks = blocks
    }

    /// Her grubun çevirisi kendi yeriyle. Çevirisi aslıyla aynı grup (ad, sayı) atlanır; İngilizcesi görünür kalır.
    /// `text` simge imlerini bütün alanın sırasıyla taşır; `slots` o sıradaki simgeler.
    static func renderBlocks(_ candidate: Candidate, layout: [Block], text: [String], similar: [Bool],
                             slots: [IconSlot]) -> [(group: Int, item: ScreenTranslation.Item)] {
        var result: [(group: Int, item: ScreenTranslation.Item)] = []
        for (index, block) in layout.enumerated() {
            let range = block.start..<(block.start + block.count)
            if range.allSatisfy({ similar[$0] }) { continue }
            var joined = range.map { text[$0] }.joined(separator: "\n")
            // Özgün yazı BÜYÜK HARF: çeviri de Türkçe kurallarıyla büyük harf (simge imleri harf değildir, korunur).
            if block.look?.upper == true { joined = TextStyleSampler.turkishUpper(joined) }
            let rendered = IconText.render(joined, slots: slots)
            let source = range.map { IconText.plain(candidate.paragraphs[$0]) }.joined(separator: "\n")
            var item = ScreenTranslation.Item(source: source, translation: rendered.text, box: block.box,
                                              lineHeight: block.lineHeight, icons: rendered.icons.isEmpty ? nil : rendered.icons)
            item.style = block.style
            item.look = block.look
            result.append((index, item))
        }
        return result
    }

    /// Saklanan çevirinin anahtarı: paragraflar ayrı ayrı. Aynı yazı başka satırlardan bölünürse paragraf sayısı değişir;
    /// `candidate.key` aynı kalsa da eski çeviri kullanılmaz (dizinin dışına taşardı).
    static func translationKey(_ candidate: Candidate) -> String { candidate.paragraphs.joined(separator: "\n") }

    /// Parçalar önce pakette aranır; kalanlar çeviri motoruna gider (yapay zekâda tek istekte). Motora simgeleri adlarla
    /// korunmuş metin gider (`IconText`; simgeler paket aramasında yok sayılır). Çevrilemeyen parça nil kalır.
    private func translate(_ paragraphs: [String]) async throws -> Translation {
        let prepared = paragraphs.map(IconText.protect)
        var result = paragraphs.map { paragraph in
            packLookup?(IconText.plain(paragraph))?.text ?? (translatesUiCommands ? UiCommands.translate(paragraph) : nil)
        }
        let readyCount = result.compactMap { $0 }.count
        // Zaten Türkçe olan parça çevrilmez: aslı kalır, tümü öyleyse kutu gösterilmez.
        for index in result.indices where result[index] == nil && skipsTurkish && TurkishText.isSure(paragraphs[index]) {
            result[index] = paragraphs[index]
        }
        let missing = result.indices.filter { result[$0] == nil }
        if !missing.isEmpty {
            let texts = missing.map { prepared[$0].text }
            let translated = translator.translatesTogether ? try await translator.translateAll(texts)
                : try await sequential(texts)
            for (index, translation) in zip(missing, translated) { result[index] = translation }
        }
        return Translation(result: result, readyCount: readyCount)
    }

    private func sequential(_ texts: [String]) async throws -> [String] {
        var result: [String] = []
        for text in texts {
            try Task.checkCancellation()
            result.append(try await translator.translate(text))
        }
        return result
    }

    /// Telefon kapanınca yalnız onun bekleyen isteğini ve görünür bloklarını kaldırır.
    public func closePhone() {
        phoneSession?.close()
        phoneSession = nil
    }

    /// Çeviri durdu ya da hat yeniden kuruldu: süren tur bırakılır, TV'deki ek alan kutuları kalkar.
    public func reset() {
        closePhone()
        session += 1
        running?.cancel()
        running = nil
        lastPass = nil
        translations.removeAll()
        let anyShown = states.values.contains { !$0.shown.isEmpty }
        states.removeAll()
        if anyShown { server.clearRegions() }
    }
}
