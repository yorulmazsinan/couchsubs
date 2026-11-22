// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Yazının yeri, içinde bulunduğu alanın kenarlarına oranla (0–1, üstten ve soldan).
public struct TextBox: Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public func union(_ other: TextBox) -> TextBox {
        TextBox(left: min(left, other.left), top: min(top, other.top), right: max(right, other.right), bottom: max(bottom, other.bottom))
    }

    /// Bu kutu `area` içindeki oranlarsa, aynı yerin `area`'yı içeren çerçevedeki oranları.
    public func placed(in area: TextBox) -> TextBox {
        let width = area.right - area.left, height = area.bottom - area.top
        return TextBox(left: area.left + left * width, top: area.top + top * height,
                       right: area.left + right * width, bottom: area.top + bottom * height)
    }

    /// Ekranın ortasındaki altyazının kutusu ortaya göre simetrik genişletilir. Açık zeminde ya da renkli yazıda
    /// yazı tanıma satırın bir ucunu okuyamayabilir; kutu yalnız okunan parçayı örterse İngilizcenin geri kalanı
    /// yanda görünür ve çeviri ortalanmamış durur. Ortadan uzak (köşedeki) yazıya dokunulmaz (Windows: TextBox.CenteredOnScreen).
    public func centeredOnScreen() -> TextBox {
        let middle = (left + right) / 2
        guard middle > 0.3, middle < 0.7 else { return self }
        return TextBox(left: max(0, min(left, 1 - right)), top: top, right: min(1, max(right, 1 - left)), bottom: bottom)
    }
}

/// Yazı tanımanın bulduğu bir satır.
public struct TextLine: Equatable, Sendable {
    public var text: String
    /// Okunan alana göre yeri; bilinmiyorsa nil.
    public var box: TextBox?
    /// Yazı tanımanın bu satırdan ne kadar emin olduğu (0–1); okuyucu vermiyorsa nil.
    public var confidence: Double?
    /// Okuyucu sözcüklerin yerini de veriyorsa (Vision) sözcükler, satırla aynı oranlarda; kumanda simgesini bulmak
    /// için (`ButtonIcons`).
    public var words: [TextWord]?
    /// Metindeki her `ButtonIcons.marker` için, sırasıyla, simgenin yeri ve okunan hali.
    public var icons: [IconSlot]?
    /// Telefon balonlarının eğimi düzeltilmiş ekrandaki yeri. TV için box kullanılır.
    var phoneBox: TextBox?

    public init(_ text: String, box: TextBox? = nil, confidence: Double? = nil, words: [TextWord]? = nil, icons: [IconSlot]? = nil) {
        self.text = text
        self.box = box
        self.confidence = confidence
        self.words = words
        self.icons = icons
    }
}

/// Yazı tanımanın bulduğu bir sözcük ve yeri (okunan alanın kenarlarına oranla).
public struct TextWord: Equatable, Sendable {
    public var text: String
    public var box: TextBox

    public init(_ text: String, box: TextBox) {
        self.text = text
        self.box = box
    }
}

/// Yazının içindeki kumanda simgesi ("Hold △ to sprint"). Yazı tanıma simgeyi harf sanar ("A", "Ä") ya da hiç okumaz
/// (Windows: Reading.cs, IconSlot).
public struct IconSlot: Equatable, Sendable {
    /// Karedeki yeri (okunan alanın kenarlarına oranla).
    public var box: TextBox
    /// Okunan hali (boş olabilir); simge kesilemezse TV'de bu yazılır.
    public var text: String
    /// Kareden kesilen simgenin PNG'si (data: adresi); kesilemediyse nil.
    public var image: String?

    public init(box: TextBox, text: String, image: String? = nil) {
        self.box = box
        self.text = text
        self.image = image
    }
}

/// Bir karenin okunan satırları, yukarıdan aşağı.
public struct Reading: Equatable, Sendable {
    public var lines: [TextLine]

