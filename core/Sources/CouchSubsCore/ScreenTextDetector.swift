// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Ekran yazılarını kendiliğinden bulur (görev, yardım kutusu, mesaj; oyundan bağımsız, sabit bölge yok). Kare 32x18
/// karoya bölünür, her karodan 12x12 nokta örneği alınır: koyu ya da yarı saydam zeminde açık renk yazı taşıyan ve en az
/// 300 ms durgun kalan karolar birleşip geçici ek alan olur (`ExtraArea.auto`). OCR, paket ve canlı çeviri, yerinde
/// gösterme ve boşalınca kaldırma `RegionWatcher`'dadır. Okunup yazı bulunmayan ya da gürültü çıkan alan (harita, para,
/// saat) `reject` ile bildirilir; karoları görüntü değişmedikçe yeniden önerilmez. Windows (ScreenTextDetector.cs) ve
/// Android (ScreenTextDetector.kt) aynı kuralları ve eşikleri uygular. İş parçacığı güvenlidir: örnek arka planda alınır.
public final class ScreenTextDetector: @unchecked Sendable {
    public static let columns = 32
    public static let rows = 18
    /// Karo başına bir kenardaki örnek sayısı (12x12 = 144 nokta).
    public static let samples = 12
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
    private static let maskChange = 6
    private static let maxShare = 0.35
    private static let keepOverlap = 0.30

    /// 144 bitlik karo maskesi (parlaklığı `bright` ve üstü olan noktalar).
    struct Mask: Equatable {
        var a: UInt64 = 0, b: UInt64 = 0, c: UInt64 = 0
        func distance(_ other: Mask) -> Int {
            (a ^ other.a).nonzeroBitCount + (b ^ other.b).nonzeroBitCount + (c ^ other.c).nonzeroBitCount
        }
    }

    private struct Tile {
        var last = Mask()
        var hasLast = false
        var stableSince = 0
        var rejected = Mask()
        var isRejected = false
        var quiet = false
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

    public init() {}

    /// Son örnekte ekranda menü vardı (bulanık zeminde birlikte beliren en az üç yazı).
    public var inMenu: Bool { lock.withLock { menu } }

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
        // Nokta örnekleri: kare, her karoya 12x12 piksel düşecek boya (384x216) ara değerlemesiz küçültülür.
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
                    let (mask, bright, dark, deviation) = measured[index]
                    var tile = tiles[index]
                    tile.quiet = deviation < Self.quietDeviation
                    if !tile.hasLast || tile.last.distance(mask) > Self.maskChange { tile.stableSince = now }
                    tile.last = mask
                    tile.hasLast = true
                    if tile.isRejected && tile.rejected.distance(mask) > Self.maskChange { tile.isRejected = false }
                    tiles[index] = tile
                    let textLike = (6...72).contains(bright) && dark >= 36
                    candidate[index] = textLike && now - tile.stableSince >= Self.stableMs && !tile.isRejected
                        && !Self.excluded(column, row, excluded)
                }
            }
            let all = Self.components(candidate)
            let inMenu = isMenu(all, now: now)
            // Menü dışında tek karoluk bileşen (kısa etiket, simge) alan olmaz.
            let components = inMenu ? all : all.filter { $0.tiles.count >= 2 }
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

    /// Çeviri durdu ya da oturum sıfırlandı: alanlar ve karo durumu silinir.
    public func reset() {
        lock.withLock {
            tiles = [Tile](repeating: Tile(), count: tiles.count)
            tracked.removeAll()
            lastSample = nil
            menu = false
        }
    }

    private static func measure(_ pixels: GamePhonePixels) -> [(Mask, Int, Int, Double)] {
        var result = [(Mask, Int, Int, Double)](repeating: (Mask(), 0, 0, 0), count: columns * rows)
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<rows {
                for column in 0..<columns {
                    var mask = Mask()
                    var bright = 0, dark = 0, bit = 0, sum = 0, squares = 0
                    for sy in 0..<samples {
                        let line = (row * samples + sy) * pixels.width * 4
                        for sx in 0..<samples {
                            let p = line + (column * samples + sx) * 4
                            let luma = (299 * Int(bytes[p]) + 587 * Int(bytes[p + 1]) + 114 * Int(bytes[p + 2])) / 1000
                            sum += luma
                            squares += luma * luma
                            if luma >= Self.bright {
                                bright += 1
                                if bit < 64 { mask.a |= 1 << UInt64(bit) }
                                else if bit < 128 { mask.b |= 1 << UInt64(bit - 64) }
                                else { mask.c |= 1 << UInt64(bit - 128) }
                            } else if luma <= Self.dark {
                                dark += 1
                            }
                            bit += 1
                        }
                    }
                    let count = Double(samples * samples)
                    let mean = Double(sum) / count
                    let deviation = max(0, Double(squares) / count - mean * mean).squareRoot()
                    result[row * columns + column] = (mask, bright, dark, deviation)
                }
            }
        }
        return result
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
        return result
    }

    /// Menü durumu: en az üç ayrı bileşen var ve bileşenlerin dışındaki karoların çoğu düşük kenar enerjili (bulanık ya
    /// da karartılmış zemin). Menüye ilk girişte bileşenlerin en çok 300 ms arayla birlikte belirmiş olması da gerekir;
    /// menüde gezinirken (seçim çerçevesi değişince) durum korunur.
    private func isMenu(_ components: [(cells: Cells, tiles: [Int])], now: Int) -> Bool {
        guard components.count >= Self.menuComponents else { return false }
        let inside = Set(components.flatMap(\.tiles))
        let outside = tiles.indices.filter { !inside.contains($0) }
        guard !outside.isEmpty,
              Double(outside.filter { tiles[$0].quiet }.count) >= Self.menuQuietShare * Double(outside.count) else { return false }
        if menu { return true }
        let appeared = components.map { $0.tiles.map { tiles[$0].stableSince }.max()! }
        return appeared.max()! - appeared.min()! <= Self.menuTogetherMs
    }

    private func update(_ components: [(cells: Cells, tiles: [Int])], candidate: [Bool], now: Int, inMenu: Bool) {
        let closed = menu && !inMenu
        menu = inMenu
        // Menü kapandı: menüde bulunan bütün alanlar hemen kalkar (700 ms beklemez).
        if closed { tracked.removeAll(where: \.menu) }
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

    /// Karo dikdörtgeni her yandan yarım karo genişletilmiş, 0..1'e kırpılmış bölge.
    static func region(_ cells: Cells) -> CropRegion {
        CropRegion(top: max(0, (Double(cells.top) - 0.5) / Double(rows)),
                   bottom: min(1, (Double(cells.bottom) + 1.5) / Double(rows)),
                   left: max(0, (Double(cells.left) - 0.5) / Double(columns)),
                   right: min(1, (Double(cells.right) + 1.5) / Double(columns)))
    }
}

/// Otomatik bulunan alanda okunan yazı çevrilmeye değer mi: sayaç, saat, para, tek sözcüklük etiket ya da büyük harfli
/// kısa tabela gürültüdür (Windows/Android: ScreenTextNoise ile aynı kurallar). Yalnız otomatik alanlarda uygulanır.
public enum ScreenTextNoise {
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
