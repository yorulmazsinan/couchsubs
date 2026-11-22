// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import CoreGraphics
import Foundation

/// Ekran yazısı denetimi (#856, #859): menü ve görev ekranında "Ekranı çevir" ile otomatik ekran yazısı her yazıyı kendi
/// kutusunda, kendi yerinde ve özgün renginde çizmeli. Beklenen (`frames.json` → `screen`):
/// - `blocks`: ayrı kutuda çevrilmesi gereken yazılar (üst menünün her sekmesi, görev başlığı, görev açıklaması). Hiçbir
///   kutu iki bloğu birleştirmemeli; çevrilen her blok kendi kutusunda bulunmalı.
/// - `keep`: çevrilmeyen özel adlar ("JASON & LUCIA"): çevirmene gitmemeli, kutusu çizilmemeli.
/// - `clear`: örtülmemesi gereken yerler (görev fotoğrafı), kareye oranla [sol, üst, sağ, alt].
/// - `within`: yalnız ortası bu alanda olan kutular denetlenir (harita kartı karesinde kartın çevresi; karenin geri
///   kalanı başka karelerin konusu), kareye oranla [sol, üst, sağ, alt].
/// Ayrıca kutular birbirine binmemeli ve her kutunun zemini özgün yazının zeminine yakın olmalı (siyah kutu değil).
/// Koşucu eski etiketin çekirdeğine karşı da derlendiği için yalnız eski çekirdekte de olan API kullanılır.
struct ScreenExpectation: Decodable {
    var blocks: [String]
    var keep: [String]?
    var clear: [[Double]]?
    var within: [Double]?
}

/// Çizilen bir çeviri kutusu: kaynağı (okunan İngilizce), çevirisi, yeri ve zemin rengi.
struct DrawnUnit {
    var source: String
    var text: String
    var box: TextBox
    var background: String?
}

/// TV yerine: ek alan gönderimlerini blokları ve stilleriyle kaydeder (alan başına son gönderim).
final class BlockRecorder: RegionSending {
    var current: [String: [DrawnUnit]] = [:]
    let translator: DictionaryTranslator

    init(translator: DictionaryTranslator) { self.translator = translator }

    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil, blocks: nil)
    }

    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons, blocks: nil)
    }

    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                    blocks: [ScreenTranslation.Item]?) {
        guard !text.isEmpty, let box else {
            current[id] = nil
            return
        }
        if let blocks {
            current[id] = blocks.map { DrawnUnit(source: $0.source, text: $0.translation, box: $0.box, background: $0.style?.background) }
        } else {
            // Bloksuz tek kutu: kaynağı, çıktısı metinde geçen çevirilerden.
            let sources = translator.calls.filter { !$0.output.isEmpty && text.contains($0.output) }.map(\.source)
            current[id] = [DrawnUnit(source: sources.joined(separator: "\n"), text: text, box: box, background: nil)]
        }
    }

    func clearRegions() { current.removeAll() }
}

