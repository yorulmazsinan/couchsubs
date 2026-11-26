// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// "Ekranı çevir": karenin tamamı bir kez okunur, yazılar yerlerine göre gruplara ayrılır (menü, görev paneli, bilgi
/// kutusu, altyazı...) ve her grup ayrı çevrilir. TV her çeviriyi kendi İngilizce yazısının üstüne, o yazının
/// boyutunda koyar (Windows: CouchSubs.Core/ScreenTranslation.cs ile aynı kurallar).
public enum ScreenTranslation {
    /// Ekrandaki bir yazı grubu.
    public struct Group: Equatable, Sendable {
        /// Ayrı ayrı çevrilecek parçalar (başlık, cümle, menü satırı...).
        public var paragraphs: [String]
        /// Karedeki yeri, kenarlara oranla.
        public var box: TextBox
        /// Satırlarının tipik yüksekliği, karenin yüksekliğine oranla; TV yazı boyunu buna göre seçer.
        public var lineHeight: Double
        /// Her parçadaki kumanda simgeleri, parçadaki `ButtonIcons.marker` sırasıyla; simge yoksa nil.
        public var icons: [[IconSlot]]? = nil
        /// GTA 6 telefonunun ekranındaki grubun rolü ve düz ekrandaki yeri (`PhoneChat`); telefon dışındaysa nil.
        var phone: ScreenPhoneCard.Placement? = nil
        /// Özgün yazının satır sayısı; çeviri de bu kadar satıra sığdırılır (TV satır aralığını buna göre seçer).
        public var rows = 1
    }

    public struct Item: Equatable, Sendable {
        public var source: String
        /// Parçaların çevirisi, her parça ayrı satırda.
        public var translation: String
        public var box: TextBox
        public var lineHeight: Double
        /// Çevirinin içindeki kumanda simgeleri (kareden kesilmiş); TV `translation`'ın o yerine koyar.
        public var icons: [IconPlacement]?
        public var style: PhoneTextStyle?
        /// Özgün yazının görünüşü (otomatik ekran yazısı ve "Ekranı çevir"); TV ve masaüstü çeviriyi bu stilde çizer.
        public var look: TextLook?
        /// Çevirisi aslıyla aynı (ad, "ok"): yalnız telefon kartında gösterilir, başka yerde atılır (`ScreenPhoneCard`).
        var unchanged = false
        /// Telefondaki yazının rolü ve düz ekrandaki yeri; kart bunlarla dizilir (`ScreenPhoneCard.layout`).
        var phone: ScreenPhoneCard.Placement?
        /// GTA 6 telefonunun mesajı kendi balonunun üstünde, yerinde (kartsız): TV çeviriyi balona sığdırır (yazı
        /// okunabilir sınıra kadar küçülür, satır kırılır; sığmazsa balon biraz aşağı uzar).
        public var bubble = false
        /// Telefonun yanındaki sohbet panelinin parçası (zemin, kişi adı, karşı tarafın ya da oyuncunun mesajı, not);
        /// yeni çiziciler paneli bunlarla akışta çizer (`ScreenPhoneCard.PanelPart`), eski TV kutuları yerinde çizer.
        public var panel: ScreenPhoneCard.PanelPart?
        /// Panelin zemininde (`card`): parçalar akışla değil, kutularının yerinde çizilir; her Türkçe balon telefondaki
        /// İngilizce balonuyla aynı yükseklikte durur (`ScreenPhoneCard.layout`, JSON `aligned`). Eski TV yok sayar.
        public var aligned = false
        /// Sohbet listesinin satırı ya da ana ekran bileşeni tek kartta (`panel == .row`; JSON `row`). Eski TV yok sayar.
        public var listRow: ScreenPhoneCard.ListRow?
        /// Kutunun genişleyebileceği yatay alan (simgelere ve komşu yazıya kadar; `ScreenFit`); nil ise bilinmiyor.
        public var room: TextBox?
        /// Özgün yazının satır sayısı (`Group.rows`).
        public var rows = 1
        /// Yerinde birebir çizim için kareden ölçülenler (örtü kutusu, zemin/degrade, satır aralığı, boş alan, grup;
        /// `TextPainter`); nil ise eski çizim.
        public var paint: TextPaint?

        public init(source: String, translation: String, box: TextBox, lineHeight: Double, icons: [IconPlacement]? = nil) {
            self.source = source
            self.translation = translation
            self.box = box
            self.lineHeight = lineHeight
            self.icons = icons
        }

        /// Birden çok parça var: TV satır satır, sola yaslı gösterir.
        public var paragraphs: Bool { translation.contains("\n") }
    }

    /// Kalabalık ekranda TV'yi kutuyla doldurmamak ve çeviriyi uzatmamak için en çok bu kadar grup çevrilir; fazlası
    /// olunca en az yazısı olanlar (tek sözcüklük etiketler) bırakılır.
    public static let maxGroups = 30

    /// Grupları sırayla çevirir; her grup çevrilince o ana kadarki sonuçlarla `progress` çağrılır. Çevirisi aslıyla
    /// aynı olan (ad, sayı, zaten Türkçe yazı) grup gösterilmez. `frame` okunan kareyse yazıların içindeki kumanda
    /// simgeleri ondan kesilip çeviriye konur; simgelerin yeri çeviride uydurma adlarla korunur (`IconText`).
    ///
    /// Kare verilince her çeviri özgün yazının stilinde (zemin ve yazı rengi, kalınlık, hiza, BÜYÜK HARF; otomatik ekran
    /// yazısıyla aynı, `TextStyleSampler`) kendi kutusunun yerine çizilir; karede GTA 6 telefonu varsa telefonun yazıları
    /// yanında bir mesaj kartında dizilir (`ScreenPhoneCard`). `memory` verilirse çeviriler (telefon mesajları sohbetin
    /// başlığıyla) saklanır; aynı sohbete dönünce ya da kart yenilenince çevirmene gitmez (`PhoneChatMemory`). `handset`:
    /// karesiz sınamalar için.
    public static func translate(_ reading: Reading, using translate: (String) async throws -> String,
                                 frame: CGImage? = nil, memory: PhoneChatMemory? = nil, handset: ScreenPhoneCard.Handset? = nil,
                                 phoneCard: Bool = true, panelScale: Double = 1,
                                 progress: ([Item]) -> Void = { _ in }) async throws -> [Item] {
        let phone = handset ?? frame.flatMap { ScreenPhoneCard.phone(in: $0) }
        let all = withImages(groups(reading, frame: frame, wholeScreen: true, handset: phone), from: frame)
        let chat = chatTitle(all)
        var made: [Int: Item] = [:]
        // Telefon listesi kartlarının avatarı, rozeti ve seçim çerçevesi bu kareden (`PhoneListLook`).
        let looks = PhoneListLook()
        func shown() -> [Item] {
            var items = present(made.keys.sorted().map { made[$0]! }, phone: phone, card: phoneCard, textScale: panelScale)
            if let frame { items = looks.apply(items, frame: frame) }
            // Liste kartı kendi kutusunda çizilir; yerinde birebir çizim ölçüleri (`ScreenFit`) ona uygulanmaz.
            return ScreenFit.fitted(items.filter { $0.panel != .row }, frame: frame) + items.filter { $0.panel == .row }
        }
        // Önce çevirmene gitmeyecek gruplar (sözlük, bu ekranda daha önce çevrilmiş yazı): çeviri beklemeden hemen çizilir.
        let prepared = all.map { $0.paragraphs.map(IconText.protect) }
        var waiting: [Int] = []
        for (g, group) in all.enumerated() {
            let ready = group.paragraphs.map { known($0, in: group) ?? remembered($0, in: group, chat: chat, memory: memory) }
            guard ready.allSatisfy({ $0 != nil }) else { waiting.append(g); continue }
            if let item = item(group, prepared[g], ready.map { $0! }, keepUnchanged: phone != nil) { made[g] = styled(item, frame: frame) }
        }
        if !made.isEmpty, !waiting.isEmpty {
            let early = shown()
            if !early.isEmpty { progress(early) }
        }
        for g in waiting {
            let group = all[g]
            try Task.checkCancellation()
            var translated: [String] = []
            for (index, paragraph) in prepared[g].enumerated() {
                let source = group.paragraphs[index]
                if let known = known(source, in: group) ?? remembered(source, in: group, chat: chat, memory: memory) {
                    translated.append(known)
                    continue
                }
                let prices = PriceText.protect(paragraph.text)
                let result = PriceText.restore(try await translate(prices.text), prices.values)
                memory?.remember(chat: memoryChat(group, chat), source: source, translation: result)
                translated.append(result)
            }
            guard let item = item(group, prepared[g], translated, keepUnchanged: phone != nil) else { continue }
            made[g] = styled(item, frame: frame)
            let now = shown()
            if !now.isEmpty { progress(now) }
        }
        return shown()
    }

