// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Ekran yazılarını kendiliğinden bulur (görev, yardım kutusu, mesaj; oyundan bağımsız, sabit bölge yok). Kare 32x18
/// karoya bölünür, her karodan 24x24 nokta örneği alınır: koyu ya da yarı saydam zeminde açık renk yazı taşıyan ve en az
/// 300 ms durgun kalan karolar birleşip geçici ek alan olur (`ExtraArea.auto`). OCR, paket ve canlı çeviri, yerinde
/// gösterme ve boşalınca kaldırma `RegionWatcher`'dadır. Okunup yazı bulunmayan ya da gürültü çıkan alan (harita, para,
/// saat) `reject` ile bildirilir; karoları görüntü değişmedikçe yeniden önerilmez. Windows (ScreenTextDetector.cs) ve
/// Android (ScreenTextDetector.kt) aynı kuralları ve eşikleri uygular. İş parçacığı güvenlidir: örnek arka planda alınır.
public final class ScreenTextDetector: @unchecked Sendable {
    public static let columns = 32
    public static let rows = 18
    /// Karo başına bir kenardaki örnek sayısı (24x24 = 576 nokta; ince açık yazılı sol sütunlar 12x12'de kaçıyordu).
    public static let samples = 24
    /// İki örnek arasında en az bu kadar süre geçer (en çok 10 Hz).
    public static let sampleIntervalMs = 100
    /// Karo bu kadar süre durgun kalınca aday olur.
    public static let stableMs = 300
    /// Alanın hiçbir karosu bu kadar süre aday olmazsa alan çıkar.
    public static let expireMs = 700
    /// En çok bu kadar otomatik alan.
    public static let maxAreas = 4
    /// Menü durumunda en çok bu kadar otomatik alan (tekerlek menünün etiketleri, başlık, alt başlık).
    public static let menuMaxAreas = 12
    /// Menü durumu için en az bu kadar ayrı bileşen birlikte belirmeli.
    public static let menuComponents = 3
    /// Menünün bileşenleri en çok bu kadar arayla belirmiş olmalı.
    public static let menuTogetherMs = 300
    /// Bileşen dışındaki karoların en az bu kadarı düşük kenar enerjili (bulanık/karartılmış zemin) olmalı.
    public static let menuQuietShare = 0.6
    /// Karo içi parlaklık sapması bundan küçükse karo düşük kenar enerjilidir.
    public static let quietDeviation = 18.0
    public static let areaName = "Screen text"

    private static let bright = 160
    private static let dark = 100
    /// Maskenin değişmiş sayılması için en az bu kadar nokta farklı olmalı (576 noktada; 144 noktadaki 6'nın orantılısı).
    private static let maskChange = 24
    private static let maxShare = 0.35
    private static let keepOverlap = 0.30

    /// 144 bitlik karo maskesi (parlaklığı `bright` ve üstü olan noktalar).
    struct Mask: Equatable {
        var words = [UInt64](repeating: 0, count: (ScreenTextDetector.samples * ScreenTextDetector.samples + 63) / 64)
        func distance(_ other: Mask) -> Int {
            zip(words, other.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        }
    }

    private struct Tile {
        var last = Mask()
        var hasLast = false
        var stableSince = 0
        var rejected = Mask()
        var isRejected = false
        /// Karo okununca tuş ipucu ya da görev/HUD yazısı çıktı (`markHud`): menü için sayılmaz.
        var isHud = false
        var quiet = false
        // Zemin (koyu) örneklerinin toplamları: panel zemini kanıtı için.
        var darkSum = 0, darkSquares = 0, darkCount = 0
    }

    /// Karo dikdörtgeni (sütun/satır, iki uç dahil).
    struct Cells: Equatable {
        var left: Int, top: Int, right: Int, bottom: Int
        var area: Int { (right - left + 1) * (bottom - top + 1) }
        func overlap(_ other: Cells) -> Double {
            let w = min(right, other.right) - max(left, other.left) + 1
            let h = min(bottom, other.bottom) - max(top, other.top) + 1
            return w <= 0 || h <= 0 ? 0 : Double(w * h) / Double(min(area, other.area))
        }
    }

