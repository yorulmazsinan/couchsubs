// SPDX-License-Identifier: AGPL-3.0-only

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

    public init(_ text: String, box: TextBox? = nil, confidence: Double? = nil) {
        self.text = text
        self.box = box
        self.confidence = confidence
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

    /// Oyunun düğme ipuçları ("R2 Swing", "△ Pick up") çıkarılmış hali; bunlar altyazı değildir.
    public func withoutButtonPrompts() -> Reading {
        Reading(lines: lines.filter { !ButtonPrompts.isPrompt($0.text) })
    }

    /// Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e", "waters2aljd") ayıklanmış hali; çevirmen bunları olduğu
    /// gibi taşıyıp TV'de anlamsız harfler gösteriyordu.
    public func withoutOcrNoise() -> Reading {
        Reading(lines: lines.map { TextLine(OcrNoise.clean($0.text), box: $0.box, confidence: $0.confidence) })
    }

    /// Alandaki altyazı bloğu. Seçilen alanda altyazının yanında menü ("MAP / HELP / SETTINGS" alt alta), köşedeki
    /// gösterge ("9", "PHOTO MODE") da okunuyordu; hepsi tek cümle gibi çevrilip TV'de bütün alanı kaplayan kutuyla
    /// gösteriliyordu. Satırlar yerlerine göre bloklara ayrılır; ortalanmış ve menü olmayan en alttaki blok altyazıdır.
    /// Ortalanmış blok yoksa en az üç sözcüklü, menü olmayan en alttaki blok alınır. Satırların yeri bilinmiyorsa
    /// okuma olduğu gibi kalır. `area`, okunan alanın karedeki yeridir (ortalanmışlık karenin ortasına göre ölçülür).
    public func subtitleBlock(in area: TextBox) -> Reading {
        guard !lines.isEmpty, lines.allSatisfy({ $0.box != nil }) else { return self }
        var blocks: [[TextLine]] = []
        for line in lines.sorted(by: { $0.box!.top < $1.box!.top }) {
            let box = line.box!.placed(in: area)
            if let index = blocks.lastIndex(where: { Self.belongs(box, to: $0, in: area) }) {
                blocks[index].append(line)
            } else {
                blocks.append([line])
            }
        }
        let candidates = blocks.map { Reading(lines: $0) }.filter { !$0.isMenu }
        let centered = candidates.filter { reading in
            guard let box = reading.box?.placed(in: area) else { return false }
            return abs((box.left + box.right) / 2 - 0.5) <= 0.12
        }
        if let block = centered.max(by: { $0.box!.bottom < $1.box!.bottom }) { return block }
        return candidates.filter { $0.text.split(whereSeparator: \.isWhitespace).count >= 3 }
            .max(by: { $0.box!.bottom < $1.box!.bottom }) ?? .empty
    }

    /// Bloğun son satırının hemen altında (arada bir satır yüksekliğinden az) ve yatayda onunla üst üste binen satır
    /// o bloğa aittir.
    private static func belongs(_ box: TextBox, to block: [TextLine], in area: TextBox) -> Bool {
        let last = block.last!.box!.placed(in: area)
        let height = max(box.bottom - box.top, last.bottom - last.top)
        guard box.top - last.bottom < height * 0.8, box.top >= last.top else { return false }
        let overlap = min(box.right, last.right) - max(box.left, last.left)
        let narrower = min(box.right - box.left, last.right - last.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    /// Alt alta kısa ve noktalamasız satırlar ("MAP", "HELP", "SOCIAL CLUB") menüdür, konuşma değil.
    var isMenu: Bool {
        lines.count >= 3 && lines.allSatisfy { line in
            line.text.split(whereSeparator: \.isWhitespace).count <= 3 && !SubtitleStabilizer.endsSentence(line.text)
        }
    }

    /// Satır kutularını `area` içindeki oranlardan dış çerçevenin oranlarına taşır.
    public func placed(in area: TextBox) -> Reading {
        Reading(lines: lines.map { TextLine($0.text, box: $0.box?.placed(in: area), confidence: $0.confidence) })
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
        if verbs.contains(first.lowercased()), tokens.count >= 2, tokens.count <= 10 {
            let second = tokens[1]
            return isButton(second) || lookalikes.contains(second)
        }
        return false
    }
}
