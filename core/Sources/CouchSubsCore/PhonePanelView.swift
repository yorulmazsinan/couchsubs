// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(SwiftUI)
import SwiftUI
import ImageIO

/// GTA 6 telefonunun yanındaki sohbet paneli (Mac yayın ve saydam penceresi, iPhone altyazı ekranı; Windows
/// PhonePanelView.cs, Android PhonePanel.kt, TV app.js `placePanel` aynı çizim): yuvarlak köşeli, yarı saydam koyu
/// kart; üstte kişinin adı, altında mesajlar sırayla (karşı taraf solda krem, oyuncu sağda amber balon, not ortada).
/// Mesajlar karta sığmazsa en eskiler üstten kırpılır, son mesajlar görünür kalır. Sağ altta sade kanepe simgesi.
public struct PhonePanelView: View {
    let panel: ScreenPhoneCard.Panel
    let fontSize: CGFloat
    let radius: CGFloat

    /// `fontSize`: mesaj yazısının boyu (nokta); `radius`: kartın köşesi.
    public init(_ panel: ScreenPhoneCard.Panel, fontSize: CGFloat, radius: CGFloat) {
        self.panel = panel
        self.fontSize = max(8, fontSize)
        self.radius = radius
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width * 0.16
            VStack(spacing: fontSize * 0.5) {
                if let title = panel.title {
                    Text(verbatim: title.translation)
                        .font(.system(size: fontSize * 1.05, weight: .bold))
                        .foregroundStyle(Self.color(title.style?.foreground, fallback: .white))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                VStack(spacing: 0) {
                    // Anahtarlı liste: en eski mesaj düşünce ya da yenisi eklenince kalan balonlar yeniden yaratılmaz.
                    ForEach(Self.keys(panel.messages), id: \.self) { key in
                        message(panel.messages[key.index], side: side)
                            .padding(.top, fontSize * Self.gap(panel.messages, key.index))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipped()
            }
            .padding(.horizontal, fontSize * 0.6)
            .padding(.top, fontSize * 0.55)
            .padding(.bottom, fontSize * 1.3)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Self.color(panel.card.style?.background, fallback: .black).opacity(ScreenPhoneCard.panelOpacity)))
            .overlay(alignment: .bottomTrailing) {
                CouchGlyph()
                    .fill(Self.color(panel.card.style?.foreground, fallback: .white).opacity(0.35))
                    .frame(width: fontSize * 0.9, height: fontSize * 0.6)
                    .padding(fontSize * 0.45)
            }
        }
        .allowsHitTesting(false)
    }

    /// Mesajın kimliği: parçası, yazısı ve aynı yazının kaçıncı tekrarı (dizin kimliğe girmez).
    struct Key: Hashable {
        let part: String, text: String, occurrence: Int
        let index: Int
        static func == (a: Key, b: Key) -> Bool { a.part == b.part && a.text == b.text && a.occurrence == b.occurrence }
        func hash(into hasher: inout Hasher) {
            hasher.combine(part)
            hasher.combine(text)
            hasher.combine(occurrence)
        }
    }

    static func keys(_ messages: [ScreenTranslation.Item]) -> [Key] {
        var seen: [String: Int] = [:]
        return messages.enumerated().map { index, item in
            let part = item.panel?.rawValue ?? ""
            let occurrence = seen[part + "\u{1F}" + item.translation, default: 0]
            seen[part + "\u{1F}" + item.translation] = occurrence + 1
            return Key(part: part, text: item.translation, occurrence: occurrence, index: index)
        }
    }

    /// Sohbet listesinin satırı (kişi adı, önizleme, bölüm başlığı): sola yaslı not; ad ve başlık kalın.
    static func isListRow(_ item: ScreenTranslation.Item) -> Bool {
        item.panel == .note && item.look?.align == .left
    }

    /// Satırın üstündeki boşluk (yazı boyuna oranla): önizleme, üstündeki kişi adının hemen altındadır.
    static func gap(_ messages: [ScreenTranslation.Item], _ index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let item = messages[index], previous = messages[index - 1]
        if isListRow(item), isListRow(previous), item.look?.bold != true, previous.look?.bold == true,
           previous.style?.foreground != ScreenPhoneCard.noteColor.foreground { return 0.08 }
        return 0.45
    }