    private final class Tracked {
        let id: String
        var cells: Cells
        var tiles: [Int]
        var seen: Int
        var menu = false
        init(id: String, cells: Cells, tiles: [Int], seen: Int) {
            self.id = id
            self.cells = cells
            self.tiles = tiles
            self.seen = seen
        }
    }

    private let lock = NSLock()
    private var tiles = [Tile](repeating: Tile(), count: columns * rows)
    private var tracked: [Tracked] = []
    private var lastSample: Int?
    private var counter = 0
    private var menu = false
    /// Menüye girildiği örnekteki bileşenlerin karoları: menü bunlar yerinde durdukça sürer (`isMenu`).
    private var menuAnchors = Set<Int>()
    /// Menüye girilen an ve süresi dolan menünün bittiği an (bundan önce belirmiş yazılar yeniden menü sayılmaz).
    private var menuEnteredAt = 0
    private var menuFloor: Int?
    /// Menü durumu bu örnekte `menuLifeMs` dolduğu için bitti: menüde bulunan bütün alanlar kalkar (#1198).
    private var menuExpired = false

    public init() {}

    /// Son örnekte ekranda menü vardı (bulanık zeminde birlikte beliren en az üç yazı).
    public var inMenu: Bool { lock.withLock { menu } }

    /// Menü durumu değişince altyazı günlüğüne yazılan satır (`MenuHeldSender` yazar; menüdeyken altyazı okunur ama
    /// bekletilir). Günlükte görünmeyince "altyazı hattı hiç satır üretmiyor" nedensiz kalıyordu. Android ve Windows
    /// (MenuPausedSender) aynı metni yazar.
    public static func menuLog(_ inMenu: Bool) -> String {
        inMenu ? "ekran menüsü açık: altyazı bekletiliyor" : "ekran menüsü kapandı: altyazı gösteriliyor"
    }

    /// Şu an önerilen otomatik alanlar.
    public var areas: [ExtraArea] { lock.withLock { current() } }

    /// Örnek zamanı geldi mi (son örnekten en az `sampleIntervalMs` geçti).
    public func due(_ now: Int) -> Bool {
        lock.withLock { lastSample.map { now - $0 >= Self.sampleIntervalMs } ?? true }
    }

