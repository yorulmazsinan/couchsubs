// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Açık zemin üzerindeki koyu yazı (duvardaki kâğıt ilan, tabela, afiş) altyazı değildir. Kullanıcı bildirimi (GitHub
/// #1124, GTA 6): altyazı alanına denk gelen otel odasındaki kâğıt ilan ("SOILED SHEETS, … WILL BE BILLED TO YOUR ROOM";
/// beyaz kâğıt, siyah yazı) altyazı sanılıp çevriliyordu; plaka/tabela kuralı (`SceneText.isSign`, #1052) uzun cümleli
/// ilanı yakalamıyor. Oyun altyazısı açık renkli yazıdır (beyaz/sarı), koyu dış çizgiyle ya da yarı saydam koyu zeminde.
///
/// Satır kutusunun içindeki ve hemen dışındaki şeridin parlaklığına bakılır (`isDarkOnLight`). Zemin tek bir sayı değil,
/// satır boyunca değişen bir çizgidir: kutunun üstündeki ve altındaki şeridin her sütunu için komşu sütunların ortancası
/// (`profileReach`; üst/alt satırın şeride değen harfleri ortancayı bozmaz), kutunun içinde üst ile alt arasında doğrusal.
/// Kâğıda vuran ışık şeridi ve satır boyunca kararan kâğıt böylece zemin sayılır (kullanıcı bildirimi #1124, beta.89: açık
/// mavi kâğıtta lacivert yazı, çapraz ışık şeridi; düz zemin ve sabit zemin parlaklığıyla ölçülünce kaçıyordu). Zemin açık
/// (ortancası en az `lightGround`, en koyu yeri en az `lightGround − groundSpread`; açık mavi/pastel kâğıt da açıktır),
/// yumuşak (komşu sütunlar arası en çok `groundStep`) ve düz (şeridin zemin çizgisinden sapmasının çeyrekler açıklığı en
/// çok `groundSpread`) olmalı. Kutunun içindeki noktalar zemin çizgisine göre ölçülür: koyu küme (Otsu eşiği) zeminden en
/// az `inkGap` koyu ve zeminin en çok `inkShade` katı parlaklıkta (renkli/lacivert mürekkep de kontrastıyla koyu sayılır),
/// yazı payı makul (`minInk`–`maxInk`) ve kutuda zeminden parlak harf yoksa (`glowShare`; koyu dış çizgili beyaz yazı açık
/// gökyüzünün önünde de parlak harf taşır) yazı koyu, zemin açıktır.
/// Bloğun satırlarının yarıdan çoğu böyleyse blok sahne yazısıdır (`isDarkBlock`); konuşan adlı blok hep altyazıdır.
///
/// Koyu altyazılı oyun bozulmasın diye kural oturumda kendini kapatır (`DarkInkStyle`): ortalanmış, birbirinden farklı
/// `DarkInkStyle.distinctBlocks` koyu yazılı blok atılınca bu oyunun altyazısı koyu yazı sayılır, kural o oturumda
/// çalışmaz. Duvardaki ilan aynı yazıyı taşır, sayılmaz.
/// Windows (InkTone.cs) ve Android (InkTone.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
/// Tests/CouchSubsCoreTests/Fixtures/dark-ink.json.
public enum InkTone {
    /// Yerel zemin (zemin çizgisinin ortancası) en az bu kadarsa açıktır (açık mavi kâğıt #BFE0F0 ≈ 216).
    public static let lightGround = 140
    /// Yazı kümesinin ortalama parlaklığı, altındaki zeminin en çok bu katıysa koyudur (kontrast; lacivert mürekkep de).
    public static let inkShade = 0.66
    /// Yazı kümesi zeminden en az bu kadar koyu olmalı.
    public static let inkGap = 70
    /// Kutudaki yazı noktalarının payı bu aralıkta olmalı (boş kâğıt ya da tümü koyu kutu yazı değildir).
    public static let minInk = 0.04
    public static let maxInk = 0.5
    /// Zeminden bu kadar (en çok `glowCeiling`'e kadar) parlak nokta harftir: payı `glowShare`'i aşarsa yazı açık renklidir.
    public static let glow = 20
    public static let glowCeiling = 250
    public static let glowShare = 0.03
    /// Yerel zemin düz olmalı: şeridin zemin çizgisinden sapmasının çeyrekler açıklığı (üst çeyrek − alt çeyrek) en çok bu
    /// kadar (kâğıt düzdür, ışık degradesi zemin çizgisindedir; oyun sahnesi çoğu zaman düz değil).
    public static let groundSpread = 40
    /// Zemin çizgisi yumuşak olmalı: komşu iki sütun arasındaki fark en çok bu kadar (ışık degradesi yumuşaktır, sahnedeki
    /// kenar değil).
    public static let groundStep = 40
    /// Zemin çizgisinin bir sütunu, iki yanındaki bu kadar sütunla birlikte şeridin ortancasıdır.
    public static let profileReach = 4
    /// Kutunun dışındaki şeridin kalınlığı (satır yüksekliğine oranla).
    public static let ringShare = 0.3
    /// Altyazı günlüğündeki atılma nedeni.
    public static let reason = "koyu yazı açık zeminde (kâğıt/tabela)"