    /// Çevirmen parçaları tek istekte çevirebiliyorsa (yapay zekâ) ekranın bütün parçaları birlikte gider ve sonuç bir
    /// kerede gelir; yoksa gruplar sırayla çevrilip hazırlandıkça bildirilir. `frame`: bkz. yukarıdaki `translate`.
    public static func translate(_ reading: Reading, using translator: TextTranslator, frame: CGImage? = nil,
                                 memory: PhoneChatMemory? = nil, handset: ScreenPhoneCard.Handset? = nil,
                                 phoneCard: Bool = true, panelScale: Double = 1,
                                 progress: ([Item]) -> Void = { _ in }) async throws -> [Item] {
        guard translator.translatesTogether else {
            return try await translate(reading, using: { try await translator.translate($0) }, frame: frame, memory: memory,
                                       handset: handset, phoneCard: phoneCard, panelScale: panelScale, progress: progress)
        }
        let phone = handset ?? frame.flatMap { ScreenPhoneCard.phone(in: $0) }
        let groups = withImages(groups(reading, frame: frame, wholeScreen: true, handset: phone), from: frame)
        let prepared = groups.map { group in group.paragraphs.map(IconText.protect) }
        let chat = chatTitle(groups)
        // Sözlükteki kısa arayüz etiketleri ("SCROLL", "SEND", "BACK") ve telefondaki kişi adları çevirmene gitmez;
        // daha önce görülen sohbetin mesajları da (`memory`); fiyatlar adla korunur.
        let sources = groups.flatMap(\.paragraphs)
        let owners = groups.flatMap { group in group.paragraphs.map { _ in group } }
        let prices = prepared.flatMap { list in list.map { PriceText.protect($0.text) } }
        // Diskteki çeviri önbelleğinde duran yazı (menü satırları oturumdan oturuma tekrar eder) da çevirmene gitmez.
        var knowns: [String?] = sources.indices.map { i in
            known(sources[i], in: owners[i]) ?? remembered(sources[i], in: owners[i], chat: chat, memory: memory)
                ?? translator.cachedTranslation(prices[i].text).map { PriceText.restore($0, prices[i].values) }
        }
        let asked = prices.indices.filter { knowns[$0] == nil }
        guard !sources.isEmpty else { return [] }
        // Gruplar: hazır olanlar (bütün parçaları biliniyor) çeviri isteğini beklemeden hemen çizilir.
        func laid(_ translations: [String?]) -> [Item] {
            var items: [Item] = []
            var next = 0
            for (index, group) in groups.enumerated() {
                let count = group.paragraphs.count
                let part = (next..<next + count).map { $0 < translations.count ? translations[$0] : nil }
                next += count
                guard part.allSatisfy({ $0 != nil }) else { continue }
                if let item = item(group, prepared[index], part.map { $0! }, keepUnchanged: phone != nil) {
                    items.append(styled(item, frame: frame))
                }
            }
            return ScreenFit.fitted(present(items, phone: phone, card: phoneCard, textScale: panelScale), frame: frame)
        }
        if !asked.isEmpty {
            let early = laid(knowns)
            if !early.isEmpty { progress(early) }
        }
        let answers = asked.isEmpty ? [] : try await translator.translateAll(asked.map { prices[$0].text })
        try Task.checkCancellation()
        for (k, index) in asked.enumerated() where k < answers.count {
            knowns[index] = PriceText.restore(answers[k], prices[index].values)
            memory?.remember(chat: memoryChat(owners[index], chat), source: sources[index], translation: knowns[index]!)
        }
        // Gelmeyen çeviri boş kalır: parça aslıyla gösterilir.
        let shown = laid(knowns.map { $0 ?? "" })
        if !shown.isEmpty { progress(shown) }
        return shown
    }

    /// Oyun arayüzü sözlüğündeki kısa etiketin Türkçesi ("SCROLL" → "KAYDIR", "TIP" → "BAHŞİŞ VER"); simgeli ya da
    /// sözlükte olmayan parçada nil (çevirmene gider).
    static func known(_ paragraph: String, in group: Group? = nil) -> String? {
        // Telefondaki kişi adı (sohbet başlığı, listedeki ad) çevrilmez: "Rose" "Gül", "May" "Mayıs" olmasın.
        if group?.phone?.role.keepsText == true { return paragraph }
        // "JASON & LUCIA" gibi yalnız özel adlardan oluşan sekme/başlık çevrilmez (#859).
        if keepsNames(paragraph) { return paragraph }
        guard !paragraph.contains(ButtonIcons.marker) else { return nil }
        return UiCommands.translateLabel(paragraph)
    }

    /// Telefondaki sohbetin başlığı (kişi adı); sohbet listesinde ya da telefonsuz karede boş.
    static func chatTitle(_ groups: [Group]) -> String {
        groups.first { $0.phone?.role == .header }?.paragraphs.first ?? ""
    }

    /// Hafızadaki yeri: telefon mesajı sohbetin başlığıyla, telefon dışındaki yazı (görev, menü) başlıksız saklanır.
    static func memoryChat(_ group: Group, _ chat: String) -> String { group.phone == nil ? "" : chat }

    /// Bu sohbette (telefon dışındaki yazıda: bu ekranda) daha önce çevrilmiş parçanın çevirisi (`PhoneChatMemory`).
    static func remembered(_ paragraph: String, in group: Group, chat: String, memory: PhoneChatMemory?) -> String? {
        memory?.translation(chat: memoryChat(group, chat), of: paragraph)
    }

    /// Öğeye özgün yazının görünüşü: zemin ve yazı rengi, kalınlık, dar yazı, hiza; özgün yazı BÜYÜK HARFse çeviri de
    /// büyütülür. Önceden "Ekranı çevir" her yazıyı aynı siyah kutuda gösteriyordu, otomatik ekran yazısı ise özgün
    /// stilde; kullanıcılar çevirinin "ayrı bir kutuda" durduğunu söylüyordu.
    static func styled(_ item: Item, frame: CGImage?) -> Item {
        guard let frame else { return item }
        var styled = item
        let (surface, look) = TextStyleSampler.sample(frame, box: item.box, lines: [], source: item.source)
        styled.style = surface
        styled.look = look
        if look.upper { styled.translation = TextStyleSampler.turkishUpper(item.translation) }
        return styled
    }