    /// Kareyi örnekler ve alanları günceller. `excluded`: altyazı alanı ve kullanıcının etkin ek alanları (merkezi
    /// bunların içinde kalan karo aday olmaz). Alan listesi değiştiyse true.
    @discardableResult
    public func sample(_ frame: CGImage, now: Int, excluded: [CropRegion]) -> Bool {
        guard due(now) else { return false }
        // Nokta örnekleri: kare, her karoya 24x24 piksel düşecek boya (768x432) ara değerlemesiz küçültülür.
        guard let pixels = GamePhonePixels(frame, width: Self.columns * Self.samples, height: Self.rows * Self.samples)
        else { return false }
        let measured = Self.measure(pixels)
        return lock.withLock {
            if let last = lastSample, now - last < Self.sampleIntervalMs { return false }
            lastSample = now
            let before = current()
            var candidate = [Bool](repeating: false, count: tiles.count)
            for row in 0..<Self.rows {
                for column in 0..<Self.columns {
                    let index = row * Self.columns + column
                    let (mask, bright, dark, deviation, darkSum, darkSquares) = measured[index]
                    var tile = tiles[index]
                    tile.quiet = deviation < Self.quietDeviation
                    (tile.darkSum, tile.darkSquares, tile.darkCount) = (darkSum, darkSquares, dark)
                    if !tile.hasLast || tile.last.distance(mask) > Self.maskChange { tile.stableSince = now; tile.isHud = false }
                    tile.last = mask
                    tile.hasLast = true
                    if tile.isRejected && tile.rejected.distance(mask) > Self.maskChange { tile.isRejected = false }
                    tiles[index] = tile
                    // Koyu/yarı saydam zeminde açık yazı (576 noktada: 24..288 parlak, en az 144 koyu).
                    // Menüde açık zeminde koyu yazı da (seçili menü satırı: açık degrade şerit, koyu "Map"; #1267). Seçili
                    // satır aday olmuyor, alan onu dışarıda bırakıyordu: "Map" seçim kayana dek çevrilmiyordu. Menü dışında
                    // açık sahne (gökyüzü, kar) yazı sanılmasın diye yalnız menüde.
                    // Menüde kontur yazı da (#1268): GTA 6 haritasının tuş listesi ("2D VIEW", "ADD MARKER") ve görev satırı
                    // doğrudan açık, desenli haritanın üstünde beyaz harf + koyu kontur; yarı saydam kartın haritaya binen
                    // yarısı da yalnız orta tonda. Karoda ne yeterince koyu zemin ne açık zemin var; tuş listesinden yalnız
                    // hazır alana düşen "RECENTER" çevriliyor, kartın yazısı kartın ortasında kesiliyordu (kesik okuma).
                    let textLike = ((24...288).contains(bright) && dark >= 144)
                        || (menu && (24...288).contains(dark) && bright >= 144)
                        || (menu && Self.outlined(bright: bright, dark: dark))
                    candidate[index] = textLike && now - tile.stableSince >= Self.stableMs && !tile.isRejected
                        // Menü durumunda altyazı alanı dışlanmaz (menü satırları orada da olabilir).
                        && (menu || !Self.excluded(column, row, excluded))
                }
            }
            let all = Self.components(candidate)
            let inMenu = isMenu(all, now: now)
            // Menü dışında tek karoluk bileşen (kısa etiket, simge) alan olmaz.
            // Menü dışında yalnız arayüz kanıtı olan bileşen alan olur: düz panel zemini ve yerinde sabitlik. Oyun dünyasındaki
            // yazı (poster, plaka, tabela) dokulu zeminde ya da kamerayla kayarak durur, çevrilmez (Windows ile aynı).
            let components = inMenu ? Self.menuColumns(all) : all.filter { $0.tiles.count >= 2 && isInterface($0.cells, $0.tiles, now: now) }
            let ranked = components.enumerated()
                .sorted { ($0.element.tiles.count, -$0.offset) > ($1.element.tiles.count, -$1.offset) }
                .map(\.element).prefix(inMenu ? Self.menuMaxAreas : Self.maxAreas)
            update(Array(ranked), candidate: candidate, now: now, inMenu: inMenu)
            return before != current()
        }
    }

    /// Alan okundu ama yazı bulunmadı ya da gürültüydü: karoları bu görüntüde reddedilir (görüntü belirgin değişene dek
    /// yeniden önerilmez) ve alan çıkar.
    public func reject(_ id: String) {
        lock.withLock {
            guard let index = tracked.firstIndex(where: { $0.id == id }) else { return }
            for tile in tracked[index].tiles {
                tiles[tile].rejected = tiles[tile].last
                tiles[tile].isRejected = true
            }
            tracked.remove(at: index)
        }
    }

    /// Alan okundu ve yazısı tuş ipucu ya da görev/HUD yazısı (`RegionWatcher.onAutoHud`): karoları menü için gereken
    /// `menuComponents` bileşene sayılmaz (görüntü değişene dek). GTA 6 balık tutma sahnesinde (#1240) ipucu ve görev yazısı
    /// birlikte belirip menü sanılıyordu; alan çevrilmeye devam eder (Windows ve Android ile aynı).
    public func markHud(_ id: String) {
        lock.withLock {
            guard let area = tracked.first(where: { $0.id == id }) else { return }
            for tile in area.tiles { tiles[tile].isHud = true }
        }
    }

    /// Konuşma satırı okunduktan sonra bu kadar süre menü durumu açılmaz.
    public static let dialogueMs = 1500
    private var dialogueAt: Int?

    /// Altyazı alanında konuşma satırı (konuşan adıyla) okundu: ekranda menü yoktur. Menü durumu hemen biter (menü alanları
    /// kalkar) ve `dialogueMs` boyunca yeniden açılmaz (#1240). Gerçek menüde (duraklatma, ayarlar, harita) altyazı alanında
    /// konuşma satırı olmaz.
    public func noteDialogue(now: Int) {
        lock.withLock {
            // Menünün geçmiş listesi az önce okundu: konuşan adlı satır listenin satırıdır (kaydırılırken tek satır okunabilir).
            if let listed = listAt, now - listed <= Self.listMs { return }
            dialogueAt = now
            guard menu else { return }
            menu = false
            menuFloor = now
            menuAnchors = []
            tracked.removeAll { $0.menu }
        }
    }

