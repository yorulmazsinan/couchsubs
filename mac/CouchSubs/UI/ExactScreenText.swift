// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import ImageIO
import SwiftUI

/// Yerinde birebir çizim (Mac yayın penceresi ve iPhone önizlemesi ortak; TV placeExact, Windows ScreenTextCanvas ve Android
/// PhoneSubtitleActivity ile aynı yerleşim: `ScreenFit.exact`). Kip (`TextPaint.mode`):
/// - örtme: kareden ölçülen örtü kutusu tam sınırında, opak, köşesiz ve gölgesiz; zemin düz renk ya da degrade.
/// - yanına yazma: kutu yok; Türkçe özgün yazının yanında, özgün renk ve stilde, okunurluk için yumuşak konturla.
/// - ikiz: özgün kutu örtülmez; aynı zemin, kenar çizgisi, köşe, kuyruk ve kişi resmiyle aynı boyda ikiz kutu, genişliği ve
///   yüksekliği içeriğe göre (yazı küçülmez).
/// Özgün yazı dar ise (konuşma satırı değilse) gömülü dar yazı tipi (`EmbeddedFonts`, Barlow Condensed) ile çizilir.
/// Türkçe özgün renk, kalınlık, hiza ve satır aralığıyla. Grup aynı boyda, uzun çeviri boş tarafa uzar; yazı kesilmez.
/// `items`: `paint`'i olan öğeler.
struct ExactScreenText: View {
    let items: [ScreenTranslation.Item]
    let size: CGSize