    /// Gösterilecek öğeler: telefon varsa `card` açıkken kartı dizilir; kapalıyken (varsayılan ayar) her mesajın
    /// çevirisi kendi balonunun üstünde, balonun rengiyle yerinde kalır (`Item.bubble`). İstek: "çeviriyi birebir o
    /// görüntünün yerine geçiremez miyiz?"; kartta son mesaj kayboluyor, telefonun altındaki yazılar karta karışıyordu
    /// (X, beta.79). Çevirisi aslıyla aynı öğeler (kart dışında; yerinde kişi adı) atılır, özgün yazı görünür kalır.
    static func present(_ items: [Item], phone: ScreenPhoneCard.Handset?, card: Bool = true, textScale: Double = 1) -> [Item] {
        let laid: [Item]
        if let phone, card {
            laid = ScreenPhoneCard.layout(items, handset: phone, textScale: textScale)
        } else {
            laid = items.map { item in
                var placed = item
                placed.bubble = item.phone?.role.inCard == true
                return placed
            }
        }
        return withoutDuplicates(laid.filter { !$0.unchanged })
    }

    // MARK: - Aynı yerde tek çizim (#827)

    /// Aynı okumada iki satırın (ya da iki öğenin) kutusu küçüğünün alanının en az bu kadarı kadar örtüşüyorsa aynı yazının
    /// iki okunuşudur; yalnız harfi çok olanı kalır.
    public static let duplicateShare = 0.5
    /// Ayrı yollardan gelen iki çevirinin ("Ekranı çevir", otomatik ekran yazısı, ek alan) kutusu küçüğünün alanının en az bu
    /// kadarı kadar örtüşüyorsa aynı yazıyı çiziyorlardır; yalnız biri çizilir. Önceden GTA 6 haritasında ikisi üst üste
    /// çiziliyor, alttakinin yazısı üsttekinin arasından görünüyordu.
    public static let coverShare = 0.25

    /// İki kutunun kesişiminin küçük kutunun alanına oranı (0…1).
    public static func overlap(_ a: TextBox, _ b: TextBox) -> Double {
        let width = min(a.right, b.right) - max(a.left, b.left)
        let height = min(a.bottom, b.bottom) - max(a.top, b.top)
        guard width > 0, height > 0 else { return 0 }
        let smaller = min((a.right - a.left) * (a.bottom - a.top), (b.right - b.left) * (b.bottom - b.top))
        return smaller > 0 ? min(1, width * height / smaller) : 0
    }

    private static func letters(_ text: String) -> Int { text.filter(\.isLetter).count }

    /// Aynı yazının iki okunuşundan (yazı tanıma bir satırı hem bütün hem parça okuyabiliyor) yalnız harfi çok olanı kalır;
    /// eşitse önce gelen. Sıra korunur. Önceden ikisi ayrı çevrilip üst üste çiziliyordu ("Donnie'nin Paketini Bul" altında
    /// "Bulur").
    public static func withoutDuplicateLines(_ lines: [TextLine]) -> [TextLine] {
        let counts = lines.map { letters($0.text) }
        return lines.indices.filter { i in
            guard let box = lines[i].box else { return true }
            return !lines.indices.contains { j in
                guard j != i, let other = lines[j].box, overlap(box, other) >= duplicateShare else { return false }
                return counts[j] > counts[i] || (counts[j] == counts[i] && j < i)
            }
        }.map { lines[$0] }
    }

    /// Satırın başındaki ya da sonundaki simge kırıntısı (menüdeki harita/dükkân/ayar simgesi yazı tanımada "<", "©",
    /// "@" ya da baştaki tek harf olarak okunur) satırdan atılır; kutu yalnız yazının sözcüklerini kapsar (#827). Önceden
    /// çeviri kutusu simgeyi de örtüyordu. Sözcük yerleri bilinmiyorsa harf sayısına göre kestirilir. Kumanda simgeli
    /// satıra (simge çeviride yerinde gösterilir), sayıya, noktalamaya ve geriye iki harf kalmayacaksa dokunulmaz.
    public static func withoutEdgeMarks(_ line: TextLine) -> TextLine {
        guard (line.icons ?? []).isEmpty, !line.text.contains(ButtonIcons.marker), let box = line.box else { return line }
        let measured = !(line.words ?? []).isEmpty
        let words = measured ? line.words! : ButtonIcons.estimate(line.text, box)
        var start = 0, end = words.count
        while start < end - 1, isEdgeMark(words[start].text, leading: true) { start += 1 }
        while end - 1 > start, isEdgeMark(words[end - 1].text, leading: false) { end -= 1 }
        guard start > 0 || end < words.count else { return line }
        let kept = Array(words[start..<end])
        guard kept.reduce(0, { $0 + letters($1.text) }) >= 2 else { return line }
        var trimmed = line
        trimmed.text = kept.map(\.text).joined(separator: " ")
        trimmed.box = TextBox(left: start > 0 ? kept[0].box.left : box.left, top: box.top,
                              right: end < words.count ? kept[kept.count - 1].box.right : box.right, bottom: box.bottom)
        trimmed.words = measured ? kept : nil
        return trimmed
    }

    /// Yalnız noktalamadan oluşan parça simge değildir ("...", "-").
    private static let punctuation = Set(".,!?…:;-–—'\"’”")

    /// Kumanda tuşu yazısı ("(✕)", "△", "R1"): kontrol şemasında etiketin parçasıdır, çeviride de yazılır; atılmaz.
    private static let buttonGlyphs = Set("✕×△○□◯⨯")

    /// Simge kırıntısı mı: harfi ve rakamı yok ve yalnız noktalama ya da kumanda tuşu değil ("<", "©", "@"); satır başında
    /// tek harf de ("G Settings"; "a", "A", "I" sözcüktür).
    static func isEdgeMark(_ word: String, leading: Bool) -> Bool {
        let core = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
        if word.contains(where: \.isNumber) || word.contains(where: { buttonGlyphs.contains($0) })
            || ButtonIcons.isButtonName(core) || (word.count > 1 && word.first == "(" && word.last == ")") { return false }
        if !word.contains(where: \.isLetter) { return !word.allSatisfy { punctuation.contains($0) } }
        return leading && word.count == 1 && !["a", "A", "I"].contains(word)
    }

    /// Telefon kartının parçası (zemin, balon, başlık): kart bilerek üst üste dizilir, çakışma kuralına girmez.
    static func isCardPart(_ item: Item) -> Bool { item.phone != nil || ScreenPhoneCard.isBackdrop(item) }

    /// Aynı okumanın öğelerinden aynı yeri çizenlerin yalnız harfi çok olanı kalır (`duplicateShare`); kart dokunulmaz.
    static func withoutDuplicates(_ items: [Item]) -> [Item] {
        let counts = items.map { letters($0.source) }
        return items.indices.filter { i in
            isCardPart(items[i]) || !items.indices.contains { j in
                guard j != i, !isCardPart(items[j]), overlap(items[i].box, items[j].box) >= duplicateShare else { return false }
                return counts[j] > counts[i] || (counts[j] == counts[i] && j < i)
            }
        }.map { items[$0] }
    }

    /// Katmanlar tek listede: sonra gelen öğe, kendisiyle çakışan (`coverShare`) önceki öğelerin yerine geçer (yeni olan
    /// eskisini değiştirir). Telefon kartının parçaları dokunulmaz.
    public static func layered(_ items: [Item]) -> [Item] {
        var result: [Item] = []
        for item in items {
            if !isCardPart(item) {
                result.removeAll { !isCardPart($0) && overlap($0.box, item.box) >= coverShare }
            }
            result.append(item)
        }
        return result
    }

    /// `items`'tan `top` öğelerinden biriyle çakışanlar (`coverShare`) atılır: "Ekranı çevir" ekrandayken onun yazılarının
    /// yerindeki otomatik ekran yazısı ve ek alan kutuları çizilmez.
    public static func uncovered(_ items: [Item], by top: [Item]) -> [Item] {
        items.filter { item in !top.contains { overlap(item.box, $0.box) >= coverShare } }
    }