extension Runner {
    /// Bir karenin ekran yazısı denetimi: iki yol ("Ekranı çevir", otomatik ekran yazısı); geçtiyse nil, kaldıysa notlar.
    func checkScreen(_ frame: Frame, _ image: CGImage) async -> [String] {
        guard let expected = frame.screen else { return [] }
        var notes: [String] = []
        // 1) "Ekranı çevir": bütün kare okunur, gruplar sırayla çevrilir.
        let whole = DictionaryTranslator(words: words)
        let reading = (try? reader.readLines(image, deep: false)) ?? .empty
        let items = (try? await ScreenTranslation.translate(reading, using: whole, frame: image)) ?? []
        let screenUnits = items.map { DrawnUnit(source: $0.source, text: $0.translation, box: $0.box, background: $0.style?.background) }
        notes += Self.judge(screenUnits, calls: whole.calls.map(\.source), expected, image, read: reading.lines.map(\.text))
            .map { "Ekranı çevir: " + $0 }
        // 2) Otomatik ekran yazısı: karo dedektörü alanları bulur, alanlar okunup çevrilir.
        let auto = DictionaryTranslator(words: words)
        let detector = ScreenTextDetector()
        var time = 1_000
        for _ in 0..<12 {
            detector.sample(image, now: time, excluded: [CropRegion()])
            time += ScreenTextDetector.sampleIntervalMs
        }
        let areas = detector.areas
        var autoUnits: [DrawnUnit] = []
        if areas.isEmpty {
            notes.append("otomatik ekran yazısı: alan bulunamadı")
        } else {
            let server = BlockRecorder(translator: auto)
            var clock = 0
            let watcher = RegionWatcher(reader: reader, translator: auto, server: server, clock: { clock })
            watcher.slowdown = { 1 }
            for _ in 0..<3 {
                await watcher.pass(image, areas: areas)
                clock += RegionWatcher.autoIntervalMs
            }
            autoUnits = areas.flatMap { server.current[$0.id] ?? [] }
            let autoRead = areas.flatMap { area in
                ((try? reader.readLines(RegionCropper.crop(image, to: area.region), deep: false)) ?? .empty).lines.map(\.text)
            }
            let autoNotes = Self.judge(autoUnits, calls: auto.calls.map(\.source), expected, image, read: autoRead)
            notes += autoNotes.map { "otomatik: " + $0 }
            // Kalan karede alanlar ve çizilenler de yazılır (CI'daki Vision okuması yereldekinden farklı olabilir).
            if !autoNotes.isEmpty {
                notes.append("otomatik alanlar: " + areas.map { String(format: "[%.3f %.3f %.3f %.3f]", $0.region.left, $0.region.top,
                                                                                 $0.region.right, $0.region.bottom) }.joined(separator: " "))
                notes.append("otomatik çizilen: " + autoUnits.map(Self.describe).joined(separator: " | "))
                notes.append("otomatik okunan: " + auto.calls.map(\.source).joined(separator: " | "))
                for area in areas {
                    let crop = RegionCropper.crop(image, to: area.region)
                    let lines = ((try? reader.readLines(crop, deep: false)) ?? .empty).lines
                    notes.append("ham okuma " + String(format: "[%.3f %.3f]", area.region.left, area.region.top) + ": "
                        + lines.map { line in
                            let b = line.box ?? TextBox(left: 0, top: 0, right: 0, bottom: 0)
                            return String(format: "«%@» [%.3f %.3f %.3f %.3f] c=%.2f w=%d", line.text, b.left, b.top, b.right, b.bottom,
                                          line.confidence ?? -1, line.words?.count ?? 0)
                        }.joined(separator: " | "))
                }
            }
        }
        // 3) Oyunun hazır alanları (GTA 6: sol üstte yardım kutusu, sağda mesaj kartı): alan yazının bir kısmını keser;
        // her bloğun bulunması beklenmez, ama birleşme, fotoğrafı örtme, siyah kutu ve ad çevirisi olmamalı.
        let presetTranslator = DictionaryTranslator(words: words)
        let presetServer = BlockRecorder(translator: presetTranslator)
        var presetClock = 0
        let presetWatcher = RegionWatcher(reader: reader, translator: presetTranslator, server: presetServer, clock: { presetClock })
        presetWatcher.slowdown = { 1 }
        let presets = GameAreaPresets.areas(frame.game)
        for _ in 0..<3 {
            await presetWatcher.pass(image, areas: presets)
            presetClock += RegionWatcher.defaultIntervalMs
        }
        let presetUnits = presets.flatMap { presetServer.current[$0.id] ?? [] }
        notes += Self.judge(presetUnits, calls: presetTranslator.calls.map(\.source), expected, image, requireAll: false)
            .map { "hazır alan: " + $0 }
        if verbose { for unit in presetUnits { print("    [hazır alan] \(Self.describe(unit))") } }
        if verbose {
            print("— \(frame.id) ekran: " + (notes.isEmpty ? "geçti" : notes.joined(separator: " | ")))
            for unit in screenUnits { print("    [ekranı çevir] \(Self.describe(unit))") }
            for area in areas { print(String(format: "    [alan] %@ menü=%@ [%.3f %.3f %.3f %.3f]", area.id, area.menu ? "evet" : "hayır",
                                             area.region.left, area.region.top, area.region.right, area.region.bottom)) }
            for unit in autoUnits { print("    [otomatik] \(Self.describe(unit))") }
        }
        return notes
    }

    static func describe(_ unit: DrawnUnit) -> String {
        String(format: "[%.3f %.3f %.3f %.3f] %@ «%@» → «%@»", unit.box.left, unit.box.top, unit.box.right, unit.box.bottom,
               unit.background ?? "stilsiz", unit.source.replacingOccurrences(of: "\n", with: " / "),
               unit.text.replacingOccurrences(of: "\n", with: " / "))
    }

    private static func tokens(_ text: String, exact: Bool = false) -> [String] {
        (exact ? text : text.lowercased()).split { !$0.isLetter && !$0.isNumber && $0 != "&" }.map(String.init)
    }

    /// `needle`'ın sözcükleri `haystack`'te art arda geçiyor mu. `exact`: büyük/küçük harf de aynı ("SOUVENIR" ayrıntısı
    /// açıklamadaki "souvenir" sözcüğü değildir).
    private static func contains(_ haystack: String, _ needle: String, exact: Bool = false) -> Bool {
        let hay = tokens(haystack, exact: exact), want = tokens(needle, exact: exact)
        guard !want.isEmpty, hay.count >= want.count else { return false }
        return (0...(hay.count - want.count)).contains { Array(hay[$0..<($0 + want.count)]) == want }
    }

