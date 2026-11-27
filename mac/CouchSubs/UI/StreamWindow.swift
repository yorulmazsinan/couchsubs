// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import Combine
import SwiftUI

/// "Yayın penceresi": şeffaflık tanımayan yayın programları (TikTok LIVE Studio, Streamlabs, OBS dışındakiler) için
/// düz renkli zeminde altyazı çizen sıradan bir pencere. Programda "Pencere yakalama" ile eklenir, zemin chroma key ile
/// silinir. Başlığı sabittir ki yakalama listesinde bulunsun. Saydam altyazı penceresinden (SubtitleOverlay.swift)
/// ayrıdır; satırlar aynı yığından gelir (bkz. AppModel+ComputerScreen.swift).
@MainActor
final class StreamWindowController: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var window: NSWindow?
    private var modelChanges: AnyCancellable?

    static let autosaveName = "CouchSubsStreamWindow"

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        modelChanges = model.$streamWindowOpen.removeDuplicates().sink { [weak self] open in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(open) } }
        }
    }

    private func show(_ open: Bool) {
        guard let model else { return }
        guard open else {
            window?.orderOut(nil)
            return
        }
        let window = self.window ?? makeWindow(model)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(_ model: AppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = Self.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Yakalanan görüntü 16:9 kalsın; yayın programında kaynak oranı bozulmaz.
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentMinSize = NSSize(width: 480, height: 270)
        window.contentView = NSHostingView(rootView: StreamWindowView().environmentObject(model))
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        self.window = window
        return window
    }

    /// Yayın programının pencere listesinde görünen ad; altyazıya göre değişmez (Türkçede "CouchSubs Yayın").
    static var title: String { String(localized: "CouchSubs Stream") }

    func windowWillClose(_ notification: Notification) {
        model?.streamWindowOpen = false
    }
}

/// Görüntü penceresinin altındaki denetim çubuğu (tuval 13): Ekranı Çevir, Örtsün (zemin tam koyu, İngilizce altyazı
/// görünmez), Çubuğu Gizle. Çubuk yayına da girer; gizlenince yalnız fare penceredeyken köşede "Çubuğu Göster" çıkar.
private struct StreamControlBar: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("streamBarHidden") private var hidden = false
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear.contentShape(Rectangle()).allowsHitTesting(false)
            if hidden {
                if hovering {
                    Button("Show the Bar") { hidden = false }
                        .buttonStyle(BarButton(fill: Color(red: 0.063, green: 0.063, blue: 0.078).opacity(0.6), height: 32))
                        .padding(16)
                        .transition(.opacity)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Translate the Screen") { model.translateScreen() }
                        .buttonStyle(BarButton(fill: .dsAmber, text: .dsOnAmber, weight: .semibold))
                        .disabled(!model.isRunning)
                    Button("Cover") {
                        model.settings.style.background = covers ? SubtitlePalette.darkness[1] : 100
                        model.sendTestSubtitle()
                    }
                    .buttonStyle(BarButton(fill: covers ? .dsSuccess : .white.opacity(0.12)))
                    Button("Hide the Bar") { hidden = true }
                        .buttonStyle(BarButton(fill: .white.opacity(0.12)))
                }
                .padding(6)
                .background(Color(red: 0.063, green: 0.063, blue: 0.078).opacity(0.7), in: Capsule(style: .circular))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(DS.animation(.medium, reduced: !model.settings.transitionAnimations), value: hidden)
        .animation(DS.animation(.short, reduced: !model.settings.transitionAnimations), value: hovering)
    }

    private var covers: Bool { model.settings.style.background >= 100 }

    private struct BarButton: ButtonStyle {
        var fill: Color
        var text: Color = .white
        var weight: Font.Weight = .medium
        var height: CGFloat = 36

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: height < 36 ? 12 : 13, weight: weight))
                .foregroundStyle(text)
                .padding(.horizontal, height < 36 ? 12 : 16)
                .frame(height: height)
                .background(fill, in: Capsule(style: .circular))
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