    public init(lines: [TextLine]) {
        self.lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public static let empty = Reading(lines: [])

    /// Satırları ayrı ayrı bilinmeyen eski okuyucular için: her satır sonu bir satırdır.
    public init(text: String) {
        self.init(lines: text.components(separatedBy: .newlines).map { TextLine($0.trimmingCharacters(in: .whitespaces)) })
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }

    /// Bütün satırları içine alan kutu; hiçbir satırın yeri bilinmiyorsa nil.
    public var box: TextBox? {
        lines.compactMap(\.box).reduce(nil) { total, box in total?.union(box) ?? box }
    }

    /// Satırların ortalama tanıma güveni (0–1); okuyucu güven vermiyorsa nil.
    public var confidence: Double? {
        let values = lines.compactMap(\.confidence)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Oyunun düğme ipuçları ("R2 Swing", "△ Pick up", "Press @ to open the map") çıkarılmış hali; bunlar altyazı
    /// değildir. Simgesi bulunmuş satır (`withButtonIcons`; "Ekranı çevir" ve ek alanlar) kalır: simgesiyle çevrilir,
    /// düğme görünür. Simgesi bulunamayan ipucu atılır; çevrilmediği için üstü örtülmez (Windows: WithoutButtonPrompts).
    public func withoutButtonPrompts() -> Reading {
        Reading(lines: lines.filter { !($0.icons ?? []).isEmpty || !ButtonPrompts.isPrompt($0.text) })
    }

    /// Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e", "waters2aljd") ayıklanmış hali; çevirmen bunları olduğu
    /// gibi taşıyıp TV'de anlamsız harfler gösteriyordu.
    public func withoutOcrNoise(keepIdentifiers: Bool = false) -> Reading {
        // Sözcük ve simge yerleri korunur (simgenin imi çöp sayılmaz, bkz. `OcrNoise.clean`).
        Reading(lines: lines.map { line in
            var cleaned = line
            cleaned.text = OcrNoise.clean(line.text, keepIdentifiers: keepIdentifiers)
            return cleaned
        })
    }

    /// Aynı satırda yan yana okunan parçalar soldan sağa tek satır olur. Renkli konuşan adını ("Arthur:", RDR2) yazı
    /// tanıma cümleden ayrı okuyor; parçalar yalnız üst kenarlarına göre dizilince ad cümlenin sonuna düşüyor ya da ayrı
    /// blok sayılıp atılıyordu. Yatayda aralarında en çok `rowGap` (alan genişliğine oranla) olan parçalar birleşir;
    /// uzaktaki köşe yazısı ayrı kalır (Android: Reading.joiningRows, Windows: Reading.JoiningRows).
    public func joiningRows() -> Reading {
        guard lines.count > 1, lines.allSatisfy({ $0.box != nil }) else { return self }
        var rows: [TextLine] = []
        for line in lines.sorted(by: { $0.box!.left < $1.box!.left }) {
            let box = line.box!
            if let index = rows.firstIndex(where: { Self.sameRow(box, $0.box!) }) {
                let row = rows[index]
                let confidence = [row.confidence, line.confidence].compactMap { $0 }.min()
                rows[index] = TextLine(row.text + " " + line.text, box: row.box!.union(box), confidence: confidence)
            } else {
                rows.append(line)
            }
        }
        return Reading(lines: rows.sorted { $0.box!.top < $1.box!.top })
    }

    static let rowGap = 0.05

    /// `next` (solda başlayan `row`'un sağında) aynı satırda mı: dikeyde küçük yüksekliğin en az %60'ı örtüşür.
    private static func sameRow(_ next: TextBox, _ row: TextBox) -> Bool {
        let overlap = min(next.bottom, row.bottom) - max(next.top, row.top)
        let smaller = min(next.bottom - next.top, row.bottom - row.top)
        guard smaller > 0, overlap >= smaller * 0.6 else { return false }
        return next.left - row.right <= rowGap
    }

    /// Alandaki altyazı bloğu. Seçilen alanda altyazının yanında menü ("MAP / HELP / SETTINGS" alt alta), köşedeki
    /// gösterge ("9", "PHOTO MODE") da okunuyordu; hepsi tek cümle gibi çevrilip TV'de bütün alanı kaplayan kutuyla
    /// gösteriliyordu. Satırlar yerlerine göre bloklara ayrılır; ortalanmış ve menü olmayan en alttaki blok altyazıdır.
    /// Ortalanmış blok yoksa en az üç sözcüklü, menü olmayan en alttaki blok alınır. Satırların yeri bilinmiyorsa
    /// okuma olduğu gibi kalır. `area`, okunan alanın karedeki yeridir (ortalanmışlık karenin ortasına göre ölçülür).
    /// Tek satırlık etkileşim/HUD etiketi ("TAKE AMMO PACK (0/3)", `ButtonPrompts.isActionLabel`) ve sahne yazısı
    /// (tabela, tişört; `SceneText`) altyazı bloğu sayılmaz. `band`: bu oturumda altyazının okunduğu yükseklikler
    /// (`SubtitleBand`); `dropped`: sahne yazısı sayılıp atılan her blok ve nedeni (altyazı günlüğü için).
    /// "Tam ekran" alanda ekranın kenarındaki bildirim kartı (`ScreenNotices.isNotice`) altyazı bloğu sayılmaz, `notices`
    /// ile bildirilir (satır kutuları alana oranlı); kendi yerinde çevrilir. Önceden ortalanmış blok yokken altyazı seçilip
    /// ekranın ortasında çiziliyordu. `age`: satırın ne kadar süredir değişmeden okunduğu (`StickyRows.unchangedMs`);
    /// verilirse `staleMs`'dir değişmeyen ortalı blok, yanında yeni beliren ortalı blok varken seçilmez (`withoutStale`),
    /// atlanan blok `stale` ile bildirilir.
    public func subtitleBlock(in area: TextBox, band: SubtitleBand = SubtitleBand(),
                              dropped: ((Reading, String) -> Void)? = nil,
                              notices: ((Reading) -> Void)? = nil,
                              age: ((String) -> Int?)? = nil,
                              stale: ((Reading) -> Void)? = nil) -> Reading {
        guard !lines.isEmpty, lines.allSatisfy({ $0.box != nil }) else { return isActionLabel ? .empty : self }
        var blocks: [[TextLine]] = []
        for line in lines.sorted(by: { $0.box!.top < $1.box!.top }) {
            let box = line.box!.placed(in: area)
            if let index = blocks.lastIndex(where: { Self.belongs(box, line.text, to: $0, in: area) }) {
                blocks[index].append(line)
            } else {
                blocks.append([line])
            }
        }
        // Tabela, tişört, plaka gibi sahne yazısı (`SceneText`) altyazı alanına düşse de altyazı değildir.
        let candidates = blocks.map { Reading(lines: $0) }.filter { block in
            guard !block.isMenu, !block.isActionLabel else { return false }
            guard let reason = SceneText.reason(block, in: area, band: band) else { return true }
            dropped?(block, reason)
            return false
        }.filter { block in
            guard ScreenNotices.isWholeScreen(area), let box = block.box?.placed(in: area), ScreenNotices.isNotice(box)
            else { return true }
            notices?(block)
            return false
        }
        let middle = candidates.filter { reading in
            guard let box = reading.box?.placed(in: area) else { return false }
            return abs((box.left + box.right) / 2 - 0.5) <= 0.12
        }
        let centered = Self.withoutStale(middle, age: age, skipped: stale)
        // Görev satırı altyazıyla aynı anda belirince ayrı blok olur (aralık ya da yazı boyu farkı): konuşan adı taşıyan
        // blok altyazıdır ("Lucia: …" görevin üstünde de dursa).
        if let spoken = centered.first(where: { SpeakerPrefix.split($0.lines[0].text) != nil }) { return spoken }
        if let lowest = centered.indices.max(by: { centered[$0].box!.bottom < centered[$1].box!.bottom }) {
            return Self.objectiveBelow(lowest, centered, in: area) ?? centered[lowest]
        }
        return candidates.filter { $0.text.split(whereSeparator: \.isWhitespace).count >= 3 }
            .max(by: { $0.box!.bottom < $1.box!.bottom }) ?? .empty
    }

    /// En alttaki blok, hemen üstündeki konuşmanın altına onunla aynı anda gelen görev satırı mı: tek satır ve üstündeki
    /// ortalanmış bloktan (arada en çok üç satır boyu) belirgin kısa (`StickyRows.joinedShare`). Öyleyse altyazı üstteki
    /// bloktur. Kullanıcı bildirimi (X, beta.69, GTA 6): "John'u takip et" konuşmayla birlikte belirince en alttaki blok
    /// olarak altyazı seçiliyor, konuşma hiç çevrilmiyordu. Görev ekranda kalınca sonraki konuşmalarda `StickyRows` onu
    /// ayırır (Windows ve Android ile aynı).
    private static func objectiveBelow(_ index: Int, _ centered: [Reading], in area: TextBox) -> Reading? {
        let lowest = centered[index]
        guard lowest.lines.count == 1, let lowestBox = lowest.box else { return nil }
        let box = lowestBox.placed(in: area)
        let height = box.bottom - box.top
        let above = centered.indices.filter { other in
            guard other != index, let placed = centered[other].box?.placed(in: area) else { return false }
            return placed.bottom <= box.top + height * 0.25 && box.top - placed.bottom <= height * 3
        }.map { centered[$0] }.max(by: { $0.box!.bottom < $1.box!.bottom })
        guard let above else { return nil }
        return Double(letters(lowest.text)) <= StickyRows.joinedShare * Double(letters(above.text)) ? above : nil
    }

    private static func letters(_ text: String) -> Int { text.filter(\.isLetter).count }

    /// Ortalı blok bu kadar süredir hiç değişmediyse ve yanında ondan en az `StickyRows.youngerByMs` daha yeni (kırıntı
    /// olmayan) ortalı blok varsa altyazı sayılmaz. Kullanıcı bildirimi (GitHub #933, GTA 6): karakter TV izlerken haber
    /// programının alt bandı konuşma altyazısının altında duruyor, en alttaki ortalı blok olarak her karede bant seçiliyor,
    /// konuşma hiç çevrilmiyordu. Bant çoğu zaman "EXCLUSIVE: …", "BREAKING NEWS: …" diye başlıyor, konuşan adı sanılıp
    /// her zaman altyazı seçiliyordu. Tek ortalı blok (değişmeyen uzun cümle) seçilmeye devam eder. Konuşan adlı sabit
    /// blok yalnız yanındaki yeni blok en az üç sözcüklü bir cümleyse atlanır: kısa görev/HUD yazısı uzun konuşmayı
    /// geçmez (Windows: Reading.StaleMs, Android: Reading.STALE_MS).
    static let staleMs = 5000

    /// `centered` blokların sabit olanları (`staleMs`) çıkarılmış hali; satır yaşı bilinmiyorsa olduğu gibi kalır.
    private static func withoutStale(_ centered: [Reading], age: ((String) -> Int?)?,
                                     skipped: ((Reading) -> Void)?) -> [Reading] {
        guard let age, centered.count >= 2 else { return centered }
        let ages = centered.map { block in block.lines.compactMap { age($0.text) }.min() ?? 0 }
        let fresh = centered.indices.filter { ages[$0] < staleMs && !OcrNoise.isCrumb(centered[$0].text) }
        guard let youngest = fresh.map({ ages[$0] }).min() else { return centered }
        let sentence = fresh.filter { wordCount(centered[$0].text) >= 3 }.map { ages[$0] }.min()
        let stale = Set(centered.indices.filter { index in
            guard ages[index] >= staleMs else { return false }
            let rival = SpeakerPrefix.split(centered[index].lines[0].text) == nil ? youngest : sentence
            return rival.map { ages[index] - $0 >= StickyRows.youngerByMs } ?? false
        })
        guard !stale.isEmpty else { return centered }
        stale.sorted().forEach { skipped?(centered[$0]) }
        return centered.indices.filter { !stale.contains($0) }.map { centered[$0] }
    }

    /// Bloğun son satırının hemen altında ve yatayda onunla üst üste binen satır o bloğa aittir. Aradaki boşluk satır
    /// yüksekliğinin `lineGap` katından (devam satırında `continuationGap`) büyükse ya da yazı boyları 1,25 kattan çok farklıysa ayrı bloktur (altyazıya bitişik görev
    /// satırı ayrılır; Windows ile aynı). Yazı boyu yalnız iki satır da en az üç sözcükken karşılaştırılır ve alttaki satır
    /// üsttekinin devamıysa (`continues`) hiç karşılaştırılmaz: satır kutusu harflere göre ölçülür, "now." gibi kısa ve
    /// büyük harfsiz/kuyruksuz satırın kutusu daha alçak çıkıyor, cümlenin devamı ayrı blok sayılıp tek başına
    /// çevriliyordu (GitHub #715).
    private static func belongs(_ box: TextBox, _ text: String, to block: [TextLine], in area: TextBox) -> Bool {
        let last = block.last!.box!.placed(in: area)
        let own = box.bottom - box.top, previous = last.bottom - last.top
        let height = max(own, previous)
        let continuing = continues(block.last!.text, with: text)
        let wide = continuing && wordCount(block.last!.text) >= continuationMinWords
        guard box.top - last.bottom <= height * (wide ? continuationGap : lineGap), box.top >= last.top else { return false }
        let comparable = wordCount(text) >= 3 && wordCount(block.last!.text) >= 3 && !continuing
        guard !comparable || max(own, previous) <= 1.25 * min(own, previous) else { return false }
        let overlap = min(box.right, last.right) - max(box.left, last.left)
        let narrower = min(box.right - box.left, last.right - last.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    /// Aynı bloğun satırları arasındaki en büyük boşluk (satır yüksekliğine oranla). GTA 6 gibi geniş satır aralıklı
    /// altyazılarda iki satırın arası 0,6'yı aşıyor; beta.67'deki 0,6 eşiği iki satırlı altyazıyı iki bloğa bölüyor, yalnız
    /// biri çevriliyordu (GitHub #822: "5-6 cümlede bir çeviri", çevirilerin bir kısmı cümlenin ikinci yarısı). beta.66'ya
    /// kadarki 0,8 geri geldi; görev satırı yazı boyu farkıyla ve `StickyRows` ile ayrılır.
    static let lineGap = 0.8
    /// Alttaki satır üsttekinin devamıysa (`continues`: cümle bitmemiş, küçük harfle sürüyor) daha geniş boşluk da aynı
    /// bloktur: yarım cümle tek başına altyazı değildir.
    static let continuationGap = 1.3
    /// `continuationGap` yalnız üstteki satır en az bu kadar sözcükken geçerlidir: altyazının sarılmış ilk satırı uzundur.
    /// Tek sözcüklük üst satır (GTA 6 telefon bildiriminde gönderenin adı "Cal", altında "Checked th…") geniş boşlukla
    /// alttakine katılınca üç sözcüklü blok olup altyazı seçiliyordu (gerçek kare gta6-n4-bildirim, beta.78'de gerileme).
    static let continuationMinWords = 3

    private static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// `next` satırı `upper`'ın devamı mı: üstteki cümle bitmemiş (nokta, ünlem, soru işaretiyle bitmiyor) ve alttaki
    /// küçük harfle başlıyor ya da üstteki virgül/tireyle bitiyor ya da alttaki en çok üç sözcük. Konuşan adlı alt satır
    /// ("Lucia: …") yeni konuşmadır, devam sayılmaz (Windows: Reading.Continues, Android: Reading.continues).
    static func continues(_ upper: String, with next: String) -> Bool {
        let top = upper.trimmingCharacters(in: .whitespacesAndNewlines)
        let below = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty, !below.isEmpty, !SubtitleStabilizer.endsSentence(top) else { return false }
        guard SpeakerPrefix.split(below) == nil else { return false }
        if let first = below.first(where: \.isLetter), first.isLowercase { return true }
        return top.hasSuffix(",") || top.hasSuffix("-") || top.hasSuffix("—") || wordCount(below) <= 3
    }

    /// Alt alta kısa ve noktalamasız satırlar ("MAP", "HELP", "SOCIAL CLUB") menüdür, konuşma değil. Satırların yeri
    /// biliniyorsa sol ya da sağ kenarları hizalı olmalı (`menuEdge` içinde): ortalanmış kısa konuşma satırları ("No /
    /// Wait / Go on") menü sanılıp atılmasın. Konuşan adıyla başlayan satır menü değildir (Windows, Android ile aynı).
    var isMenu: Bool {
        guard lines.count >= 3, lines.allSatisfy({ line in
            line.text.split(whereSeparator: \.isWhitespace).count <= 3 && !SubtitleStabilizer.endsSentence(line.text)
                && SpeakerPrefix.split(line.text) == nil
        }) else { return false }
        let boxes = lines.compactMap(\.box)
        guard boxes.count == lines.count else { return true }
        func aligned(_ edges: [Double]) -> Bool { edges.max()! - edges.min()! <= Self.menuEdge }
        return aligned(boxes.map(\.left)) || aligned(boxes.map(\.right))
    }

    /// Menü satırlarının sol ya da sağ kenarı bu kadar içinde hizalı (okunan alana oranla).
    static let menuEdge = 0.012

    /// Tek başına okunan etkileşim/HUD etiketi (GTA 6: "SIT", "• ADD TO TRUNK").
    var isActionLabel: Bool { lines.count == 1 && ButtonPrompts.isActionLabel(lines[0].text) }

    /// Satır kutularını `area` içindeki oranlardan dış çerçevenin oranlarına taşır.
    public func placed(in area: TextBox) -> Reading {
        Reading(lines: lines.map { line in
            var moved = line
            moved.box = line.box?.placed(in: area)
            moved.words = line.words?.map { TextWord($0.text, box: $0.box.placed(in: area)) }
            moved.icons = line.icons?.map { IconSlot(box: $0.box.placed(in: area), text: $0.text, image: $0.image) }
            return moved
        })
    }

    /// Yazının içindeki kumanda simgeleri `ButtonIcons.marker` ile işaretlenmiş hali (bkz. `ButtonIcons.mark`).
    /// `monochrome`: yalnız renksiz simgeler (otomatik ekran yazısı; bkz. `ButtonIcons.markFree`).
    public func withButtonIcons(frame: CGImage? = nil, monochrome: Bool = false) -> Reading {
        let marked = ButtonIcons.joinHints(self).lines.map(ButtonIcons.mark)
        guard let frame else { return Reading(lines: marked) }
        return Reading(lines: marked.map { ButtonIcons.markFree($0, frame: frame, monochrome: monochrome) })
    }
}

/// Oyunların ekranda gösterdiği kumanda ipuçlarını tanır: "R2 Swing", "L1 + R1 Spartan Rage",
/// "△ Pick up", "Press ✕ to jump". Konuşma satırları dokunulmadan kalır.
public enum ButtonPrompts {
    /// Her zaman kumanda düğmesi olan simgeler ve adlar (yazı tanıma bazen köşeli parantezle okur).
    private static let buttons: Set<String> = [
        "R1", "R2", "R3", "L1", "L2", "L3", "OPTIONS", "TOUCHPAD",
        "✕", "×", "⨯", "✖", "○", "◯", "●", "□", "▢", "◻", "■", "△", "▲", "⨂",
    ]
    /// Simge yazı tanımada harfe dönüşebilir; yalnız ipucu kalıbında düğme sayılır.
    private static let lookalikes: Set<String> = ["X", "O"]
    private static let verbs: Set<String> = ["press", "hold", "tap", "push", "use", "mash", "release"]
    private static let brackets = CharacterSet(charactersIn: "()[]{}<>「」")

    public static func isPrompt(_ line: String) -> Bool {
        let tokens = line
            .components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "+/")))
            .map { $0.trimmingCharacters(in: brackets) }
            .filter { !$0.isEmpty }
        guard let first = tokens.first else { return false }

        let isButton = { (token: String) in buttons.contains(token.uppercased()) }
        let words = tokens.filter { !isButton($0) && $0.contains(where: \.isLetter) }

        // "R2 Swing", "△ Pick up", "L1 R1 Spartan Rage"
        if isButton(first) { return words.count <= 5 }
        // "PHOTO MODE L1 + R1": düğme sonda, önünde kısa ve noktalamasız bir eylem adı.
        if let last = tokens.last, isButton(last), words.count <= 4, !SubtitleStabilizer.endsSentence(line) { return true }
        // "X Interact", "O Back": ardından kısa, büyük harfle başlayan, noktalamasız bir eylem gelir.
        if lookalikes.contains(first), tokens.count >= 2, tokens.count <= 4,
           tokens[1].first?.isUppercase == true, !SubtitleStabilizer.endsSentence(line) {
            return true
        }
        // "Press ✕ to jump", "Hold R2 to aim"
        if verbs.contains(first.lowercased()), tokens.count >= 2, tokens.count <= 10,
           isButton(tokens[1]) || lookalikes.contains(tokens[1]) {
            return true
        }
        return isIconPrompt(tokens, line: line)
    }

    private static let connectors: Set<String> = ["and", "or"]
    /// Büyük harfle yazılmış kısa İngilizce sözcükler tuş kalıntısı sayılmaz ("HOLD ON TO IT").
    private static let shortWords: Set<String> = [
        "on", "up", "it", "in", "at", "out", "off", "me", "us", "him", "her", "my", "an", "the", "you", "its",
    ]
    /// "to"dan sonra eylem yerine bunlar gelirse konuşmadır ("Hold to your course").
    private static let objects: Set<String> = [
        "the", "a", "an", "my", "your", "his", "her", "our", "their", "me", "you", "him", "them", "us", "it", "this", "that",
    ]

    /// Tuş simgesinin yazı tanımadaki kalıntısı: harfsiz ("@", "•", "9"), tek karakter ("D", "i"; "a" hariç), tuş adı,
    /// "and"/"or" ya da büyük harf içeren en çok üç karakter ("LI", "RE", "Rd", "RB").
    private static func isIconRemnant(_ token: String) -> Bool {
        if !token.contains(where: \.isLetter) || buttons.contains(token.uppercased()) || lookalikes.contains(token)
            || connectors.contains(token.lowercased()) {
            return true
        }
        if token.count == 1 { return token != "a" }
        return token.count <= 3 && token.contains(where: \.isUppercase) && !shortWords.contains(token.lowercased())
    }

    /// GTA 6: "Press/Hold/Use ... to ..." ipucunda tuş simgesi resimdir; yazı tanıma onu ya hiç okumaz ("Press  to open
    /// the map") ya da harf/simge kalıntısı olarak okur ("Press @ to", "Hold I LI to", "Press [RB] to take cover").
    /// Çevrilince tuş kaybolur ve konuşma yerine ipucu görünür. Fiil ile "to" arasında en çok üç kalıntı olabilir;
    /// ünlem, soru, tırnak ya da konuşmacı adı (":") taşıyan satır ve "to"dan sonra eylem yerine nesne gelen satır
    /// ("Hold to your course") konuşma sayılır (Windows: ButtonPrompts.IsIconPrompt, Android: isIconPrompt, havuz:
    /// server/pool/src/prompts.js).
    static func isIconPrompt(_ tokens: [String], line: String) -> Bool {
        if line.contains(where: { "!?\"“”:".contains($0) }) { return false }
        let all = Array(tokens.drop(while: { !$0.contains(where: \.isLetter) }))
        guard all.count >= 3, verbs.contains(all[0].lowercased()),
              let to = all.indices.dropFirst().first(where: { all[$0].lowercased() == "to" }),
              to <= 4, all[1..<to].allSatisfy(isIconRemnant) else { return false }
        let rest = all[(to + 1)...].filter { $0.contains(where: \.isLetter) }
        guard let next = rest.first else { return false }
        return all.count - to - 1 <= 10 && !objects.contains(next.lowercased())
    }

    /// `isIconPrompt` kalıbındaki satırın yazı tanıma sözcüklerinde fiilin ve "to"nun sırası; aralarında en az bir tuş
    /// kalıntısı yoksa ya da kalıp tutmazsa nil. Aradaki kalıntılar ("I LI", "(9 0", "2 and R2") simgenin okunuşudur:
    /// `ButtonIcons.mark` onları kareden kesilecek simge yapar (Windows: ButtonPrompts.IconRemnantSpan).
    static func iconRemnantSpan(_ words: [String], line: String) -> (verb: Int, to: Int)? {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "+/"))
        let tokens = line.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: brackets) }
            .filter { !$0.isEmpty }
        guard isIconPrompt(tokens, line: line),
              let verb = words.firstIndex(where: { $0.trimmingCharacters(in: brackets).contains(where: \.isLetter) }),
              verbs.contains(words[verb].trimmingCharacters(in: brackets).lowercased()) else { return nil }
        var to = verb + 2
        while to < words.count && to <= verb + 4 {
            if words[to].trimmingCharacters(in: brackets).lowercased() == "to" {
                let between = words[(verb + 1)..<to]
                    .flatMap { $0.components(separatedBy: separators) }
                    .map { $0.trimmingCharacters(in: brackets) }
                    .filter { !$0.isEmpty }
                return between.allSatisfy(isIconRemnant) ? (verb, to) : nil
            }
            to += 1
        }
        return nil
    }

    /// "and"/"or": iki tuş kalıntısının arasındaki bağlaç, simge değildir ("Release 2 and R2 to breathe out").
    static func isConnector(_ token: String) -> Bool { connectors.contains(token.lowercased()) }

    /// Etkileşim/HUD etiketi: en çok üç sözcük, hiç küçük harf yok (en az bir büyük harf var), cümle sonu noktalaması
    /// yok. GTA 6'nın etkileşim yazıları ("TAKE AMMO PACK (0/3)", "• ADD TO TRUNK", "TURN ON") ve ekipman yazıları
    /// ("BENCH PRESS") simgeleri harfe dönüşerek okunuyor, altyazı gibi çevriliyordu (#404). Konuşma altyazısı küçük
    /// harf içerir ya da noktalamayla biter ("Yes.", "OKAY.", "WHAT?"); büyük/küçük harfi olmayan yazılara
    /// (Japonca) dokunulmaz. Yalnız tek başına okunan satıra uygulanır: tümü büyük harfli altyazının sarılmış
    /// satırı ("I TOLD YOU" / "NOT TO GO THERE.") bozulmaz (Windows: ButtonPrompts.IsActionLabel, Android: isActionLabel).
    public static func isActionLabel(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
        return (1...3).contains(words.count) && line.contains(where: \.isUppercase)
            && !line.contains(where: \.isLowercase) && !SubtitleStabilizer.endsSentence(line)
    }
}