    static let samplesX = 48
    static let samplesY = 10
    static let ringSamples = 2
    static let minSamples = 16

    /// `box` (görüntüye oranla) açık zemin üzerinde koyu yazı mı. `luma(x, y)`: görüntünün (piksel) parlaklığı, 0–255.
    public static func isDarkOnLight(_ box: TextBox, width: Int, height: Int, luma: (Int, Int) -> Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let w = Double(width), h = Double(height)
        let left = max(0, min(1, box.left)) * w, right = max(0, min(1, box.right)) * w
        let top = max(0, min(1, box.top)) * h, bottom = max(0, min(1, box.bottom)) * h
        guard right - left >= 2, bottom - top >= 2 else { return false }
        let inside = grid(left, top, right, bottom, samplesX, samplesY, width, height, luma)
        let d = (bottom - top) * ringShare
        // Şeritler: üst ve alt (samplesX × ringSamples), sol ve sağ (ringSamples × samplesY); görüntüden taşan şerit yok.
        var strips: [[Int]?] = [nil, nil, nil, nil]
        if d >= 1 {
            let bounds = [
                (left, top - d, right, top, samplesX, ringSamples),
                (left, bottom, right, bottom + d, samplesX, ringSamples),
                (left - d, top, left, bottom, ringSamples, samplesY),
                (right, top, right + d, bottom, ringSamples, samplesY),
            ]
            for (i, (l, t, r, b, nx, ny)) in bounds.enumerated() where l >= 0 && t >= 0 && r <= w && b <= h {
                strips[i] = grid(l, t, r, b, nx, ny, width, height, luma)
            }
        }
        return decide(inside: inside, top: strips[0], bottom: strips[1], left: strips[2], right: strips[3])
    }

    /// Kutunun içindeki (`inside`, samplesX × samplesY) ve dışındaki şeritlerin parlaklıklarıyla karar.
    static func decide(inside: [Int], top: [Int]?, bottom: [Int]?, left: [Int]?, right: [Int]?) -> Bool {
        let ringCount = [top, bottom, left, right].reduce(0) { $0 + ($1?.count ?? 0) }
        guard inside.count == samplesX * samplesY, ringCount >= minSamples else { return false }
        // Zemin çizgisi: üst ve alt şeridin sütun sütun ortancası; biri yoksa öteki, ikisi de yoksa yan şeritlerin ortancası.
        var upper = top.map(profile), lower = bottom.map(profile)
        if upper == nil && lower == nil {
            let sides = ((left ?? []) + (right ?? [])).sorted()
            upper = [Int](repeating: sides[sides.count / 2], count: samplesX)
        }
        let up = upper ?? lower!, down = lower ?? upper!
        let ground = { (column: Int, row: Int) -> Int in
            up[column] + (down[column] - up[column]) * (2 * row + 1) / (2 * samplesY)
        }
        let line = (up + down).sorted()
        guard line[line.count / 2] >= lightGround, line[0] >= lightGround - groundSpread else { return false }
        for p in [up, down] {
            for c in 1..<samplesX where abs(p[c] - p[c - 1]) > groundStep { return false }
        }
        var residuals: [Int] = []
        if let top { residuals += top.indices.map { top[$0] - up[$0 % samplesX] } }
        if let bottom { residuals += bottom.indices.map { bottom[$0] - down[$0 % samplesX] } }
        if let left { residuals += left.indices.map { left[$0] - ground(0, $0 / ringSamples) } }
        if let right { residuals += right.indices.map { right[$0] - ground(samplesX - 1, $0 / ringSamples) } }
        residuals.sort()
        guard residuals[residuals.count * 3 / 4] - residuals[residuals.count / 4] <= groundSpread else { return false }
        let grounds = inside.indices.map { ground($0 % samplesX, $0 / samplesX) }
        // Zemine göre parlaklık (128 zemin); Otsu eşiğinin altı yazıdır.
        let relative = inside.indices.map { max(0, min(255, inside[$0] - grounds[$0] + 128)) }
        let threshold = otsu(relative)
        let ink = inside.indices.filter { relative[$0] <= threshold }
        guard !ink.isEmpty, ink.count < inside.count else { return false }
        let share = Double(ink.count) / Double(inside.count)
        guard share >= minInk, share <= maxInk else { return false }
        let inkMean = Double(ink.reduce(0) { $0 + inside[$1] }) / Double(ink.count)
        let groundMean = Double(ink.reduce(0) { $0 + grounds[$1] }) / Double(ink.count)
        guard groundMean - inkMean >= Double(inkGap), inkMean <= groundMean * inkShade else { return false }
        let glowing = inside.indices.filter { inside[$0] >= min(grounds[$0] + glow, glowCeiling) }.count
        return Double(glowing) / Double(inside.count) < glowShare
    }