    static func judge(_ units: [DrawnUnit], calls: [String], _ expected: ScreenExpectation, _ image: CGImage,
                      requireAll: Bool = true, read: [String]? = nil) -> [String] {
        var notes: [String] = []
        let keep = expected.keep ?? []
        var units = units
        if let area = box(expected.within) {
            units = units.filter { unit in
                let x = (unit.box.left + unit.box.right) / 2, y = (unit.box.top + unit.box.bottom) / 2
                return x >= area.left && x <= area.right && y >= area.top && y <= area.bottom
            }
        }
        // Birleşen bloklar: bir kutu iki beklenen yazıyı taşıyor.
        for unit in units {
            let inside = Set(expected.blocks + keep).filter { contains(unit.source, $0, exact: $0 == $0.uppercased()) }.sorted()
            if inside.count >= 2 { notes.append("birleşti: \(inside.map { "\"\($0)\"" }.joined(separator: " + "))") }
        }
        // Her blok kendi kutusunda çevrilmiş. Yazı tanımanın hiç okumadığı blok (CI makinesindeki Vision sürümü seçili pembe
        // sekmeyi okumayabiliyor) hattın sorunu değildir, aranmaz.
        let seen = read.map { lines in { (block: String) in lines.contains { contains($0, block) } } } ?? { _ in true }
        for block in expected.blocks where requireAll && !keep.contains(block) && seen(block) {
            if !units.contains(where: { similarity($0.source, block) >= 0.85 }) { notes.append("ayrı kutuda yok: \"\(block)\"") }
        }
        // Özel ad çevrilmez.
        for name in keep {
            if calls.contains(where: { contains($0, name) }) || units.contains(where: { contains($0.source, name) }) {
                notes.append("özel ad çevrildi: \"\(name)\"")
            }
        }
        // Görev fotoğrafı ve tuş simgesi örtülmez: TV kutusu kenar payıyla en çok kenarından dörtte birine değebilir.
        for values in expected.clear ?? [] {
            guard let keepOut = box(values) else { continue }
            for unit in units where area(intersection(drawn(unit.box), keepOut)) > 0.25 * area(keepOut) {
                notes.append("fotoğrafı örtüyor: \"\(unit.source.replacingOccurrences(of: "\n", with: " / ").prefix(30))\"")
            }
        }
        // Kutular birbirine binmez.
        for i in units.indices {
            for j in units.indices where j > i && intersects(units[i].box, units[j].box) {
                notes.append("üst üste: \"\(units[i].source.replacingOccurrences(of: "\n", with: " / ").prefix(20))\" / \"\(units[j].source.replacingOccurrences(of: "\n", with: " / ").prefix(20))\"")
            }
        }
        // Zemin özgün yazının zemini (stilsiz kutu TV'de siyah çizilir).
        for unit in units {
            guard let background = unit.background, let actual = ground(image, unit.box) else {
                notes.append("stilsiz (siyah) kutu: \"\(unit.source.replacingOccurrences(of: "\n", with: " / ").prefix(30))\"")
                continue
            }
            if colorDistance(background, actual) > 48 {
                notes.append("zemin rengi \(background) ≠ \(actual): \"\(unit.source.replacingOccurrences(of: "\n", with: " / ").prefix(30))\"")
            }
        }
        return notes
    }

    private static func area(_ box: TextBox) -> Double { max(0, box.right - box.left) * max(0, box.bottom - box.top) }

    private static func intersection(_ a: TextBox, _ b: TextBox) -> TextBox {
        TextBox(left: max(a.left, b.left), top: max(a.top, b.top), right: min(a.right, b.right), bottom: min(a.bottom, b.bottom))
    }

    private static func drawn(_ box: TextBox) -> TextBox {
        let dx = coverMargin / 1920, dy = coverMargin / 1080
        return TextBox(left: box.left - dx, top: box.top - dy, right: box.right + dx, bottom: box.bottom + dy)
    }

    private static func intersects(_ a: TextBox, _ b: TextBox) -> Bool {
        min(a.right, b.right) > max(a.left, b.left) && min(a.bottom, b.bottom) > max(a.top, b.top)
    }

    /// Kutunun hemen çevresindeki (yazının dışı, kenar payı kadar) en sık renk: özgün zemin.
    private static func ground(_ image: CGImage, _ box: TextBox) -> String? {
        let data = Images.pixels(image)
        let width = image.width, height = image.height
        let pad = 8
        let ix0 = Int(box.left * Double(width)), ix1 = Int(box.right * Double(width))
        let iy0 = Int(box.top * Double(height)), iy1 = Int(box.bottom * Double(height))
        let x0 = max(0, ix0 - pad), x1 = min(width, ix1 + pad), y0 = max(0, iy0 - pad), y1 = min(height, iy1 + pad)
        guard x1 > x0, y1 > y0 else { return nil }
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for y in y0..<y1 {
            for x in x0..<x1 where x < ix0 || x >= ix1 || y < iy0 || y >= iy1 {
                let i = (y * width + x) * 4
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                let key = (r / 24) << 16 | (g / 24) << 8 | (b / 24)
                let old = buckets[key] ?? (0, 0, 0, 0)
                buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
            }
        }
        guard let top = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
        return String(format: "#%02X%02X%02X", top.r / top.count, top.g / top.count, top.b / top.count)
    }

    private static func colorDistance(_ a: String, _ b: String) -> Int {
        func rgb(_ hex: String) -> [Int] {
            let value = Int(hex.dropFirst(), radix: 16) ?? 0
            return [(value >> 16) & 255, (value >> 8) & 255, value & 255]
        }
        return zip(rgb(a), rgb(b)).map { abs($0 - $1) }.max() ?? 255
    }
}