    @ViewBuilder private func message(_ item: ScreenTranslation.Item, side: CGFloat) -> some View {
        let mine = item.panel == .mine, note = item.panel == .note, listed = Self.isListRow(item)
        let text = Text(verbatim: item.translation)
            .font(.system(size: listed ? fontSize * 0.92 : note ? fontSize * 0.8 : fontSize,
                          weight: listed ? (item.look?.bold == true ? .bold : .regular) : note ? .medium : .semibold))
            .foregroundStyle(Self.color(item.style?.foreground, fallback: .white))
            .multilineTextAlignment(note && !listed ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
        if listed {
            text.frame(maxWidth: .infinity, alignment: .leading)
        } else if note {
            text.frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                if mine { Spacer(minLength: side) }
                text
                    .padding(.horizontal, fontSize * 0.6)
                    .padding(.vertical, fontSize * 0.32)
                    .background(RoundedRectangle(cornerRadius: fontSize * 0.75, style: .continuous)
                        .fill(Self.color(item.style?.background, fallback: .gray)))
                if !mine { Spacer(minLength: side) }
            }
        }
    }

    static func color(_ hex: String?, fallback: Color) -> Color {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return fallback }
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

/// Panelin sağ altındaki sade kanepe (`ScreenPhoneCard.couchGlyph`, 24×16 ızgara).
public struct CouchGlyph: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let sx = rect.width / 24, sy = rect.height / 16
        for part in ScreenPhoneCard.couchGlyph {
            let r = CGRect(x: rect.minX + part.x * sx, y: rect.minY + part.y * sy, width: part.width * sx, height: part.height * sy)
            path.addRoundedRect(in: r, cornerSize: CGSize(width: part.radius * sx, height: part.radius * sy))
        }
        return path
    }
}

/// Paneli karedeki yerinde çizer: `size` karenin (ya da onu gösteren alanın) boyu; yazı boyu panelin satır yüksekliğinden.
public struct PhonePanelInFrame: View {
    let panel: ScreenTranslation.Item
    let parts: ScreenPhoneCard.Panel
    let size: CGSize
    let minFont: CGFloat

    /// `minFont`: küçük ekranda (iPhone) yazı bundan küçülmez; sığmayan eski mesajlar panelde üstten kırpılır.
    public init(_ parts: ScreenPhoneCard.Panel, size: CGSize, minFont: CGFloat = 0) {
        self.parts = parts
        self.panel = parts.card
        self.size = size
        self.minFont = minFont
    }

    public var body: some View {
        let box = panel.box
        if parts.aligned {
            PhonePanelAligned(parts, size: size, minFont: minFont)
                .transition(.opacity)
        } else {
            PhonePanelView(parts, fontSize: max(minFont, panel.lineHeight * size.height * 0.85),
                           radius: max(6, ScreenPhoneCard.panelRadius * size.height / 1080))
                .frame(width: max(0, box.right - box.left) * size.width, height: max(0, box.bottom - box.top) * size.height)
                .position(x: (box.left + box.right) * 0.5 * size.width, y: (box.top + box.bottom) * 0.5 * size.height)
        }
    }
}

/// Hizalı panel (`ScreenPhoneCard.Panel.aligned`; TV app.js `placePanel`, Windows PhoneBlocksCanvas, Android PhonePanel
/// aynı çizim): zemin kartı ve simge yok; her Türkçe balon kendi kutusunda, telefondaki İngilizce balonuyla aynı
/// yükseklikte, oyunun üstünde doğrudan çizilir. Balon telefonun balon renginde, %85 örtülü, yuvarlak köşeli; gelen sola,
/// giden sağa yaslı. Kişi adı üstte küçük başlık, notlar ortada koyu zeminde. Yer değişince kısa geçişle kayar.
public struct PhonePanelAligned: View {
    let parts: ScreenPhoneCard.Panel
    let size: CGSize
    let minFont: CGFloat

    public init(_ parts: ScreenPhoneCard.Panel, size: CGSize, minFont: CGFloat = 0) {
        self.parts = parts
        self.size = size
        self.minFont = minFont
    }