    /// Şeridin (samplesX × ringSamples) zemin çizgisi: her sütun için `profileReach` komşusuyla birlikte ortanca.
    private static func profile(_ strip: [Int]) -> [Int] {
        (0..<samplesX).map { c in
            var values: [Int] = []
            for r in 0..<ringSamples {
                for k in max(0, c - profileReach)...min(samplesX - 1, c + profileReach) { values.append(strip[r * samplesX + k]) }
            }
            values.sort()
            return values[values.count / 2]
        }
    }

    /// Bloğun kutulu satırlarının yarıdan çoğu açık zeminde koyu yazı mı (`dark`: satır kutusu için `isDarkOnLight`).
    public static func isDarkBlock(_ block: Reading, dark: (TextBox) -> Bool) -> Bool {
        let boxes = block.lines.compactMap(\.box)
        guard !boxes.isEmpty else { return false }
        return boxes.filter(dark).count * 2 > boxes.count
    }

    /// Okunan alanın görüntüsü için satır kutusu denetimi (kutular görüntüye oranla). Görüntü ilk soruda bir kez çözülür.
    public static func sampler(_ image: CGImage) -> (TextBox) -> Bool {
        let pixels = LazyPixels(image)
        return { box in
            guard let grid = pixels.value else { return false }
            return isDarkOnLight(box, width: grid.width, height: grid.height) { x, y in
                let i = (y * grid.width + x) * 4
                return (299 * Int(grid.bytes[i]) + 587 * Int(grid.bytes[i + 1]) + 114 * Int(grid.bytes[i + 2])) / 1000
            }
        }
    }

    private final class LazyPixels {
        private let image: CGImage
        private var loaded = false
        private var pixels: GamePhonePixels?
        init(_ image: CGImage) { self.image = image }
        var value: GamePhonePixels? {
            if !loaded {
                loaded = true
                pixels = GamePhonePixels(image)
            }
            return pixels
        }
    }

    private static func grid(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double, _ nx: Int, _ ny: Int,
                             _ width: Int, _ height: Int, _ luma: (Int, Int) -> Int) -> [Int] {
        var values: [Int] = []
        values.reserveCapacity(nx * ny)
        for sy in 0..<ny {
            let y = min(height - 1, Int(top + (Double(sy) + 0.5) * (bottom - top) / Double(ny)))
            for sx in 0..<nx {
                let x = min(width - 1, Int(left + (Double(sx) + 0.5) * (right - left) / Double(nx)))
                values.append(max(0, min(255, luma(x, y))))
            }
        }
        return values
    }

    private static func otsu(_ values: [Int]) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for value in values { histogram[value] += 1 }
        let total = Double(values.count)
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * histogram[i]) }
        var below = 0.0, belowSum = 0.0, best = -1.0
        var threshold = 127
        for t in 0..<255 {
            below += Double(histogram[t])
            if below == 0 { continue }
            let above = total - below
            if above == 0 { break }
            belowSum += Double(t * histogram[t])
            let gap = belowSum / below - (sum - belowSum) / above
            let between = below * above * gap * gap
            if between > best {
                best = between
                threshold = t
            }
        }
        return threshold
    }
}

/// Oturumun koyu yazılı altyazı biçimi: ortalanmış, birbirinden farklı (biri ötekini içermeyen, benzemeyen) en az
/// `distinctBlocks` koyu yazılı blok atılınca oyunun altyazısı koyu yazı sayılır ve `InkTone` kuralı o oturumda kapanır
/// (`isGameStyle`). Duvardaki ilan hep aynı yazıdır (kısmi okunsa da), sayılmaz. Hat sıfırlanınca unutulur
/// (Windows: DarkInkStyle, Android: DarkInkStyle).
///
/// `lightInk`: oyunun altyazısı bilinen açık renkli yazı (GTA 6: beyaz); kural o oyunda hiç kapanmaz, koyu bloklar
/// sayılmaz. Kullanıcı bildirimi (X, beta-104, Windows): GTA 6 telefonu bulunamadığı anlarda ekranın ortasındaki sohbet
/// balonları (açık zeminde koyu yazı) atılıyor, dört farklı mesaj sayılınca kural oturumda kapanıyordu; sonraki balonlar
/// altyazı sanılıp telefonun ortasından geçen satır olarak ya da balonların üstüne üst üste çiziliyordu.
public struct DarkInkStyle: Equatable, Sendable {
    public static let distinctBlocks = 4

    private(set) var texts: [String] = []
    /// Oyunun altyazısı bilinen açık renkli yazı: kural kapanmaz (GTA 6).
    public var lightInk = false

    public init() {}

    public var isGameStyle: Bool { !lightInk && texts.count >= Self.distinctBlocks }

    /// Koyu yazılı diye atılan blok (satır kutuları `area`'ya oranlı). Kural bu blokla kapandıysa true.
    @discardableResult
    public mutating func observe(_ block: Reading, in area: TextBox) -> Bool {
        guard !lightInk, !isGameStyle, let box = block.box?.placed(in: area), SceneText.isCentered(box) else { return false }
        let text = TextMatch.normalize(block.text)
        guard !text.isEmpty,
              !texts.contains(where: { $0.contains(text) || text.contains($0) || TextMatch.isSimilar($0, text) })
        else { return false }
        texts.append(text)
        return isGameStyle
    }

    public mutating func reset() { texts = [] }
}