/// Pencerenin içeriği: düz zemin ve TV'deki altyazı kutusu (yazı boyu 1080 satırlık ekrana göre pencereye ölçeklenir).
struct StreamWindowView: View {
    @EnvironmentObject private var model: AppModel
    /// Altyazı satırlarının penceredeki yeri: ekran yazısı kutuları onunla çakışırsa kayar (altyazı yerinde kalır).
    @State private var subtitleFrame: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let scale = max(0.2, proxy.size.height / 1080)
            VStack(spacing: 14 * scale) {
                // Sürekli okunan ek alanların çevirisi saydam penceredeki gibi üstte, alanın yanına yaslı.
                VStack(spacing: 10 * scale) {
                    // Ekran yazıları (bloklu) aşağıda kendi yerlerinde çizilir.
                    ForEach(model.overlayRegions.filter { $0.items == nil }) { regionBox($0, scale: scale) }
                }
                .padding(.top, 16 * scale)
                Spacer(minLength: 0)
                VStack(spacing: 14 * scale) {
                    // "Ekranı çevir" çevirileri aşağıda kendi yerlerinde: yığındaki düz listeleri gösterilmez.
                    ForEach(Self.lines(model.overlayLines, without: model.overlayScreenItems.isEmpty ? nil : model.overlayScreenText)) {
                        line(line: $0, scale: scale)
                    }
                }
                .background(GeometryReader { lines in
                    Color.clear.preference(key: SubtitleFrameKey.self,
                                           value: model.overlayLines.isEmpty ? nil : lines.frame(in: .named("stream")))
                })
            }
            .padding(.horizontal, 24 * scale)
            .padding(.bottom, proxy.size.height * 0.07)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background {
                // Yerinde Türkçe çizim: telefonun Türkçe ikizi çapayla telefonun üstünde (yayın penceresi karenin kendisidir).
                if model.drawsPhoneInPlace {
                    PhoneTwinLayer(feed: model.phoneAnchorFeed)
                } else if !model.overlayPhoneItems.isEmpty { GamePhoneBlocks(items: model.overlayPhoneItems) }
                // Aynı yazıyı çizen iki kutudan yalnız biri: "Ekranı çevir" otomatik ekran yazısının üstüne geçer (#827).
                let screenText = model.layeredItems
                if !screenText.isEmpty { ScreenTextBlocks(items: screenText, avoiding: subtitleFrame) }
            }
        }
        .coordinateSpace(name: "stream")
        .onPreferenceChange(SubtitleFrameKey.self) { subtitleFrame = $0 }
        .background(Self.color(model.streamBackground))
        .overlay(alignment: .bottom) { StreamControlBar() }
    }

    /// Yığının satırları; `screen` verilirse o metinli ("Ekranı çevir" listesi) satır atlanır.
    static func lines(_ lines: [SubtitleStack.Line], without screen: String?) -> [SubtitleStack.Line] {
        guard let screen, !screen.isEmpty else { return lines }
        return lines.filter { $0.text != screen }
    }

    static func color(_ background: StreamBackground) -> Color {
        let rgb = background.rgb
        return Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }

    /// Ek alanın çevirisi: altyazıdan küçük, tam koyu kutu (düz zeminde chroma key bozulmasın).
    private func regionBox(_ region: OverlayRegion, scale: CGFloat) -> some View {
        let style = model.settings.style
        let size = max(12, CGFloat(style.fontSize) * scale * 0.55)
        let alignment: Alignment = switch region.side {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(verbatim: region.text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(model.settings.setTextApart ? .white : SubtitleOverlayView.color(style.textColor))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6 * scale)
            .padding(.horizontal, 14 * scale)
            // Ayrık gösterim: altyazı kutusundan farklı, zeminsiz ve koyu gölgeli.
            .background(Color.black.opacity(model.settings.setTextApart ? 0 : 1), in: RoundedRectangle(cornerRadius: 8 * scale))
            .shadow(color: .black.opacity(model.settings.setTextApart ? 1 : 0), radius: 3 * scale)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func line(line: SubtitleStack.Line, scale: CGFloat) -> some View {
        let style = model.settings.style
        let current = line.role == .current
        // Uzun çeviri en çok 3 satıra dengeli bölünür; 3 satıra sığmazsa yazı biraz küçülür (bkz. SubtitleWrap).
        let wrapped = line.wrapped
        let size = CGFloat(style.fontSize) * scale * (current ? 1 : 0.8) * CGFloat(wrapped.scale)
        // Düz zeminde yarı saydam kutu zeminle karışır, chroma key'i bozar; kutu tam koyu (ya da hiç yok).
        let alpha = StreamBackground.boxOpacity(background: style.background)
        let opacity: Double = switch line.role {
        case .current: 1
        case .previous: 0.6
        case .older: 0.45
        }
        let weight: Font.Weight = style.bold ? .bold : .semibold
        let alignment: TextAlignment = line.paragraphs ? .leading : .center
        let vertical: CGFloat = (current ? 10 : 6) * scale
        let horizontal: CGFloat = (current ? 26 : 20) * scale
        let corner: CGFloat = 10 * scale
        // Soluk üst satırlar kutunun içinde yazı renginden soldurulur; pencere zeminiyle karışan saydamlık olmaz.
        let textOpacity: Double = alpha > 0 ? opacity : 1
        let shadowRadius: CGFloat = alpha > 0 ? 0 : 2 * scale
        let shown: Double = line.fading ? 0 : 1
        let colored = model.settings.speakerColors && !line.paragraphs
        let text = SubtitleOverlayView.subtitleText(wrapped.text, colored: colored,
                                                    base: SubtitleOverlayView.textColor(style), book: model.speakerBook,
                                                    nameOnly: style.nameOnly, wholeLine: style.nameColorMode == .line)
            .font(.system(size: size, weight: weight))
        return text
            .opacity(textOpacity)
            .multilineTextAlignment(alignment)
            .lineSpacing(size * 0.3)
            .shadow(color: .black, radius: shadowRadius, x: 0, y: shadowRadius)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, vertical)
            .padding(.horizontal, horizontal)
            .background(SubtitleOverlayView.boxColor(style).opacity(alpha), in: RoundedRectangle(cornerRadius: corner))
            .opacity(shown)
            .animation(.linear(duration: SubtitleStack.previousFade), value: line.fading)
    }
}