    /// Menü listesi okunduktan sonra bu kadar süre konuşan adlı satır menüyü bitirmez, menü de süresi dolmuş sayılmaz.
    public static let listMs = 1500
    private var listAt: Int?

    /// Altyazı alanında menünün geçmiş listesi okundu (`Reading.isHistoryList`, Sinan Bey beta.100 3380-3383): ekranda menü
    /// vardır. Menü durumu liste durdukça sürer (`menuLifeMs` dolmaz; listeye bakarken menü bitip satırlar dünya yazısı
    /// sayılıyor, kimi satır çevrilmiyordu) ve `listMs` boyunca konuşan adlı satır (`noteDialogue`) menüyü bitirmez.
    public func noteList(now: Int) {
        lock.withLock { listAt = now }
    }

    /// Çeviri durdu ya da oturum sıfırlandı: alanlar ve karo durumu silinir.
    public func reset() {
        lock.withLock {
            listAt = nil
            tiles = [Tile](repeating: Tile(), count: tiles.count)
            tracked.removeAll()
            lastSample = nil
            menu = false
            menuAnchors = []
            menuFloor = nil
            menuExpired = false
            dialogueAt = nil
        }
    }

    private static func measure(_ pixels: GamePhonePixels) -> [(Mask, Int, Int, Double, Int, Int)] {
        var result = [(Mask, Int, Int, Double, Int, Int)](repeating: (Mask(), 0, 0, 0, 0, 0), count: columns * rows)
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<rows {
                for column in 0..<columns {
                    var mask = Mask()
                    var bright = 0, dark = 0, bit = 0, sum = 0, squares = 0, darkSum = 0, darkSquares = 0
                    for sy in 0..<samples {
                        let line = (row * samples + sy) * pixels.width * 4
                        for sx in 0..<samples {
                            let p = line + (column * samples + sx) * 4
                            let luma = (299 * Int(bytes[p]) + 587 * Int(bytes[p + 1]) + 114 * Int(bytes[p + 2])) / 1000
                            sum += luma
                            squares += luma * luma
                            if luma >= Self.bright {
                                bright += 1
                                mask.words[bit / 64] |= 1 << UInt64(bit % 64)
                            } else if luma <= Self.dark {
                                dark += 1
                                darkSum += luma
                                darkSquares += luma * luma
                            }
                            bit += 1
                        }
                    }
                    let count = Double(samples * samples)
                    let mean = Double(sum) / count
                    let deviation = max(0, Double(squares) / count - mean * mean).squareRoot()
                    result[row * columns + column] = (mask, bright, dark, deviation, darkSum, darkSquares)
                }
            }
        }
        return result
    }

    /// Kontur yazı karosu (576 noktada): açık harf noktaları ve koyu kontur noktaları ikisi de `outlineMin`..288; geri
    /// kalanı orta ton (açık harita, yarı saydam kartın haritaya binen yanı). Yalnız menüde (açık sahne yazı sanılmasın).
    static let outlineMin = 24
    static func outlined(bright: Int, dark: Int) -> Bool {
        (outlineMin...288).contains(bright) && (outlineMin...288).contains(dark)
    }

    private static func excluded(_ column: Int, _ row: Int, _ regions: [CropRegion]) -> Bool {
        let x = (Double(column) + 0.5) / Double(columns)
        let y = (Double(row) + 0.5) / Double(rows)
        return regions.contains { x >= $0.left && x <= $0.right && y >= $0.top && y <= $0.bottom }
    }