    var body: some View {
        let shown = items.filter { $0.paint != nil }
        let inputs = shown.compactMap { ScreenFit.ExactInput($0, width: size.width, height: size.height) }
        // Ölçü çizimin yazı tipiyle; grupta kalın öğe varsa kalın ölçülür (geniş ölçü yazıyı hiç taşırmaz). Dar öğeler gömülü
        // dar yazı tipiyle ölçülür (hepsi dar değilse geniş ölçü).
        let bold = shown.contains { $0.look?.bold == true }
        let narrow = !shown.isEmpty && shown.allSatisfy(Self.condensed)
        let measure: (String, Double) -> Double = { text, fontSize in
            if narrow, let width = EmbeddedFonts.width(text, size: CGFloat(fontSize), bold: bold) { return Double(width) }
            return Double(ScreenFit.textWidth(text, size: CGFloat(fontSize), bold: bold))
        }
        let placed = ScreenFit.exact(inputs, measure: measure)
        // Etiket her öğenin kendi yazı tipiyle ölçülür (TV, Windows ve Android gibi): kalın başlık ya da dar olmayan öğe
        // öbür satırların etiketini genişletmez.
        let fitted = Self.hugged(shown, inputs, placed) { text, fontSize, k in
            let heavy = shown[k].look?.bold == true
            if Self.condensed(shown[k]), let width = EmbeddedFonts.width(text, size: CGFloat(fontSize), bold: heavy) {
                return Double(width)
            }
            return Double(ScreenFit.textWidth(text, size: CGFloat(fontSize), bold: heavy))
        }
        let twins = Self.twins(shown, placed, size: size)
        ZStack(alignment: .topLeading) {
            ForEach(Array(twins.enumerated()), id: \.offset) { _, twin in
                Self.panel(twin)
            }
            ForEach(Array(zip(shown.indices, fitted)), id: \.0) { index, place in
                Self.block(shown[index], place)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// İkiz panel (piksel): kutusu, köşe yarıçapı, zemini, kuyruğu ve kişi resmi.
    struct Twin {
        var frame: CGRect
        var radius: CGFloat
        var fill: Color
        var tail: String?
        /// `square`: görev kartının resmi köşeli kare (`TextPaint.portraitSquare`); değilse yuvarlak.
        var portrait: (image: CGImage, frame: CGRect, square: Bool)?
        /// Kenar çizgisi: rengi ve her yandaki kalınlığı (piksel; kutunun dışında).
        var edge: (color: Color, top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat)?
    }

    /// Menü etiketi yazıyı sarar (`TextPaint.label`; TV 0.9.124 ile aynı): genişliği en uzun satır kadar, özgüne yaslı kenarı
    /// yerinde; boş alan etiketle dolmaz.
    static func hugged(_ items: [ScreenTranslation.Item], _ inputs: [ScreenFit.ExactInput], _ placed: [ScreenFit.ExactPlacement],
                       measure: (String, Double, Int) -> Double) -> [ScreenFit.ExactPlacement] {
        placed.enumerated().map { k, place in
            guard k < items.count, k < inputs.count, let paint = items[k].paint, paint.mode == .beside, paint.label != nil,
                  let tight = place.lines.map({ measure($0, place.fontSize, k) }).max(), tight > 0, tight < place.width else { return place }
            var fitted = place
            switch inputs[k].align {
            case .right: fitted.left += place.width - tight
            case .center: fitted.left += (place.width - tight) / 2
            case .left: break
            }
            fitted.width = tight
            return fitted
        }
    }

    /// Özgün yazı dar ve konuşma satırı değil: gömülü dar yazı tipi (#1297: konuşma satırı hiç dar çizilmez).
    static func condensed(_ item: ScreenTranslation.Item) -> Bool {
        item.look?.condensed == true && !ScreenFit.isDialogue(item.translation, rows: item.paragraphs ? max(2, item.rows) : item.rows)
    }

    /// Aynı ikiz kutusunu paylaşan öğeler tek panel: genişliği içeriğe göre (en sağdaki yazı ya da resim + sol iç boşluk),
    /// yüksekliği ikizinki.
    static func twins(_ items: [ScreenTranslation.Item], _ placed: [ScreenFit.ExactPlacement], size: CGSize) -> [Twin] {
        var result: [Twin] = []
        var seen: [TextBox] = []
        for (i, item) in items.enumerated() where i < placed.count {
            guard let paint = item.paint, paint.mode == .twin, let box = paint.twin, !seen.contains(box) else { continue }
            seen.append(box)
            let members = items.indices.filter { $0 < placed.count && items[$0].paint?.twin == box }
            let left = box.left * size.width
            let pad = max(0, (members.map { placed[$0].left }.min() ?? left) - left)
            var right = members.map { placed[$0].left + placed[$0].width }.max() ?? box.right * size.width
            // Yükseklik de içeriğe göre: satırı kırılan Türkçe kutuyu aşağı uzatır, alt iç boşluk özgündeki kadar kalır.
            let bottom = members.map { placed[$0].top + placed[$0].height }.max() ?? box.bottom * size.height
            let spotBottom = members.compactMap { items[$0].paint?.spot?.bottom }.max().map { $0 * size.height } ?? bottom
            var portrait: (image: CGImage, frame: CGRect, square: Bool)?
            if let at = paint.portraitTwin, let image = image(paint.portraitImage) {
                let frame = CGRect(x: at.left * size.width, y: at.top * size.height, width: (at.right - at.left) * size.width,
                                   height: (at.bottom - at.top) * size.height)
                portrait = (image, frame, paint.portraitSquare)
                right = max(right, frame.maxX)
            }
            let top = box.top * size.height
            let frame = CGRect(x: left, y: top, width: max(1, right + pad - left, (box.right - box.left) * size.width),
                               height: max((box.bottom - box.top) * size.height, bottom + (box.bottom * size.height - spotBottom) - top))
            var edge: (color: Color, top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat)?
            if let line = paint.edge, let tone = color(line.color) {
                func px(_ v: Double) -> CGFloat { v > 0 ? max(1, (v * size.height).rounded()) : 0 }
                edge = (tone, px(line.top), px(line.right), px(line.bottom), px(line.left))
            }
            result.append(Twin(frame: frame, radius: paint.radius * size.height, fill: color(paint.background) ?? .white,
                               tail: paint.tail, portrait: portrait, edge: edge))
        }
        return result
    }

    @ViewBuilder
    static func panel(_ twin: Twin) -> some View {
        let r = twin.radius
        ZStack(alignment: .topLeading) {
            if let edge = twin.edge {
                // Kenar çizgisi: kutunun dışında, her yanda kendi kalınlığında (köşesiz ince şerit).
                edge.color.frame(width: twin.frame.width + edge.left + edge.right, height: twin.frame.height + edge.top + edge.bottom)
                    .offset(x: -edge.left, y: -edge.top)
            }
            Bubble(radius: r, tail: twin.tail)
                .fill(twin.fill)
                .frame(width: twin.frame.width, height: twin.frame.height)
            if let tail = twin.tail {
                Tail(right: tail == "right", size: r)
                    .fill(twin.fill)
                    .frame(width: twin.frame.width, height: twin.frame.height + 0.6 * r)
            }
            if let portrait = twin.portrait {
                let picture = Image(decorative: portrait.image, scale: 1)
                    .resizable()
                    .frame(width: portrait.frame.width, height: portrait.frame.height)
                let at = CGSize(width: portrait.frame.minX - twin.frame.minX, height: portrait.frame.minY - twin.frame.minY)
                // Görev kartının resmi köşeli kare (TV ile aynı), telefon bildiriminin kişi resmi yuvarlak.
                if portrait.square {
                    picture.offset(at)
                } else {
                    picture.clipShape(Ellipse()).offset(at)
                }
            }
        }
        .offset(x: twin.frame.minX, y: twin.frame.minY)
    }

    /// Yuvarlak köşeli panel; kuyruklu alt köşe köşeli (macOS 13 / iOS 16: UnevenRoundedRectangle yok).
    struct Bubble: Shape {
        let radius: CGFloat
        let tail: String?

        func path(in rect: CGRect) -> Path {
            let r = min(radius, rect.width / 2, rect.height / 2)
            let bl = tail == "left" ? 0 : r, br = tail == "right" ? 0 : r
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90),
                        endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
            if br > 0 {
                path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0),
                            endAngle: .degrees(90), clockwise: false)
            }
            path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
            if bl > 0 {
                path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90),
                            endAngle: .degrees(180), clockwise: false)
            }
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180),
                        endAngle: .degrees(270), clockwise: false)
            path.closeSubpath()
            return path
        }
    }

    /// Balonun kuyruğu: alt köşeden aşağı küçük üçgen.
    struct Tail: Shape {
        let right: Bool
        let size: CGFloat

        func path(in rect: CGRect) -> Path {
            let bottom = rect.maxY - 0.6 * size
            let x = right ? rect.maxX : rect.minX, inward: CGFloat = right ? -size : size
            var path = Path()
            path.move(to: CGPoint(x: x, y: bottom - 1))
            path.addLine(to: CGPoint(x: x + inward, y: bottom - 1))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    /// Menüde yanına yazılan Türkçenin etiketi (`TextPaint.label`, `MenuLayout`; TV 0.9.124 ile aynı): koyu, yarı saydam,
    /// yuvarlak köşeli; yazının çevresine `pad` kadar taşar, yerleşimi değiştirmez.
    struct LabelChip: View {
        let color: Color?
        /// Yanlara taşma; alta/üste ince pay (`padY`): alt alta satırların etiketleri birbirine değmez.
        let pad: CGFloat
        let padY: CGFloat

        var body: some View {
            if let color {
                RoundedRectangle(cornerRadius: max(2, pad * 0.8)).fill(color.opacity(0.86))
                    .padding(.horizontal, -pad).padding(.vertical, -padY)
            }
        }
    }

    @ViewBuilder
    static func block(_ item: ScreenTranslation.Item, _ place: ScreenFit.ExactPlacement) -> some View {
        let mode = item.paint?.mode ?? .cover
        let alignment: Alignment = switch mode == .beside ? besideAlign(item) : item.look?.align {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
        // Etiketli yanına yazmada (menü, "yanına yaz") yazı etikette açık renkle, kontursuz.
        let marked = mode == .beside ? color(item.paint?.label) : nil
        // Seçili (ters renkli: açık zemin, koyu ve zeminden belirgin biçimde ayrışan yazı) satırın etiketi de ters renkli
        // (TV `labelSelected` ile aynı).
        let selected = marked != nil && Self.selected(item.paint?.background, item.style?.foreground)
        let label = selected ? color(item.paint?.background) : marked
        let foreground = selected ? color(item.style?.foreground) ?? .black
            : label != nil ? labelInk(item.style?.foreground) : color(item.style?.foreground) ?? .white
        let halo = outline(item.style?.foreground)
        let haloed = mode == .beside && label == nil
        ZStack(alignment: .topLeading) {
            ForEach(Array(place.lines.enumerated()), id: \.offset) { k, text in
                Text(verbatim: text)
                    .font(font(item, size: place.fontSize))
                    .foregroundStyle(foreground)
                    .shadow(color: haloed ? halo : .clear, radius: haloed ? max(1, place.fontSize * 0.08) : 0)
                    .shadow(color: haloed ? halo : .clear, radius: 0, x: 0, y: haloed ? 1 : 0)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: place.width, height: place.rowHeight, alignment: alignment)
                    .offset(y: CGFloat(k) * place.lineHeight)
            }
        }
        .frame(width: place.width, height: place.height, alignment: .topLeading)
        .background(mode == .cover ? fill(item) : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom))
        .background(LabelChip(color: label, pad: max(2, (place.fontSize * 0.2).rounded()),
                              padY: max(1, (place.fontSize * 0.06).rounded())))
        .offset(x: place.left, y: place.top)
    }

    /// Seçili satır mı (TV `labelSelected` ile aynı eşikler): zemin açık, yazı koyu ve zeminden en az 80/255 koyu.
    static func selected(_ background: String?, _ foreground: String?) -> Bool {
        guard let background, let ground = SpeakerColors.rgb(background), let foreground, let ink = SpeakerColors.rgb(foreground)
        else { return false }
        let bright = 0.299 * ground.red + 0.587 * ground.green + 0.114 * ground.blue
        let dark = 0.299 * ink.red + 0.587 * ink.green + 0.114 * ink.blue
        return bright > 160.0 / 255 && dark <= 160.0 / 255 && bright - dark >= 80.0 / 255
    }

    /// Etiketteki yazı: özgün yazı açık renkse o renk (gri liste, sarı vurgu), koyuysa açık gri (TV `labelInk` ile aynı).
    static func labelInk(_ hex: String?) -> Color {
        guard let hex, let rgb = SpeakerColors.rgb(hex), 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue > 150.0 / 255 else {
            return Color(.sRGB, red: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF2 / 255.0)
        }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Çizimin yazı tipi: dar özgünde gömülü dar yazı tipi (yüklenemezse sistemin dar genişliği), değilse sistem.
    static func font(_ item: ScreenTranslation.Item, size: CGFloat) -> Font {
        let bold = item.look?.bold == true
        if condensed(item), let name = EmbeddedFonts.condensedName(bold: bold) { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: bold ? .bold : .regular).width(condensed(item) ? .condensed : .standard)
    }

    /// Yanına yazılan Türkçe özgüne yaslanır (ScreenFit.ExactInput ile aynı).
    static func besideAlign(_ item: ScreenTranslation.Item) -> TextLook.Align? {
        guard let paint = item.paint, let spot = paint.spot else { return item.look?.align }
        if spot.right <= paint.cover.left { return .right }
        if spot.left >= paint.cover.right { return .left }
        return item.look?.align
    }

    /// Yanına yazmada okunurluk konturu: açık yazıda koyu, koyu yazıda açık.
    static func outline(_ hex: String?) -> Color {
        guard let hex, let rgb = SpeakerColors.rgb(hex) else { return .black.opacity(0.85) }
        return 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue > 0.5 ? .black.opacity(0.85) : .white.opacity(0.85)
    }

    /// Zemin: düz renk ya da iki uçlu doğrusal degrade (sol→sağ ya da üst→alt).
    static func fill(_ item: ScreenTranslation.Item) -> LinearGradient {
        let first = color(item.paint?.background) ?? .black
        guard let paint = item.paint, let second = color(paint.background2), let direction = paint.direction else {
            return LinearGradient(colors: [first, first], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [first, second], startPoint: direction == .horizontal ? .leading : .top,
                              endPoint: direction == .horizontal ? .trailing : .bottom)
    }

    static func color(_ hex: String?) -> Color? {
        guard let hex, let rgb = SpeakerColors.rgb(hex) else { return nil }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// PNG data: adresinden görüntü.
    static func image(_ url: String?) -> CGImage? {
        guard let url, let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