    /// Ekranın yazılarının izi: tuşa yeniden basınca ekranın değişip değişmediği buna bakılarak anlaşılır (`isSameScreen`).
    public static func fingerprint(_ reading: Reading) -> String {
        TextMatch.normalize(groups(reading).flatMap(\.paragraphs).map(IconText.plain).joined(separator: " "))
    }

    /// İki iz aynı ekranın mı. Çeviriler ekrandayken tuşa yeniden basmak önceden hep onları kaldırıyordu: telefonda başka
    /// bir sohbete geçip basınca yeni sohbet çevrilmiyor, ekran boşalıyordu. Artık ekran değiştiyse yeni kare çevrilir,
    /// değişmediyse çeviriler kalkar (Windows ve Android ile aynı).
    /// Aynı ekranın iki okuması en az bu kadar benzer; yeni bir mesajın eklenmesi bile ekranı "değişmiş" yapar.
    public static let sameScreenSimilarity = 0.95

    public static func isSameScreen(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return a == b }
        return TextMatch.isSimilar(a, b, threshold: sameScreenSimilarity)
    }

    /// Simgelerin resimleri kareden kesilir; kare yoksa gruplar olduğu gibi kalır (simge okunan haliyle yazılır).
    static func withImages(_ groups: [Group], from frame: CGImage?) -> [Group] {
        guard let frame else { return groups }
        return groups.map { group in
            guard let icons = group.icons else { return group }
            var cut = group
            cut.icons = icons.map { ButtonIcons.withImages($0, frame: frame) }
            return cut
        }
    }

    /// Grubun gösterilecek çevirisi; çevirisi aslıyla aynıysa (ad, sayı, zaten Türkçe yazı) nil. Boş çeviride parçanın
    /// aslı gösterilir; simgeler TV'de çevirinin içindeki yerlerine konur.
    static func item(_ group: Group, _ prepared: [IconText.Protected], _ translations: [String],
                     keepUnchanged: Bool = false) -> Item? {
        var changed = false
        var texts: [String] = []
        var slots: [IconSlot] = []
        for (index, paragraph) in group.paragraphs.enumerated() {
            let translated = (index < translations.count ? translations[index] : "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = translated.isEmpty ? IconText.indexed(paragraph, offset: slots.count)
                : IconText.restore(translated, names: index < prepared.count ? prepared[index].names : [], offset: slots.count)
            changed = changed || !TextMatch.isSimilar(TextMatch.normalize(IconText.plain(paragraph)),
                                                      TextMatch.normalize(IconText.plain(text)), threshold: 0.90)
            texts.append(text)
            if let all = group.icons, index < all.count { slots += all[index] }
        }
        guard changed || keepUnchanged else { return nil }
        let rendered = IconText.render(texts.joined(separator: "\n"), slots: slots)
        var item = Item(source: group.paragraphs.map(IconText.plain).joined(separator: "\n"), translation: rendered.text,
                        box: group.box, lineHeight: group.lineHeight, icons: rendered.icons.isEmpty ? nil : rendered.icons)
        item.unchanged = !changed
        item.phone = group.phone
        item.rows = group.rows
        return item
    }

    /// Satırları gruplara toplar. Yazının içindeki kumanda simgeleri işaretlenir (`ButtonIcons`); kumanda ipuçları ve
    /// yazı tanıma çöpleri atılır; harfi olmayan ya da tek harfli satırlar ("23m", "9", "+") göstergedir, çevrilmez. Bir
    /// satır, üstündeki satırın hemen altındaysa, yatayda onunla üst üste biniyorsa ve yazı boyu benziyorsa o gruba
    /// katılır; küçük harfle başlayan satır üstteki bitmemiş cümleye katılır (`continues`). Gruplar yukarıdan aşağı; en çok
    /// `maxGroups`, en çok yazısı olanlar.
    ///
    /// `wholeScreen` ("Ekranı çevir"): yazı tanımanın bozduğu fiyatlar düzelir (`PriceText.repair`) ve tuş çubukları
    /// atılmaz, etiketlerine bölünür (`promptPieces`): tuş simgeleri ve fiyatlar çeviriye girmez, ekranda görünür kalır;
    /// aynı satırdaki her seçenek kendi kutusunda çevrilir, çeviriler üst üste binmez.
    ///
    /// `handset`: karede GTA 6 telefonu varsa ekranındaki satırlar ayrı gruplanır (`PhoneChat`: balon, başlık, liste).
    public static func groups(_ reading: Reading, frame: CGImage? = nil, keepIdentifiers: Bool = false,
                              wholeScreen: Bool = false, handset: ScreenPhoneCard.Handset? = nil) -> [Group] {
        var marked = (wholeScreen ? Reading(lines: reading.lines.map(repaired)) : reading).withButtonIcons()
        if wholeScreen {
            marked = Reading(lines: marked.lines.flatMap { line -> [TextLine] in
                guard (line.icons ?? []).isEmpty, line.box != nil,
                      ButtonPrompts.isPrompt(line.text) || hasWideGap(line) else { return [line] }
                return promptPieces(line)
            })
            // Menü şeridinin sekmeleri ("JASON & LUCIA   MAP   BRIEF") tek satır okunsa da ayrı ayrı çevrilir (#859).
            let aspect = frame.map { Double($0.width) / Double(max(1, $0.height)) } ?? 16.0 / 9.0
            marked = Reading(lines: marked.lines.flatMap { menuPieces($0, aspect: aspect, frame: frame) })
        }
        // Tam ekranda yalnız aksi halde atılacak kısa ipuçlarında simgeyi görüntüden doğrula.
        if let frame {
            marked = Reading(lines: marked.lines.map { line in
                guard (line.icons ?? []).isEmpty else { return line }
                if ButtonPrompts.isPrompt(line.text) { return ButtonIcons.markFree(line, frame: frame) }
                // "Ekranı çevir": satır ucundaki kısa parça ("RECENTER 13", "EXIT O") okunmuş bir tuş simgesi olabilir;
                // görüntüden doğrulanırsa simge olur, kutunun dışında kalır (#860).
                return wholeScreen && hasShortEdge(line) ? ButtonIcons.markFree(line, frame: frame, monochrome: true) : line
            })
        }
        let lines = marked.withoutButtonPrompts().withoutOcrNoise(keepIdentifiers: keepIdentifiers).lines
            .filter { $0.box != nil && isWords($0.text) }
            // Saat ve sayaç ("12:00 pm") çevrilmez.
            .filter { !wholeScreen || !isClock($0.text) }
            // Aynı satırdaki parçalar (tuş çubuğunun etiketleri) soldan sağa; sıralama kararlı değildir.
            .sorted { $0.box!.top != $1.box!.top ? $0.box!.top < $1.box!.top : $0.box!.left < $1.box!.left }
        // "Ekranı çevir": haritanın görev kartı kendi parçalarına ayrılır (başlık, açıklama, ayrıntılar; `MissionCard`).
        // Aynı yazının iki okunuşu tek satır kalır; satırın başındaki/sonundaki simge kutunun dışında kalır (#827).
        // Telefonun satırları girmez: eğik telefonda kutuları bilerek üst üste.
        let plain = { (all: [TextLine]) -> [Group] in
            // "Ekranı çevir"de satırın başındaki/sonundaki kumanda simgesi kutunun dışında kalır, görünür (#860).
            let lines = withoutDuplicateLines(all.map(withoutEdgeMarks).map { wholeScreen ? withoutEdgeIcons($0) : $0 })
            return wholeScreen ? withMissionCards(lines, frame: frame) : groups(from: lines)
        }
        guard let handset else { return plain(lines) }
        let onPhone = lines.filter { PhoneChat.onScreen(handset.flat($0.box!)) }
        guard !onPhone.isEmpty else { return plain(lines) }
        // Süzülmemiş satırlar da gider: harfsiz hava durumu satırı ("76°") ana ekranı belli eder.
        let raw = reading.lines.filter { $0.box.map { PhoneChat.onScreen(handset.flat($0)) } ?? false }
        return plain(lines.filter { !PhoneChat.onScreen(handset.flat($0.box!)) }) + PhoneChat.groups(onPhone, handset: handset, raw: raw)
    }

    /// Satırlardaki görev kartları kendi gruplarıyla (kare varsa yalnız düz panelin üstündekiler), kalanlar her zamanki
    /// gibi. Kart tanınmadan başlık açıklamanın ilk cümlesine katılıyor, beş-altı sözcüklük başlık cümleyle birlikte
    /// çevriliyordu.
    static func withMissionCards(_ lines: [TextLine], frame: CGImage?) -> [Group] {
        let cards = MissionCard.find(lines).filter { card in frame.map { MissionCard.onPanel($0, card.all.map { lines[$0] }) } ?? true }
        let taken = Set(cards.flatMap(\.all))
        let rest = lines.indices.filter { !taken.contains($0) }.map { lines[$0] }
        return (labelColumns(groups(from: rest), rest) + cards.flatMap { MissionCard.groups($0, lines) })
            .sorted { $0.box.top < $1.box.top }
    }

    /// Kısa etiket satırı: en çok bu kadar sözcük (otomatik ekran yazısıyla aynı, `RegionWatcher.labelWords`).
    static let labelWords = 5

    /// Bütün satırları kısa BÜYÜK HARFLİ etiket olan grup (tuş ipuçları sütunu, menü listesi) satır satır gruptur: her
    /// etiket kendi kutusunda, kendi yerinde çevrilir. Önceden sütun tek kutu oluyor, sağındaki tuş simgelerini de
    /// örtüyordu (#860).
    static func labelColumns(_ groups: [Group], _ lines: [TextLine]) -> [Group] {
        groups.flatMap { group -> [Group] in
            let own = lines.filter { line in
                let box = line.box!, x = (box.left + box.right) / 2, y = (box.top + box.bottom) / 2
                return x >= group.box.left - 1e-6 && x <= group.box.right + 1e-6 && y >= group.box.top - 1e-6 && y <= group.box.bottom + 1e-6
            }
            guard own.count > 1, own.allSatisfy({ line in
                let plain = IconText.plain(line.text)
                return plain.split(whereSeparator: \.isWhitespace).count <= labelWords && plain.contains(where: \.isLetter)
                    && !plain.contains(where: \.isLowercase)
            }) else { return [group] }
            return own.map { line in
                let icons = paragraphIcons([line])
                return Group(paragraphs: paragraphs([line]), box: line.box!, lineHeight: line.box!.bottom - line.box!.top,
                             icons: icons.contains { !$0.isEmpty } ? icons : nil)
            }
        }
    }

    /// Saat ya da sayaç ("12:00 pm", "x3"): harflerinden çok rakamı var, fiyat değil. Çevrilmez.
    static func isClock(_ text: String) -> Bool {
        ScreenTextNoise.isNoise(text, menu: true)
            && !text.split(whereSeparator: \.isWhitespace).contains { PriceText.isMoney(String($0)) }
    }

    /// Satırın ilk ya da son parçası en çok iki harflik (okunmuş tuş simgesi olabilir: "13", "O", "®").
    static func hasShortEdge(_ line: TextLine) -> Bool {
        let parts = line.text.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return false }
        return parts.last!.count <= 2 || parts.first!.count <= 2
    }

    // MARK: - Menü şeridi, özel adlar, kenardaki tuş simgesi (#856, #859, #860)

    /// Menü şeridinde sekmelerin arası: satır yüksekliğinin bu katından geniş boşluk sözcük arası değildir (sözcük arası
    /// yazı boyunun üçte biri kadardır). GTA 6 haritasının üst şeridi "JASON & LUCIA   MAP   BRIEF   PROGRESS" tek satır
    /// okunuyor, sekmeler tek cümle sanılıp "LUCIA HARİTASI KISA İLERLEME RAPORU" diye çevriliyordu.
    public static let menuGap = 0.9

    /// BÜYÜK HARFLİ satırdaki geniş boşluklar (`menuGap`) ayrı sekmelerdir: her sekme kendi satırı, kutusu kendi yazısı.
    /// Kare verilirse boşluklar görüntüden bulunur (`inkPieces`; yazı tanımanın sözcük kutuları boşluğu da kapsıyor),
    /// yoksa sözcük yerlerinden. Satırda simge varsa ya da satır büyük harf değilse dokunulmaz. `aspect`: kutuların
    /// oranlandığı görüntünün genişlik/yükseklik oranı. İki harfi olmayan parça atılır.
    public static func menuPieces(_ line: TextLine, aspect: Double = 16.0 / 9.0, frame: CGImage? = nil) -> [TextLine] {
        guard let box = line.box, (line.icons ?? []).isEmpty, TextStyleSampler.isUpper(line.text),
              line.text.split(whereSeparator: \.isWhitespace).count >= 2 else { return [line] }
        let limit = (box.bottom - box.top) * menuGap / max(0.1, aspect)
        if let frame { return inkPieces(line, frame: frame, gap: limit) }
        guard let words = line.words, words.count >= 2 else { return [line] }
        var runs: [[TextWord]] = [[words[0]]]
        for word in words.dropFirst() {
            if word.box.left - runs[runs.count - 1].last!.box.right > limit { runs.append([]) }
            runs[runs.count - 1].append(word)
        }
        guard runs.count > 1 else { return [line] }
        return runs.filter { run in run.reduce(0) { $0 + $1.text.filter(\.isLetter).count } >= 2 }.map { run in
            let span = run.dropFirst().reduce(run[0].box) { $0.union($1.box) }
            return TextLine(run.map(\.text).joined(separator: " "),
                            box: TextBox(left: span.left, top: box.top, right: span.right, bottom: box.bottom),
                            confidence: line.confidence, words: run)
        }
    }

    /// Satırın yazı sütunları: kutudaki her sütunda zeminden (kutunun ortanca parlaklığı) belirgin ayrılan nokta var mı;
    /// `gap`'ten geniş boş aralıklar yazıyı parçalara böler. Parçalar kareye oranla [sol, sağ].
    static func inkSpans(_ frame: CGImage, _ box: TextBox, gap: Double) -> [(left: Double, right: Double)] {
        let fw = Double(frame.width), fh = Double(frame.height)
        let rect = CGRect(x: max(0, box.left) * fw, y: max(0, box.top) * fh,
                          width: (min(1, box.right) - max(0, box.left)) * fw, height: (min(1, box.bottom) - max(0, box.top)) * fh)
        let columns = max(8, min(800, Int(rect.width.rounded())))
        let rows = 12
        guard rect.width >= 8, rect.height >= 4,
              let grid = GamePhonePixels(frame, in: rect, width: columns, height: rows) else { return [] }
        var luma = [Int](repeating: 0, count: columns * rows)
        for i in 0..<(columns * rows) {
            let p = i * 4
            luma[i] = (299 * Int(grid.bytes[p]) + 587 * Int(grid.bytes[p + 1]) + 114 * Int(grid.bytes[p + 2])) / 1000
        }
        let median = luma.sorted()[luma.count / 2]
        let ink = (0..<columns).map { x in (0..<rows).contains { y in abs(luma[y * columns + x] - median) > 60 } }
        let step = (box.right - box.left) / Double(columns)
        let blank = max(1, Int((gap / max(1e-9, step)).rounded(.up)))
        var spans: [(left: Int, right: Int)] = []
        var x = 0
        while x < columns {
            guard ink[x] else { x += 1; continue }
            var end = x
            var run = 0
            var probe = x + 1
            while probe < columns {
                if ink[probe] { end = probe; run = 0 } else { run += 1; if run > blank { break } }
                probe += 1
            }
            spans.append((x, end))
            x = end + 1
        }
        return spans.map { (box.left + Double($0.left) * step, box.left + Double($0.right + 1) * step) }
    }

    /// Menü satırının sekmeleri: görüntüdeki geniş boşluklardan (`inkSpans`) bölünür. Sözcükler sırasıyla parçalara
    /// dağıtılır: her parçanın harf sayısı payı genişlik payına en yakın olacak biçimde (yazı tanımanın sözcük kutuları
    /// boşlukları da kapsadığı için yerlerine bakılmaz). Parça sayısı sözcüklerden çoksa dokunulmaz.
    static func inkPieces(_ line: TextLine, frame: CGImage, gap: Double) -> [TextLine] {
        guard let box = line.box else { return [line] }
        let spans = inkSpans(frame, box, gap: gap)
        let words = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard spans.count >= 2, words.count >= spans.count else { return [line] }
        let k = spans.count, n = words.count
        let widths = spans.map { $0.right - $0.left }
        let totalWidth = widths.reduce(0, +)
        let sizes = words.map { Double($0.count) }
        let totalSize = sizes.reduce(0, +) + Double(n - k)
        // En iyi bölme: best[i][j] ilk i sözcük j parçada; parçanın payı sözcükleri ve aralarındaki boşluklar.
        var best = [[Double]](repeating: [Double](repeating: .infinity, count: k + 1), count: n + 1)
        var from = [[Int]](repeating: [Int](repeating: 0, count: k + 1), count: n + 1)
        best[0][0] = 0
        for i in 1...n {
            for j in 1...min(i, k) {
                for start in (j - 1)..<i where best[start][j - 1] < .infinity {
                    let size = sizes[start..<i].reduce(0, +) + Double(i - start - 1)
                    let cost = best[start][j - 1] + abs(size / totalSize - widths[j - 1] / totalWidth)
                    if cost < best[i][j] {
                        best[i][j] = cost
                        from[i][j] = start
                    }
                }
            }
        }
        var bounds: [Int] = []
        var i = n
        for j in stride(from: k, to: 0, by: -1) {
            bounds.insert(from[i][j], at: 0)
            i = from[i][j]
        }
        bounds.append(n)
        return (0..<k).compactMap { j -> TextLine? in
            let text = words[bounds[j]..<bounds[j + 1]].joined(separator: " ")
            guard text.filter(\.isLetter).count >= 2 else { return nil }
            return TextLine(text, box: TextBox(left: spans[j].left, top: box.top, right: spans[j].right, bottom: box.bottom),
                            confidence: line.confidence)
        }
    }

    /// Oyunun logosu ve stilize başlığı çevrilmez: yalnız Roma rakamı ("VI"), oyun adı ("Grand Theft Auto", "GTA VI",
    /// "Rockstar Games"). Önceden PS5 ana ekranındaki "Grand Theft Auto VI" "araba hırsızlığı." oluyordu (Sinan Bey, beta.93).
    static func isTitleMark(_ text: String) -> Bool {
        let words = text.uppercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "-" }).map(String.init)
        guard !words.isEmpty else { return false }
        let roman = try! NSRegularExpression(pattern: "^(?=[IVX]+$)X{0,3}(IX|IV|V?I{0,3})$")
        func isRoman(_ word: String) -> Bool {
            roman.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil
        }
        if words.allSatisfy(isRoman) { return true }
        let joined = words.filter { !isRoman($0) }.joined(separator: " ")
        return titleMarks.contains(joined)
    }

    private static let titleMarks: Set<String> = ["GRAND THEFT AUTO", "GTA", "ROCKSTAR GAMES", "ROCKSTAR"]

    /// Yalnız özel adlardan oluşan yazı ("JASON & LUCIA", "Bonnie & Clyde"): "&" ile bağlı, her biri bir iki sözcüklük
    /// (BÜYÜK HARFLİ yazıda tek sözcüklük), büyük harfle başlayan adlar. Çevirmene gitmez; çevirisi aslıdır (kutusu çizilmez, özgün yazı görünür kalır).
    public static func keepsNames(_ text: String) -> Bool {
        let plain = IconText.plain(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if isTitleMark(plain) || isPlaceName(plain) || isProductName(plain) { return true }
        let parts = plain.components(separatedBy: " & ")
        guard parts.count >= 2 else { return false }
        // BÜYÜK HARFLİ yazıda her ad tek sözcük: "JASON & LUCIA MAP" (sekmeler tek satır okununca) ad değildir.
        let most = TextStyleSampler.isUpper(plain) ? 1 : 2
        return parts.allSatisfy { part in
            let words = part.split(separator: " ")
            return (1...most).contains(words.count) && words.allSatisfy { word in
                word.filter(\.isLetter).count >= 2 && word.allSatisfy { $0.isLetter || "'’-.".contains($0) }
                    && word.first?.isUppercase == true && !SpeakerNames.notNames.contains(word.lowercased())
            }
        }
    }

    /// Haritadaki yer adı ("Peregrine Bay", "Shoeless Keys", "Key Lento") ve soluk okunan parçası ("ne Bay"): bir-üç sözcük,
    /// yalnız harf, son ya da ilk sözcük yer türü (Bay, Key, Island…), BÜYÜK HARFLİ değil. Çevrilmez (beta.100 3408: "Peregrine
    /// Bay" parçası "ne Körfezi" olup R1 simgesinin üstüne yazılıyordu). Windows ve Android aynı.
    static func isPlaceName(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        guard (1...3).contains(words.count), !TextStyleSampler.isUpper(text),
              words.allSatisfy({ $0.allSatisfy { $0.isLetter || "'’-.".contains($0) } && $0.contains(where: \.isLetter) }),
              words.dropFirst().allSatisfy({ $0.first?.isUppercase == true }) else { return false }
        return words.count >= 2 && (placeWords.contains(words.last!) || placeWords.contains(words.first!))
    }

    /// Ürün/marka adı ("HARBOR LAGER", "Glacier Water", "VANILLA SHAKE"): iki-üç sözcük, yalnız harf, her sözcük büyük
    /// harfle başlar, son sözcük ürün türü (içecek, atıştırmalık), hiçbiri eylem ya da bağlaç/edat değil ("DRINK WATER",
    /// "GLASS OF WATER" ad değildir). Çevrilmez; etkileşim listesinde de olduğu gibi kalır (Sinan Bey beta.101: listede
    /// marka yarım çevriliyor, kimi satır çevrilmiyordu; liste tutarsızdı). Windows ve Android aynı.
    static func isProductName(_ text: String) -> Bool {
        var body = text
        if let last = body.last, "!?".contains(last) { body.removeLast() }
        let words = body.split(separator: " ").map(String.init)
        guard (2...3).contains(words.count),
              words.allSatisfy({ word in
                  word.contains(where: \.isLetter) && word.allSatisfy { $0.isLetter || "'’-&".contains($0) }
                      && word.first(where: \.isLetter)?.isUppercase == true
              }) else { return false }
        let upper = words.map { $0.uppercased(with: Locale(identifier: "en_US_POSIX")) }
        return productWords.contains(upper.last!) && !upper.contains(where: { productStops.contains($0) })
    }

    private static let productWords: Set<String> = ["BEER", "LAGER", "ALE", "STOUT", "CIDER", "WINE", "VODKA", "WHISKEY", "WHISKY", "RUM", "GIN", "TEQUILA", "BOURBON", "WATER", "SODA", "COLA", "POP", "JUICE", "LEMONADE", "SHAKE", "SMOOTHIE", "MILK", "COFFEE", "TEA", "CHIPS", "CRISPS", "CEREAL"]

    /// Ürün adında geçmeyen sözcükler: eylemler ve bağlaç/edat/belirteçler.
    private static let productStops: Set<String> = ["DRINK", "TAKE", "EAT", "OPEN", "CLOSE", "BUY", "SELL", "GRAB", "USE", "PICK", "GET", "PUT", "DROP", "GIVE", "POUR", "SIP", "CHUG", "ORDER", "MAKE", "COOK", "CHECK", "LOOK", "INSPECT", "EXAMINE", "STEAL", "THROW", "SHARE", "OFFER", "FILL", "A", "AN", "THE", "OF", "SOME", "MORE", "NO", "AND", "OR", "WITH", "TO", "FOR", "YOUR", "MY", "ANY"]

    private static let placeWords: Set<String> = ["Bay", "Key", "Keys", "Island", "Islands", "Beach", "Harbor", "Harbour", "Lake", "River", "Creek", "Cove", "Reef", "Springs", "Heights", "Hills", "Park", "Marina", "Inlet", "Lagoon", "Everglades", "Glades", "Shores", "Shore"]

    private static let iconBrackets = CharacterSet(charactersIn: " ()[]")

    /// Satırın başındaki ya da sonundaki kumanda simgesi (kareden tanınmış simge ya da okunmuş tuş adı: "RECENTER L3",
    /// "EXIT (○)") çeviriye girmez; kutu yalnız yazının sözcüklerini kapsar, simge ekranda görünür kalır. Önceden çeviri
    /// kutusu simgenin üstünü örtüyordu ("Ortala" L3'ü kapatıyordu, #860). Sözcük yerleri bilinmiyorsa harf sayısına göre
    /// kestirilir. Geriye tuş adı olmayan iki harfli bir sözcük kalmayacaksa (yalnız tuştan oluşan satır) dokunulmaz.
    public static func withoutEdgeIcons(_ line: TextLine) -> TextLine {
        guard let box = line.box else { return line }
        let original = line.text.trimmingCharacters(in: .whitespaces)
        var text = original
        var icons = line.icons ?? []
        guard text.filter({ $0 == ButtonIcons.marker }).count == icons.count else { return line }
        var left = box.left, right = box.right
        // Kareden tanınmış simgeler (yazıda imle).
        while let icon = icons.last, text.trimmingCharacters(in: iconBrackets).last == ButtonIcons.marker {
            text = String(text.trimmingCharacters(in: iconBrackets).dropLast()).trimmingCharacters(in: iconBrackets)
            icons.removeLast()
            right = min(right, icon.box.left)
        }
        while let icon = icons.first, text.trimmingCharacters(in: iconBrackets).first == ButtonIcons.marker {
            text = String(text.trimmingCharacters(in: iconBrackets).dropFirst()).trimmingCharacters(in: iconBrackets)
            icons.removeFirst()
            left = max(left, icon.box.right)
        }
        var words = line.words
        if text == original {
            // Okunmuş tuş adı ("L3", "(R3)").
            guard !text.contains(ButtonIcons.marker) else { return line }
            let measured = !(line.words ?? []).isEmpty && line.words!.map(\.text).joined(separator: " ") == text
            var list = measured ? line.words! : ButtonIcons.estimate(text, box)
            while list.count > 1, ButtonIcons.isButtonName(list[list.count - 1].text) {
                right = min(right, list.removeLast().box.left)
            }
            while list.count > 1, ButtonIcons.isButtonName(list[0].text) {
                left = max(left, list.removeFirst().box.right)
            }
            text = list.map(\.text).joined(separator: " ")
            words = measured ? list : nil
        } else {
            words = line.words?.filter { $0.box.left >= left - 1e-6 && $0.box.right <= right + 1e-6 }
        }
        guard text != original, right > left,
              text.split(whereSeparator: \.isWhitespace).contains(where: { word in
                  word.filter(\.isLetter).count >= 2 && !ButtonIcons.isButtonName(String(word)) }) else { return line }
        var trimmed = line
        trimmed.text = text
        trimmed.icons = icons.isEmpty ? nil : icons
        trimmed.words = (words ?? []).isEmpty ? nil : words
        trimmed.box = TextBox(left: left, top: box.top, right: right, bottom: box.bottom)
        return trimmed
    }

    /// Satırın ve sözcüklerinin fiyat düzeltmesi (uzunluk değişmez).
    static func repaired(_ line: TextLine) -> TextLine {
        var fixed = line
        fixed.text = PriceText.repair(line.text)
        fixed.words = line.words?.map { TextWord(PriceText.repair($0.text), box: $0.box) }
        return fixed
    }

    /// Tuş çubuğunun etiketleri: tuş adları ve simgeleri ("R1", "△", okunmuş "X"/"O"), fiyatlar ("$10") ve harfsiz
    /// parçalar ayırıcıdır, çeviriye girmez; aralarındaki her sözcük öbeği ayrı satır olur, kutusu sözcüklerinin yeri.
    /// Sözcük yerleri biliniyorsa geniş boşluk da ayırır ("TIP $10   ORDER   BARTENDER"). İki harfi olmayan öbek atılır.
    static func promptPieces(_ line: TextLine) -> [TextLine] {
        guard let box = line.box else { return [line] }
        let measured = !(line.words ?? []).isEmpty
        let words = measured ? line.words! : ButtonIcons.estimate(line.text, box)
        let gap = measured ? wideGap(words) : .infinity
        var runs: [[TextWord]] = [[]]
        for word in words {
            if isPromptSeparator(word.text) {
                runs.append([])
                continue
            }
            if let last = runs[runs.count - 1].last, word.box.left - last.box.right > gap { runs.append([]) }
            runs[runs.count - 1].append(word)
        }
        return runs.filter { run in run.reduce(0) { $0 + $1.text.filter(\.isLetter).count } >= 2 }.map { run in
            let span = run.dropFirst().reduce(run[0].box) { $0.union($1.box) }
            return TextLine(run.map(\.text).joined(separator: " "),
                            box: TextBox(left: span.left, top: box.top, right: span.right, bottom: box.bottom),
                            confidence: line.confidence, words: run)
        }
    }

    /// Sözcüklerin arasında bu kadar boşluk (harf başına ortalama genişliğin üç katı) ayrı seçenek demektir.
    private static func wideGap(_ words: [TextWord]) -> Double {
        let chars = words.reduce(0) { $0 + $1.text.count }
        guard chars > 0 else { return .infinity }
        return words.reduce(0.0) { $0 + ($1.box.right - $1.box.left) } / Double(chars) * 3
    }

    /// Sözcük yerleri bilinen satırda aynı satıra düşmüş ayrı seçenekler var mı (geniş boşluk).
    static func hasWideGap(_ line: TextLine) -> Bool {
        guard let words = line.words, words.count >= 2 else { return false }
        let gap = wideGap(words)
        return zip(words, words.dropFirst()).contains { $1.box.left - $0.box.right > gap }
    }

    /// Tuş çubuğunda çeviriye girmeyen parça: tuş adı/simgesi, tek harf (okunmuş simge), fiyat ya da harfsiz parça.
    static func isPromptSeparator(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>"))
        // "&" sekme adının parçasıdır ("JASON & LUCIA"), ayırıcı değil.
        return ButtonIcons.isButtonName(core) || PriceText.isMoney(core) || (!core.contains(where: \.isLetter) && core != "&")
            || (core.count == 1 && core != "a")
    }

    /// Kutuları bilinen, süzülmüş ve sıralı satırları yeniden işaretlemeden gruplar.
    static func groups(from lines: [TextLine]) -> [Group] {
        var groups: [[TextLine]] = []
        for line in lines {
            if let index = groups.lastIndex(where: { belongs(line.box!, below: $0.last!.box!) }),
               !bridgesColumns(groups[index].last!.box!, line.box!, lines),
               !bridgesColumns(line.box!, groups[index].last!.box!, lines) {
                groups[index].append(line)
            } else if let index = groups.lastIndex(where: { continues(line, above: $0.last!) }) {
                // Küçük harfle başlayan satır, üstündeki bitmemiş cümlenin devamıdır: satır aralığı biraz geniş ya da
                // yanında başka bir yazı olsa da o gruba katılır. Ayrı grup olunca yarım cümle tek başına çevriliyor ya da
                // grup sınırına takılıp hiç çevrilmiyordu; bilgi kutusunun son satırı İngilizce kalıyordu.
                groups[index].append(line)
            } else {
                groups.append([line])
            }
        }
        return busiest(groups).map { group in
            let heights = group.map { $0.box!.bottom - $0.box!.top }.sorted()
            let box = group.dropFirst().reduce(group[0].box!) { $0.union($1.box!) }
            let icons = paragraphIcons(group)
            var made = Group(paragraphs: paragraphs(group), box: box, lineHeight: heights[heights.count / 2],
                             icons: icons.contains(where: { !$0.isEmpty }) ? icons : nil)
            made.rows = rows(group)
            return made
        }
    }

    /// Satırların kaç ayrı satır olduğu: yazı tanıma aynı satırı iki parça okuyabilir (yan yana duran parçalar tek satırdır).
    static func rows(_ lines: [TextLine]) -> Int {
        var tops: [TextBox] = []
        for box in lines.compactMap(\.box) where !tops.contains(where: { other in
            min(other.bottom, box.bottom) - max(other.top, box.top) >= 0.5 * min(other.bottom - other.top, box.bottom - box.top)
        }) { tops.append(box) }
        return max(1, tops.count)
    }

    /// Kalabalık ekranda en çok yazısı olan `maxGroups` grup, yukarıdan aşağı sırasıyla. Önceden en üstteki gruplar
    /// alınıyordu: menü ve gösterge etiketleri sınırı doldurunca ekranın alt yarısındaki bilgi kutusu hiç çevrilmiyordu.
    private static func busiest(_ groups: [[TextLine]]) -> [[TextLine]] {
        guard groups.count > maxGroups else { return groups }
        let letters = groups.map { group in group.reduce(0) { $0 + $1.text.filter(\.isLetter).count } }
        let kept = groups.indices.sorted { letters[$0] != letters[$1] ? letters[$0] > letters[$1] : $0 < $1 }.prefix(maxGroups)
        return kept.sorted().map { groups[$0] }
    }

    /// Alt satır, üstteki satırın bitmemiş cümlesini sürdürüyor: küçük harfle başlıyor, üstteki cümle sonu işaretiyle
    /// bitmiyor, yazı boyu benzer, yatayda üst üste ve arada satır yüksekliğinin bir buçuk katından az boşluk var.
    private static func continues(_ lower: TextLine, above upper: TextLine) -> Bool {
        guard let first = lower.text.first(where: \.isLetter), first.isLowercase,
              !SubtitleStabilizer.endsSentence(upper.text.trimmingCharacters(in: .whitespaces)),
              let below = lower.box, let above = upper.box else { return false }
        let a = above.bottom - above.top, b = below.bottom - below.top
        guard max(a, b) <= min(a, b) * 1.6 else { return false }
        guard below.top - above.bottom < max(a, b) * 1.5, below.top >= above.top else { return false }
        let overlap = min(below.right, above.right) - max(below.left, above.left)
        let narrower = min(below.right - below.left, above.right - above.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    // Geniş başlık/alt satır iki bağımsız sütundan birine katılmasın. Filtrelenmiş OCR satırlarına bakılır.
    private static func bridgesColumns(_ wide: TextBox, _ column: TextBox, _ lines: [TextLine]) -> Bool {
        lines.contains { line in
            let peer = line.box!
            guard min(column.right, peer.right) <= max(column.left, peer.left) else { return false }
            let rowOverlap = min(column.bottom, peer.bottom) - max(column.top, peer.top)
            guard rowOverlap > 0, rowOverlap >= min(column.bottom - column.top, peer.bottom - peer.top) * 0.5 else { return false }
            return (belongs(column, below: wide) && belongs(peer, below: wide))
                || (belongs(wide, below: column) && belongs(wide, below: peer))
        }
    }

    /// Alt satır üsttekinin hemen altında (arada satır yüksekliğinin %80'inden az), yatayda onunla üst üste ve yazı boyu benzer.
    private static func belongs(_ lower: TextBox, below upper: TextBox) -> Bool {
        let a = upper.bottom - upper.top, b = lower.bottom - lower.top
        guard max(a, b) <= min(a, b) * 1.6 else { return false }
        guard lower.top - upper.bottom < max(a, b) * 0.8, lower.top >= upper.top else { return false }
        let overlap = min(lower.right, upper.right) - max(lower.left, upper.left)
        let narrower = min(lower.right - lower.left, upper.right - upper.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    /// Önceki parça cümleyi bitirdiyse ya da kısa bir başlık/menü satırıysa (en çok üç sözcük, virgülsüz) ve yeni satır
    /// büyük harfle başlıyorsa yeni parça başlar; yoksa satır öncekinin devamıdır (cümle iki satıra sarılmış).
    static func paragraphs(_ lines: [TextLine]) -> [String] {
        var result: [String] = []
        for line in lines.map({ $0.text.trimmingCharacters(in: .whitespaces) }) {
            if let previous = result.last, !startsNew(after: previous, line) {
                result[result.count - 1] += " " + line
            } else {
                result.append(line)
            }
        }
        return result
    }

    /// `paragraphs` ile aynı bölmede her parçanın kumanda simgeleri, metindeki sırasıyla.
    static func paragraphIcons(_ lines: [TextLine]) -> [[IconSlot]] {
        var texts: [String] = []
        var result: [[IconSlot]] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let icons = line.icons ?? []
            if let previous = texts.last, !startsNew(after: previous, text) {
                texts[texts.count - 1] += " " + text
                result[result.count - 1] += icons
            } else {
                texts.append(text)
                result.append(icons)
            }
        }
        return result
    }

    private static func startsNew(after previous: String, _ line: String) -> Bool {
        if SubtitleStabilizer.endsSentence(previous) { return true }
        return line.first?.isUppercase == true && wordCount(previous) <= 3 && !previous.hasSuffix(",")
    }

    /// En az iki harfi ve iki harfli bir sözcüğü olan satır yazıdır; geri kalanı sayı ve simgedir. Yalnız uzaklık
    /// ("124 ft", "2.4 mi", "300 m") da göstergedir: haritada kartın yanındaki uzaklık çevrilip kutuyla örtülüyordu.
    static func isWords(_ text: String) -> Bool {
        text.filter(\.isLetter).count >= 2 && text.split(whereSeparator: \.isWhitespace).contains { $0.filter(\.isLetter).count >= 2 }
            && !isDistance(text)
    }

    /// Yalnız sayı ve uzaklık birimi: "124 ft", "4 ft", "2.4 mi", "300m", "1,2 km", "50 yd".
    static func isDistance(_ text: String) -> Bool {
        text.range(of: #"^\s*\d[\d.,]*\s?(ft|m|mi|km|yd|yds)\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// Çevirilerin TV'de kalma süresi (ms): yazı çoksa daha uzun; tuşa yeniden basınca hemen kalkar.
    public static func displayMilliseconds(_ items: [Item]) -> Int {
        min(60000, max(12000, 8000 + items.reduce(0) { $0 + $1.translation.count } * 50))
    }
}