    /// Aday karoların bileşenleri: 4-komşuluk ve aynı satırda en çok bir boş karo aralık.
    static func components(_ candidate: [Bool]) -> [(cells: Cells, tiles: [Int])] {
        var parent = Array(candidate.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func join(_ i: Int, _ j: Int) { parent[find(i)] = find(j) }
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard candidate[index] else { continue }
                if column + 1 < columns && candidate[index + 1] { join(index, index + 1) }
                else if column + 2 < columns && candidate[index + 2] { join(index, index + 2) }
                if row + 1 < rows && candidate[index + columns] { join(index, index + columns) }
            }
        }
        var groups: [Int: [Int]] = [:]
        var order: [Int] = []
        for i in candidate.indices where candidate[i] {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(i)
        }
        var result: [(cells: Cells, tiles: [Int])] = []
        for root in order {
            let list = groups[root]!
            let cells = Cells(left: list.map { $0 % columns }.min()!, top: list.map { $0 / columns }.min()!,
                              right: list.map { $0 % columns }.max()!, bottom: list.map { $0 / columns }.max()!)
            // Ekranın büyük bölümünü kaplayan bileşen yazı kutusu değil, sahne dokusudur.
            if Double(cells.area) > maxShare * Double(columns * rows) { continue }
            result.append((cells, list))
        }
        return merged(result)
    }

    /// Bölgeleri kesişen bileşenler birleşir: aynı yazı iki alanda yarım yarım okunmasın (gerçek karede tuş çubuğu iki
    /// alana bölünüp ikisi de kesik okunuyor, kutular sırayla gidip geliyordu). Bölge yatayda bir, dikeyde yarım karo
    /// genişlediği için yatayda iki, dikeyde bir boş karoya kadar aralıklı bileşenler kesişir. Birleşen sahne dokusu
    /// kadar büyürse birleşmez.
    /// Aynı karo satırındaki bileşenler arasında en çok bu kadar sütun (iki uç arası) olunca birleşir; ikisi de en az iki
    /// karo genişse (sekme öbekleri) `wideRowReach`. Tek karoluk etiketler (tekerlek menü) arası dar kalır.
    static let rowReach = 3
    static let wideRowReach = 4

    static func merged(_ components: [(cells: Cells, tiles: [Int])]) -> [(cells: Cells, tiles: [Int])] {
        var result = components
        var changed = true
        while changed {
            changed = false
            outer: for i in result.indices {
                for j in result.indices where j > i {
                    let a = result[i].cells, b = result[j].cells
                    // Aynı satırdaki bileşenler (menü şeridinin sekmeleri) iki (sekme öbekleri arasında üç) boş karoya kadar birleşir: seçili sekme renkli
                    // olduğu için aday olmuyor, iki yanındaki alanlar onu ortadan kesiyordu ("MAP" → "M", #859).
                    let sameRow = a.top <= b.bottom && b.top <= a.bottom
                    let wide = a.right - a.left >= 1 && b.right - b.left >= 1
                    let reach = sameRow ? (wide ? Self.wideRowReach : Self.rowReach) : 2
                    guard a.left <= b.right + reach, b.left <= a.right + reach, a.top <= b.bottom + 1, b.top <= a.bottom + 1
                    else { continue }
                    let union = Cells(left: min(a.left, b.left), top: min(a.top, b.top),
                                      right: max(a.right, b.right), bottom: max(a.bottom, b.bottom))
                    guard Double(union.area) <= maxShare * Double(columns * rows) else { continue }
                    result[i] = (union, result[i].tiles + result[j].tiles)
                    result.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return result
    }

    /// Menüde aynı sütunda (sol kenarları en çok `columnSlack` karo farklı; iki tek satırlık bileşende aynı karo) alt alta duran bileşenler arada bir boş karo
    /// satırı olsa da birleşir: dikey menünün satırları tek alanda okunur, Türkçeleri tek grupta aynı yana yazılır. Satır
    /// aralığı karo boyuna denk gelince bir satır ("Settings") ayrı alana düşüp kendi başına yerleşiyordu (#1339).
    static let columnSlack = 1

    static func menuColumns(_ components: [(cells: Cells, tiles: [Int])]) -> [(cells: Cells, tiles: [Int])] {
        var result = components
        var changed = true
        while changed {
            changed = false
            outer: for i in result.indices {
                for j in result.indices where j > i {
                    let a = result[i].cells, b = result[j].cells
                    // Tek satırlık iki bileşende (ortalı başlık ve alt başlığı) sol kenar aynı karoda olmalı.
                    let slack = a.bottom > a.top || b.bottom > b.top ? columnSlack : 0
                    guard abs(a.left - b.left) <= slack, a.top <= b.bottom + 2, b.top <= a.bottom + 2 else { continue }
                    let union = Cells(left: min(a.left, b.left), top: min(a.top, b.top),
                                      right: max(a.right, b.right), bottom: max(a.bottom, b.bottom))
                    guard Double(union.area) <= maxShare * Double(columns * rows) else { continue }
                    result[i] = (union, result[i].tiles + result[j].tiles)
                    result.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return result
    }

    /// Menü durumu: en az üç ayrı bileşen var ve bileşenlerin dışındaki karoların çoğu düşük kenar enerjili (bulanık ya
    /// da karartılmış zemin). Menüye ilk girişte bileşenlerin en çok 300 ms arayla birlikte belirmiş olması da gerekir;
    /// menüde gezinirken (seçim çerçevesi değişince) durum, menüye girildiğindeki bileşenlerden biri (karolarının en az
    /// `keepOverlap` kadarı) yerinde durdukça korunur (Android ile aynı: menünün kendi yazılarından biri görünmeli).
    ///
    /// Eskiden menü girişten sonra yalnız "en az üç bileşen ve sakin zemin" ile sürüyordu. GTA 6 "Chapter 1: Gone Fishing"
    /// (gece, karanlık kamp) duraklatma menüsü kapandıktan sonra sahnenin görev yazısı, PS5 bildirimi ve HUD üç bileşen,
    /// karanlık zemin de sakin sayıldı; menü durumu hiç bitmedi. Menüdeyken altyazı okunmadığı için bütün oturumda tek
    /// altyazı çevrilmedi (Mac 04:01–04:05 ve iPhone 1.0.6 04:10–04:14 günlükleri: "ilk yazı" yok, diyalog satırı
    /// altyazı alanı dışlanmadığı için yalnız ekran yazısı olarak okundu).
    /// Arayüz kanıtı: zemin örneklerinin parlaklık sapması en çok bu kadar (düz ya da yarı saydam düz panel).
    public static let groundDeviation = 22.0
    /// Zemin karolarının en az bu kadarı aynı tonda (±`groundTone`).
    public static let groundShare = 0.7
    public static let groundTone = 20.0
    /// Arayüz kanıtı: bileşen en az bu kadar yerinde sabit kalmış olmalı.
    public static let uiStableMs = 600

    /// Bileşen bir arayüz kutusu mu: kutusundaki zemin (koyu) örneklerinin parlaklık sapması en çok `groundDeviation` ve
    /// zemin karolarının en az %70'i aynı tonda (düz ya da yarı saydam düz panel); karoları en az `uiStableMs` yerinde sabit.
    private func isInterface(_ cells: Cells, _ component: [Int], now: Int) -> Bool {
        if component.contains(where: { now - tiles[$0].stableSince < Self.uiStableMs }) { return false }
        var sum = 0, squares = 0, count = 0
        var means: [Double] = []
        let points = Self.samples * Self.samples
        for row in cells.top...cells.bottom {
            for column in cells.left...cells.right {
                let tile = tiles[row * Self.columns + column]
                guard tile.darkCount > 0 else { continue }
                sum += tile.darkSum
                squares += tile.darkSquares
                count += tile.darkCount
                if tile.darkCount >= points / 10 { means.append(Double(tile.darkSum) / Double(tile.darkCount)) }
            }
        }
        guard count > 0, !means.isEmpty else { return false }
        let mean = Double(sum) / Double(count)
        let deviation = max(0, Double(squares) / Double(count) - mean * mean).squareRoot()
        guard deviation <= Self.groundDeviation else { return false }
        let median = means.sorted()[means.count / 2]
        return Double(means.filter { abs($0 - median) <= Self.groundTone }.count) >= Self.groundShare * Double(means.count)
    }

    private func isMenu(_ all: [(cells: Cells, tiles: [Int])], now: Int) -> Bool {
        // Konuşma satırı az önce okundu: menü yok (#1240).
        if let spoken = dialogueAt, now - spoken <= Self.dialogueMs { return false }
        // Tuş ipucu ve görev/HUD yazısı (`markHud`) menü bileşeni sayılmaz; zeminin sakinliğinde yazı karosu olarak kalır.
        let components = all.filter { !$0.tiles.allSatisfy { tiles[$0].isHud } }
        guard components.count >= Self.menuComponents else { return false }
        let inside = Set(all.flatMap(\.tiles))
        let outside = tiles.indices.filter { !inside.contains($0) }
        guard !outside.isEmpty,
              Double(outside.filter { tiles[$0].quiet }.count) >= Self.menuQuietShare * Double(outside.count) else { return false }
        if menu, components.contains(where: { component in
            Double(component.tiles.filter(menuAnchors.contains).count) >= Self.keepOverlap * Double(component.tiles.count)
        }) {
            // Menüde bir şey değişmeden (gezinme, seçim) `menuLifeMs` geçti: menü sayılmaz, altyazı yeniden okunur. Aynı
            // yazılar yeniden menü sayılmaz; menü ancak sonradan beliren yazılarla yeniden açılır (`menuFloor`).
            var activity = menuAnchors.map { tiles[$0].stableSince }.max() ?? menuEnteredAt
            // Menünün geçmiş listesi altyazı alanında okunuyor (`noteList`): menü yerinde, süresi dolmaz.
            if let listed = listAt, now - listed <= Self.listMs { activity = max(activity, listed) }
            if now - max(activity, menuEnteredAt) <= Self.menuLifeMs { return true }
            menuFloor = now
            menuExpired = true
            return false
        }
        let appeared = components.map { $0.tiles.map { tiles[$0].stableSince }.max()! }
        guard appeared.max()! - appeared.min()! <= Self.menuTogetherMs,
              menuFloor.map({ floor in appeared.allSatisfy { $0 > floor } }) ?? true else { return false }
        if !menu { menuEnteredAt = now }
        menuAnchors = Set(components.flatMap(\.tiles))
        return true
    }

    /// Menüde hiçbir yazı değişmeden bu kadar süre geçince menü durumu biter (altyazı okunur). Karanlık sahnede birlikte
    /// beliren sabit HUD yazıları da menü sanılabiliyor; menü durumu altyazıyı en çok bu kadar susturur.
    public static let menuLifeMs = 5000

    private func update(_ components: [(cells: Cells, tiles: [Int])], candidate: [Bool], now: Int, inMenu: Bool) {
        let closed = menu && !inMenu
        menu = inMenu
        // Menü kapandı: menüde bulunan bütün alanlar hemen kalkar (700 ms beklemez).
        // Karoları hâlâ yerinde duran alan (seçim gezinirken menü durumu bir örnek düşse de) kalır; yanıp sönmez.
        // Menü durumu süresi dolduğu için bittiyse karoları yerinde dursa da bütün menü alanları kalkar (RegionWatcher
        // çevirilerini TV'den kaldırır). Eskiden alan tek aday karoyla yaşamaya devam ediyor, menü yazısı oyundan kalksa da
        // çevirisi ekranda kalıyordu (#1198).
        if closed { tracked.removeAll { $0.menu && (menuExpired || !$0.tiles.contains { candidate[$0] }) } }
        menuExpired = false
        var matched = Set<ObjectIdentifier>()
        for (cells, list) in components {
            var existing = tracked.first { !matched.contains(ObjectIdentifier($0)) && $0.cells.overlap(cells) >= Self.keepOverlap }
            if existing == nil {
                guard tracked.count < (inMenu ? Self.menuMaxAreas : Self.maxAreas) else { continue }
                counter += 1
                let made = Tracked(id: "auto-\(counter)", cells: cells, tiles: list, seen: now)
                tracked.append(made)
                existing = made
            }
            guard let area = existing else { continue }
            // Bölge en az bir karo kayınca güncellenir (karo biriminde olduğundan her fark bir karodur).
            area.cells = cells
            area.tiles = list
            area.seen = now
            area.menu = inMenu
            matched.insert(ObjectIdentifier(area))
        }
        // Bileşenlerden birinin içinde kalan eşleşmemiş alan (birleşen menü sütununun eski parçası) ikinci kez okunmaz.
        tracked.removeAll { area in
            !matched.contains(ObjectIdentifier(area)) && components.contains { $0.cells.overlap(area.cells) >= 1 }
        }
        for area in tracked where !matched.contains(ObjectIdentifier(area)) && area.tiles.contains(where: { candidate[$0] }) {
            area.seen = now
        }
        tracked.removeAll { now - $0.seen >= Self.expireMs }
    }

    private func current() -> [ExtraArea] {
        tracked.map {
            var area = ExtraArea(id: $0.id, name: Self.areaName, region: Self.region($0.cells), auto: true)
            area.menu = $0.menu
            return area
        }
    }

    /// Karo dikdörtgeni yatayda her yandan bir karo, dikeyde yarım karo genişletilmiş, 0..1'e kırpılmış bölge.
    static func region(_ cells: Cells) -> CropRegion {
        CropRegion(top: max(0, (Double(cells.top) - 0.5) / Double(rows)),
                   bottom: min(1, (Double(cells.bottom) + 1.5) / Double(rows)),
                   left: max(0, (Double(cells.left) - 1) / Double(columns)),
                   right: min(1, (Double(cells.right) + 2) / Double(columns)))
    }
}

/// Otomatik bulunan alanda okunan yazı çevrilmeye değer mi: sayaç, saat, para, tek sözcüklük etiket ya da büyük harfli
/// kısa tabela gürültüdür (Windows/Android: ScreenTextNoise ile aynı kurallar). Yalnız otomatik alanlarda uygulanır.
public enum ScreenTextNoise {
    /// Yayıncı katmanının sık yazıları (logo, canlı yayın işareti); oyun yazısı değildir.
    private static let overlay: Set<String> = [
        "GAMING", "GAMERS", "REPUBLIC OF", "REPUBLIC OF GAMERS", "ROG", "LIVE", "CANLI", "CANLİ",
    ]
    private static let domain = try! NSRegularExpression(pattern: #"\b[\w-]+\. ?(?:com|net|org|tv|tr|gg|io|live|tk)\b"#,
                                                         options: .caseInsensitive)

    /// Satır yayın katmanının yazısı mı (alan adı "GEN.TR", logo "REPUBLIC OF GAMERS", "• Canlı").
    public static func isOverlay(_ line: String) -> Bool {
        let text = IconText.plain(line).trimmingCharacters(in: CharacterSet(charactersIn: "•·● "))
        let range = NSRange(text.startIndex..., in: text)
        return domain.firstMatch(in: text, range: range) != nil
            || overlay.contains(text.uppercased(with: Locale(identifier: "en_US_POSIX")))
            || overlay.contains(text.uppercased(with: Locale(identifier: "tr_TR")))
    }

    /// Bozuk okuma (otomatik alanda çevrilmez): güveni 0,5'ten düşük ya da harflerinin %30'undan fazlası tuhaf
    /// sözcüklerde (ilk harften sonra karışık büyük/küçük: "MelFaming"; harfle simge karışık: "SBACK)Q,").
    public static func isGarbled(_ line: TextLine) -> Bool {
        if let confidence = line.confidence, confidence < 0.5 { return true }
        let words = IconText.plain(line.text).split(separator: " ")
        let letters = words.reduce(0) { $0 + $1.filter(\.isLetter).count }
        guard letters > 0 else { return false }
        let odd = words.filter { word in
            let body = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?()[]'\u{2019}\"/"))
            let tail = body.dropFirst().filter(\.isLetter)
            let mixedCase = tail.contains(where: \.isUppercase) && tail.contains(where: \.isLowercase)
            let mixedSymbols = body.contains(where: \.isLetter)
                && body.contains(where: { !$0.isLetter && !$0.isNumber && !"-'\u{2019}&".contains($0) })
            return mixedCase || mixedSymbols
        }.reduce(0) { $0 + $1.filter(\.isLetter).count }
        return Double(odd) > 0.3 * Double(letters)
    }

    /// `menu`: menü durumunda (`ExtraArea.menu`) kısa etiketler de çevrilir ("OFF", "ON", "OUTFITS"): yalnız harfsiz
    /// (sayı, simge, noktalama: "40", "100%") ve sayısı ağır basan ("x3") etiketler gürültüdür.
    public static func isNoise(_ text: String, menu: Bool = false) -> Bool {
        let plain = IconText.plain(text)
        let letters = plain.filter(\.isLetter).count
        let digits = plain.filter(\.isNumber).count
        if letters == 0 || digits * 2 > letters { return true }
        if menu { return false }
        if letters < 8 { return true }
        let words = plain.split(whereSeparator: \.isWhitespace).filter { $0.filter(\.isLetter).count >= 2 }.count
        if words < 2 { return true }
        return !plain.contains(where: \.isLowercase) && words < 3
    }
}