    public var body: some View {
        let font = max(8, minFont, parts.card.lineHeight * size.height * 0.85)
        ZStack(alignment: .topLeading) {
            if let title = parts.title { part(title, font: font, title: true) }
            // Anahtarlı liste: yeni mesaj eklenince ya da eskisi düşünce kalan balonlar yeniden yaratılmaz.
            ForEach(PhonePanelView.keys(parts.messages), id: \.self) { key in
                part(parts.messages[key.index], font: font, title: false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: parts.messages.map(\.box.top))
        .allowsHitTesting(false)
    }

    @ViewBuilder private func part(_ item: ScreenTranslation.Item, font: CGFloat, title: Bool) -> some View {
        if item.panel == .row, let row = item.listRow {
            PhoneListCard(item: item, row: row, font: font, size: size)
        } else {
            bubble(item, font: font, title: title)
        }
    }

    @ViewBuilder private func bubble(_ item: ScreenTranslation.Item, font: CGFloat, title: Bool) -> some View {
        let box = item.box
        let width = max(0, box.right - box.left) * size.width
        let listed = PhonePanelView.isListRow(item), note = item.panel == .note && !listed
        let points = title ? font * 0.8 : listed ? font * 0.92 : note ? font * 0.8 : font
        let weight: Font.Weight = title || item.look?.bold == true ? .bold : listed ? .regular : note ? .medium : .semibold
        let alignment: Alignment = item.panel == .mine ? .trailing : note ? .center : .leading
        Text(verbatim: item.translation)
            .font(.system(size: points, weight: weight))
            .foregroundStyle(PhonePanelView.color(item.style?.foreground, fallback: .white))
            .multilineTextAlignment(note ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, font * 0.6)
            .padding(.vertical, font * 0.3)
            .background(RoundedRectangle(cornerRadius: font * 0.75, style: .continuous)
                .fill(PhonePanelView.color(item.style?.background, fallback: .black).opacity(ScreenPhoneCard.bubbleOpacity)))
            .frame(maxWidth: width, alignment: alignment)
            .frame(width: width, alignment: alignment)
            .offset(x: box.left * size.width, y: box.top * size.height)
    }
}

/// Telefon listesinin tek kartı (`ScreenPhoneCard.ListRow`; TV app.js `placeListCard`, Windows PhoneBlocksCanvas, Android
/// PhonePanel aynı çizim): telefonun satır kartı renginde yuvarlak köşeli kart; solda oyundan kesilmiş avatar, yanında
/// kalın ad ve altında önizleme, sağda rozet; seçili satırda telefondaki renkte çerçeve. Kartın üstü adın İngilizcesiyle
/// aynı hizada, boyu kutusu kadar.
struct PhoneListCard: View {
    let item: ScreenTranslation.Item
    let row: ScreenPhoneCard.ListRow
    let font: CGFloat
    let size: CGSize

    var body: some View {
        let box = item.box
        let width = max(0, box.right - box.left) * size.width, height = max(0, box.bottom - box.top) * size.height
        let line = font / 0.85
        let avatar = line * ScreenPhoneCard.avatarLines
        let ink = PhonePanelView.color(item.style?.foreground, fallback: .black)
        HStack(alignment: .center, spacing: line * ScreenPhoneCard.avatarGap) {
            if let image = Self.image(row.avatar) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: avatar, height: avatar)
                    .clipShape(RoundedRectangle(cornerRadius: avatar * 0.3, style: .continuous))
            }
            VStack(alignment: .leading, spacing: line * 0.1) {
                if !row.name.isEmpty {
                    // Avatarsız kart (sohbet dışı ekran: makale başlığı) başlığı satır kırar; kişi adı tek satır.
                    Text(verbatim: row.name).font(.system(size: font, weight: .bold))
                        .lineLimit(row.avatar == nil ? nil : 1)
                        .fixedSize(horizontal: false, vertical: row.avatar == nil)
                }
                if !row.preview.isEmpty {
                    Text(verbatim: row.preview).font(.system(size: font * 0.92, weight: .regular))
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(0.8)
                }
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let badge = Self.image(row.badge) {
                Image(decorative: badge, scale: 1).resizable().interpolation(.medium)
                    .frame(width: line * 1.1, height: line * 1.1)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(line * ScreenPhoneCard.rowPadding)
        .frame(width: width, height: height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: line * 0.8, style: .continuous)
            .fill(PhonePanelView.color(item.style?.background, fallback: .white).opacity(ScreenPhoneCard.bubbleOpacity)))
        .overlay {
            if let selected = row.selected {
                RoundedRectangle(cornerRadius: line * 0.8, style: .continuous)
                    .stroke(PhonePanelView.color(selected, fallback: .blue), lineWidth: max(1.5, line * 0.12))
            }
        }
        .offset(x: box.left * size.width, y: box.top * size.height)
    }

    /// PNG data: adresinden resim.
    static func image(_ url: String?) -> CGImage? {
        guard let url, let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
#endif