/// Yayın katmanının koordinatları telefondaki kaynak kutularıyla aynı, sol üst köşeye göre 0…1 aralığındadır.
/// Yanda Panel'de telefonun mesajları sohbet panelinde (`PhonePanelView`; TV ve Windows ile aynı çizim), panel dışındaki
/// yazılar (ana ekran) kendi yerinde. `panelFont` verilirse (saydam pencere: alan oyun karesi değil, kullanıcının seçtiği
/// altyazı yeri) hizalı panelin balonları alanın telefon tarafındaki kenarında alt alta dizilir (`ScreenPhoneCard.stacked`),
/// yazısı altyazı boyundan gelir.
struct GamePhoneBlocks: View {
    let items: [ScreenTranslation.Item]
    var panelFont: CGFloat? = nil

    var body: some View {
        let panel = ScreenPhoneCard.panel(items)
        let items = panel?.outside ?? items
        GeometryReader { proxy in
            if let panel {
                if let font = panelFont {
                    // Saydam pencere: hizalı panelin kartsız balonları alanın telefon tarafındaki kenarında, alt alta.
                    PhonePanelAligned(ScreenPhoneCard.stacked(panel, width: proxy.size.width, height: proxy.size.height,
                                                              font: font),
                                      size: proxy.size, minFont: max(ScreenPhoneCard.stackedMinFont, font))
                        .transition(.opacity)
                } else {
                    PhonePanelInFrame(panel, size: proxy.size)
                }
            }
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let box = item.box
                let width = max(0, box.right - box.left) * proxy.size.width
                let height = max(0, box.bottom - box.top) * proxy.size.height
                Text(verbatim: item.translation)
                    .font(.system(size: max(1, item.lineHeight * proxy.size.height * 0.85), weight: .semibold))
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(Self.color(item.style?.foreground, fallback: .white))
                    .frame(width: width, height: height, alignment: .leading)
                    .background(Self.color(item.style?.background, fallback: .black))
                    .clipped()
                    .position(x: (box.left + box.right) * 0.5 * proxy.size.width,
                              y: (box.top + box.bottom) * 0.5 * proxy.size.height)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        // Hizalı telefon paneli telefon görününce solarak gelir, kalkınca solarak kaybolur (TV ile aynı, 250 ms).
        .animation(.easeOut(duration: 0.25), value: panel == nil)
    }

    private static func color(_ hex: String?, fallback: Color) -> Color {
        guard let hex, let (r, g, b) = DesignTokens.rgb(hex) else { return fallback }
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}

/// Kendiliğinden bulunan ekran yazısının çevirisi özgün yazının stilinde: zemin ve yazı rengi, kalınlık, dar aile, hiza
/// (`TextLook`; BÜYÜK HARF çeviriye zaten uygulanmış gelir). Kutu her zeminde tam opak: özgün yazı arasından görünmez
/// (#827; "Örtsün" kutusu gibi).
enum StyledScreenText {
    static func label(_ item: ScreenTranslation.Item, text: String? = nil, size: CGFloat) -> some View {
        let look = item.look
        let alignment: TextAlignment = switch look?.align {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
        return Text(verbatim: text ?? item.translation)
            .font(.system(size: size, weight: look?.bold == true ? .bold : .semibold).width(look?.condensed == true ? .condensed : .standard))
            .foregroundStyle(color(item.style?.foreground, fallback: .white))
            .multilineTextAlignment(alignment)
    }

    static func background(_ item: ScreenTranslation.Item) -> Color {
        color(item.style?.background, fallback: .black)
    }

    static func frameAlignment(_ item: ScreenTranslation.Item) -> Alignment {
        switch item.look?.align {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    static func color(_ hex: String?, fallback: Color) -> Color {
        guard let hex, let (r, g, b) = SpeakerColors.rgb(hex) else { return fallback }
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}

/// Ekran yazısı blokları oyun karesindeki kendi yerlerinde (yayın penceresi 16:9 karenin kendisidir), TV ile aynı
/// yerleşimle (`ScreenFit.lines`): sığmayan yazı küçülür, satır kırılıp aşağı uzar; yana hiç genişlemez.
struct ScreenTextBlocks: View {
    let items: [ScreenTranslation.Item]
    /// Altyazı satırlarının yeri (pencere koordinatında); ekran yazısı kutusu onunla çakışmaz.
    var avoiding: CGRect? = nil

    /// Kutunun üst kenarı: altyazıyla çakışıyorsa yalnız gerektiği kadar (en az %0,6 ekran yüksekliği boşlukla) yukarı ya
    /// da aşağı kayar, hangisi daha azsa; altyazının yeri değişmez (TV #673 ile aynı kural). Sığmazsa yukarı yaslanır.
    static func top(_ rect: CGRect, avoiding: CGRect?, height: CGFloat) -> CGFloat {
        guard let avoiding, rect.intersects(avoiding.insetBy(dx: 0, dy: -height * 0.006)) else { return rect.minY }
        let gap = height * 0.006
        let up = avoiding.minY - gap - rect.height
        let down = avoiding.maxY + gap
        let upFits = up >= 0, downFits = down + rect.height <= height
        if upFits && (!downFits || rect.minY - up <= down - rect.minY) { return up }
        if downFits { return down }
        return max(0, up)
    }

    var body: some View {
        // "Ekranı çevir"in GTA 6 telefon paneli de otomatik telefon okumasındaki gibi akışla çizilir (`PhonePanelView`).
        let panel = ScreenPhoneCard.panel(items)
        let blocks = panel?.outside ?? items
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let panel { PhonePanelInFrame(panel, size: proxy.size) }
                // Kareden ölçülmüş öğeler yerinde birebir (TV, Windows, iPhone, Android ile aynı: `ScreenFit.exact`).
                ExactScreenText(items: blocks.filter { $0.paint != nil }, size: proxy.size)
                ForEach(blocks.indices.filter { blocks[$0].paint == nil }, id: \.self) { i in
                    block(blocks[i], size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: panel == nil)
    }

    /// Bir blok, TV ile aynı yerleşimle (`ScreenFit.lines`): yazı boyu satır yüksekliğinin 0,95'i; yazının alanı özgün kutu
    /// ve yana hiç genişlemez. Türkçe uzunsa önce yalnız yatayda sıkıştırılır, sonra yazı küçülür, sonra satır kırılıp kutu
    /// aşağı uzar. Kenar payı yalnız bilgisayarın verdiği alanda (`room`): yandaki tuş simgesinin üstüne binmez (#1203).
    @ViewBuilder
    private func block(_ item: ScreenTranslation.Item, size: CGSize) -> some View {
        let line = max(1, item.lineHeight * size.height)
        let baseSize = line * 0.95
        let pad = line * 0.15
        let boxHeight = max(0, item.box.bottom - item.box.top) * size.height
        let bold = item.look?.bold == true
        let left = item.box.left * size.width, width = max(1, item.box.right - item.box.left) * size.width
        let fit = ScreenFit.lines(item.translation, width: width, rows: item.rows,
                                  floor: ScreenFit.floor(fontSize: baseSize, screenHeight: size.height)) {
            ScreenFit.textWidth($0, size: baseSize, bold: bold)
        }
        let fontSize = baseSize * fit.scale
        let side = ScreenFit.pads(left: left, width: width,
                                  room: item.room.map { ($0.left * size.width, $0.right * size.width) }, pad: pad)
        let pitch = max(boxHeight / CGFloat(max(1, fit.lines.count)), fontSize * 1.05)
        let alignment = StyledScreenText.frameAlignment(item)
        let anchor: UnitPoint = switch item.look?.align {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
        let top = Self.top(CGRect(x: left - side.left, y: item.box.top * size.height - pad,
                                  width: width + side.left + side.right, height: boxHeight + 2 * pad),
                           avoiding: avoiding, height: size.height)
        VStack(alignment: alignment.horizontal, spacing: 0) {
            ForEach(Array(fit.lines.enumerated()), id: \.offset) { _, text in
                StyledScreenText.label(item, text: text, size: fontSize)
                    .lineLimit(1)
                    .fixedSize()
                    .scaleEffect(x: fit.squeeze, y: 1, anchor: anchor)
                    .frame(width: width, height: pitch, alignment: alignment)
            }
        }
        .frame(width: width, alignment: alignment)
        .frame(minHeight: boxHeight, alignment: .center)
        .padding(.vertical, pad)
        .padding(.leading, side.left)
        .padding(.trailing, side.right)
        .background(StyledScreenText.background(item))
        .offset(x: left - side.left, y: top)
    }
}

/// Yayın penceresinde altyazı satırlarının yeri.
private struct SubtitleFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
