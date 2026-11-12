// SPDX-License-Identifier: AGPL-3.0-only
// Mobil tasarım sistemi: TASARIM-MOBIL.md'deki tokenlar ve bileşenler (Android ile ortak belge; onaylı tuval
// "CouchSubs Mobil ve Windows Tasarımı", AI Design Check ile sadeleştirildi). Köşe ve yazı ölçeği design/tokens.json ile
// aynıdır (16/12/8/6, 13/15/17/22/28). Düz yüzey: parıltı, degrade, hale yok. Ekranlar sabit değer kullanmaz.

import SwiftUI
import UIKit

enum Mobile {
    enum Space {
        static let screen: CGFloat = 20
        static let gap: CGFloat = 12
        static let tile: CGFloat = 16
        static let inline: CGFloat = 8
        static let hair: CGFloat = 4
    }

    enum Radius {
        static let tile: CGFloat = 16
        static let control: CGFloat = 12
        static let inner: CGFloat = 8
        static let tag: CGFloat = 6
        static let pill: CGFloat = 999
    }

    enum Control {
        static let button: CGFloat = 52
        static let buttonSmall: CGFloat = 44
        static let icon: CGFloat = 44
        static let field: CGFloat = 52
        static let row: CGFloat = 52
        static let tag: CGFloat = 24
    }

    /// Basamaklar: deep → bg → surface → surface2 → raised; katmanlar %8 ince çizgiyle ayrılır.
    enum Palette {
        static let deep = Color(hex: 0x0E0F11)
        static let bg = Color(hex: 0x141518)
        static let surface = Color(hex: 0x1C1E23)
        static let surface2 = Color(hex: 0x25282F)
        /// İnce çizgi (%8): karo ve alan çerçevesi, ayraç.
        static let border = Color(.sRGB, red: 0xF3 / 255, green: 0xEE / 255, blue: 0xE4 / 255, opacity: 0.08)
        /// `raised`: seçili segment, kapalı anahtar, boş adım, sayfa noktası.
        static let borderStrong = Color(hex: 0x30333A)
        static let text = Color(hex: 0xF3EEE4)
        static let secondary = Color(hex: 0xA9A59C)
        static let tertiary = Color(hex: 0x94908A)
        static let accent = Color(hex: 0xF5B83D)
        static let accentHi = Color(hex: 0xFFCF6B)
        static let onAccent = Color(hex: 0x17181B)
        static let pro = Color(hex: 0xA78BFA)
        static let proSoft = Color(hex: 0x322F45)
        static let success = Color(hex: 0x62C990)
        static let warning = Color(hex: 0xF2A55A)
        static let danger = Color(hex: 0xF28B82)
        static let dangerSoft = Color(hex: 0x2F2325)
    }

    /// Yalnız bu beş arayüz boyu (altyazı içeriği hariç).
    enum TypeScale {
        static let display = Font.system(size: 28, weight: .semibold)
        static let title = Font.system(size: 22, weight: .semibold).monospacedDigit()
        static let headline = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 15, weight: .regular)
        static let caption = Font.system(size: 13, weight: .medium)
        /// Altyazı içeriği: dikeyde canlı satır 28, yatay altyazı ekranında 36; kullanıcı %80–%160 ölçekler.
        static func subtitle(landscape: Bool, scale: Double) -> Font {
            .system(size: (landscape ? 36 : 28) * min(1.6, max(0.8, scale)), weight: .semibold)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Düğmeler (§5)

struct MobileButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Mobile.TypeScale.headline)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(foreground)
            .frame(maxWidth: kind == .ghost ? nil : .infinity, minHeight: kind == .ghost ? Mobile.Control.buttonSmall : Mobile.Control.button)
            .padding(.horizontal, kind == .ghost ? Mobile.Space.gap : Mobile.Space.screen)
            .background { background(pressed: pressed) }
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Mobile.Radius.control).strokeBorder(Mobile.Palette.border)
                }
            }
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Mobile.Radius.control))
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Mobile.Palette.onAccent
        case .secondary: Mobile.Palette.text
        case .ghost: Mobile.Palette.accent
        case .destructive: Mobile.Palette.danger
        }
    }

    /// Düz dolgu, gölge yok; basılı birincil düğme biraz açık sarı.
    @ViewBuilder private func background(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Mobile.Radius.control)
        switch kind {
        case .primary: shape.fill(pressed ? Mobile.Palette.accentHi : Mobile.Palette.accent)
        case .secondary: shape.fill(Mobile.Palette.surface2)
        case .ghost: Color.clear
        case .destructive: shape.fill(Mobile.Palette.dangerSoft)
        }
    }
}

extension ButtonStyle where Self == MobileButtonStyle {
    static var mobilePrimary: MobileButtonStyle { MobileButtonStyle(kind: .primary) }
    static var mobileSecondary: MobileButtonStyle { MobileButtonStyle(kind: .secondary) }
    static var mobileGhost: MobileButtonStyle { MobileButtonStyle(kind: .ghost) }
    static var mobileDestructive: MobileButtonStyle { MobileButtonStyle(kind: .destructive) }
}

/// 44×44 simge düğmesi (ayarlar, kapat, geri).
struct IconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Mobile.Palette.text)
                .frame(width: Mobile.Control.icon, height: Mobile.Control.icon)
                .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Mobile.Radius.control).strokeBorder(Mobile.Palette.border))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Profil (Cihazlarım) düğmesi: simge düğmesiyle aynı görünüm; baş harf varsa simgenin yerine.
struct AvatarButton: View {
    let initials: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if initials.isEmpty {
                    Image(systemName: "person").font(.system(size: 17, weight: .semibold))
                } else {
                    Text(verbatim: initials).font(Mobile.TypeScale.caption.weight(.semibold))
                }
            }
            .foregroundStyle(Mobile.Palette.text)
            .frame(width: Mobile.Control.icon, height: Mobile.Control.icon)
            .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Mobile.Radius.control).strokeBorder(Mobile.Palette.border))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Profile"))
    }
}

// MARK: - Karolar (§6, §7)

/// Karonun vurgusu: seçili (1 pt amber çerçeve). Parıltı, degrade ve renkli çerçeve yok.
enum TileEmphasis { case none, selected }

/// Karo: düz yüzey, %8 ince çerçeve, köşe 16.
struct Tile<Content: View>: View {
    var emphasis: TileEmphasis = .none
    var spacing: CGFloat = Mobile.Space.inline
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Mobile.Radius.tile, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Mobile.Space.tile)
            .background(Mobile.Palette.surface, in: shape)
            .overlay(shape.strokeBorder(emphasis == .selected ? Mobile.Palette.accent : Mobile.Palette.border))
    }
}

/// Değer karosu: üstte etiket satırı (simge + etiket [+ durum noktası]), altında `title` değer. Kare zorlanmaz.
struct StatTile: View {
    let symbol: String
    var tint: MobileTileIcon.Tint = .neutral
    let label: LocalizedStringKey
    let value: String
    var live = false

    var body: some View {
        Tile {
            HStack(spacing: Mobile.Space.inline) {
                MobileTileIcon(symbol: symbol, tint: tint)
                Text(label).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                Spacer(minLength: 0)
                if live { MobileLiveDot(pulses: false) }
            }
            Text(verbatim: value).font(Mobile.TypeScale.title).lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

/// Bilgi karosu: üstte simge + `headline` başlık, altında `caption` açıklama (simge kutusu yok).
struct InfoTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    var emphasis: TileEmphasis = .none

    var body: some View {
        Tile(emphasis: emphasis) {
            HStack(spacing: Mobile.Space.inline) {
                MobileTileIcon(symbol: symbol)
                Text(title).font(Mobile.TypeScale.headline).fixedSize(horizontal: false, vertical: true)
            }
            Text(caption).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Karodaki simge: kutusuz, 18 pt, ikincil renkte; paket simgesi mor, hata kırmızı.
struct MobileTileIcon: View {
    enum Tint { case neutral, ok, accent, pro, danger }
    let symbol: String
    var tint: Tint = .neutral

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tint {
        case .neutral, .ok, .accent: Mobile.Palette.secondary
        case .pro: Mobile.Palette.pro
        case .danger: Mobile.Palette.danger
        }
    }
}

/// Oyun kısaltması rozeti ("GTA").
struct GameMonogram: View {
    let code: String
    var size: CGFloat = 44

    var body: some View {
        Text(verbatim: code)
            .font(Mobile.TypeScale.caption.weight(.semibold))
            .foregroundStyle(Mobile.Palette.text)
            .frame(width: size, height: size)
            .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.inner))
    }
}

/// Etiket ya da durum. Etiket: 24 yükseklik, köşe 6, nötr zemin (paket için mor yazı ve `proSoft`).
/// Durum (`dot`): 8 pt nokta ve kelime, zeminsiz; `live` ise nokta atar (yalnız canlı çeviride).
struct MobilePill: View {
    enum Kind { case neutral, ok, accent, pro }
    let text: String
    var kind: Kind = .neutral
    var dot = false
    var live = false
    var compact = false

    var body: some View {
        if dot || live {
            HStack(spacing: Mobile.Space.inline) {
                MobileLiveDot(pulses: live)
                Text(verbatim: text).font(Mobile.TypeScale.caption).monospacedDigit().lineLimit(1)
            }
            .foregroundStyle(Mobile.Palette.text)
        } else {
            Text(verbatim: text)
                .font(Mobile.TypeScale.caption)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(kind == .pro ? Mobile.Palette.pro : Mobile.Palette.secondary)
                .padding(.horizontal, Mobile.Space.inline)
                .frame(height: Mobile.Control.tag)
                .background(kind == .pro ? Mobile.Palette.proSoft : Mobile.Palette.surface2,
                            in: RoundedRectangle(cornerRadius: Mobile.Radius.tag))
        }
    }
}

/// Durum noktası: 8 pt yeşil. `pulses` ise 2 sn'de bir genişleyip sönen halka (azaltılmış harekette sabit).
struct MobileLiveDot: View {
    var color: Color = Mobile.Palette.success
    var pulses = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulses && !reduceMotion {
                    Circle()
                        .stroke(color, lineWidth: 2)
                        .frame(width: 16, height: 16)
                        .scaleEffect(pulse ? 1.2 : 0.5)
                        .opacity(pulse ? 0 : 0.7)
                }
            }
            .onAppear {
                guard pulses, !reduceMotion else { return }
                // ai-design-check-ignore-next-line pulse-for-live-only -- yalnız canlı çeviride atar; azaltılmış harekette durur
                withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

/// Sayfa göstergesi (karşılama, tur).
struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: Mobile.Space.inline) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Mobile.Palette.text : Mobile.Palette.borderStrong)
                    .frame(width: index == current ? 24 : 8, height: 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityHidden(true)
    }
}

/// Segmentli seçim (çeviri motoru): seçili öğe `raised` zemin ve yarı kalın; çerçeve ve parıltı yok.
struct SegmentedTabs<Value: Hashable>: View {
    let options: KeyValuePairs<Value, LocalizedStringKey>
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: Mobile.Space.hair) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.key == selection
                Button { selection = option.key } label: {
                    Text(option.value)
                        .font(Mobile.TypeScale.body.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Mobile.Palette.text : Mobile.Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Mobile.Radius.inner).fill(Mobile.Palette.borderStrong)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .selectionFeedback(trigger: selected)
            }
        }
        .padding(Mobile.Space.hair)
        .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.control))
    }
}

/// 52'lik giriş alanı.
struct MobileFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(Mobile.TypeScale.headline.weight(.regular))
            .foregroundStyle(Mobile.Palette.text)
            .padding(.horizontal, Mobile.Space.tile)
            .frame(minHeight: Mobile.Control.field)
            .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Mobile.Radius.control).strokeBorder(Mobile.Palette.border))
    }
}

/// Geniş karonun içindeki 52'lik liste satırı.
struct ListRow<Trailing: View>: View {
    let symbol: String
    var tint: MobileTileIcon.Tint = .neutral
    let title: LocalizedStringKey
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Mobile.Space.gap) {
            MobileTileIcon(symbol: symbol, tint: tint)
            Text(title).font(Mobile.TypeScale.headline).foregroundStyle(Mobile.Palette.text)
            Spacer(minLength: Mobile.Space.inline)
            if let detail { Text(verbatim: detail).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary) }
            trailing
        }
        .frame(minHeight: Mobile.Control.row)
        .contentShape(Rectangle())
    }
}

extension ListRow where Trailing == AnyView {
    /// Gidilecek bir ekranı olan satır (sağda ok).
    init(symbol: String, tint: MobileTileIcon.Tint = .neutral, title: LocalizedStringKey, detail: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail) {
            AnyView(Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Mobile.Palette.tertiary))
        }
    }
}

/// Satırlar arası 1 px ayraç.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Mobile.Palette.border).frame(height: 1) }
}

// MARK: - Ekran iskeleti

/// Ekran zemini: düz `bg` (hale ve ışık yok).
struct MobileBackground: View {
    var body: some View {
        Mobile.Palette.bg.ignoresSafeArea()
    }
}

/// Ekran yapısı: güvenli alan + 20 → üst satır → 12 → içerik (12 aralıkla, kayar) → alt düğme bölgesi → 20.
struct MobileScreen<Header: View, Content: View, Bottom: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Mobile.Space.screen)
                .padding(.top, Mobile.Space.inline)
            ScrollView {
                VStack(alignment: .leading, spacing: Mobile.Space.gap) { content }
                    .padding(.horizontal, Mobile.Space.screen)
                    .padding(.top, Mobile.Space.gap)
                    .padding(.bottom, Mobile.Space.screen)
            }
            .scrollIndicators(.hidden)
            VStack(spacing: Mobile.Space.gap) { bottom }
                .padding(.horizontal, Mobile.Space.screen)
                .padding(.bottom, Mobile.Space.screen)
        }
        .foregroundStyle(Mobile.Palette.text)
        .background(MobileBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Başlık bloğu: ekran başına bir `display` başlık + açıklama.
struct ScreenTitle: View {
    var caption: LocalizedStringKey?
    let title: LocalizedStringKey
    var message: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.hair) {
            if let caption { Text(caption).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary) }
            Text(title).font(Mobile.TypeScale.display).fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Alt sayfaların üst satırı: geri düğmesi ve `title` boyunda başlık.
struct BackHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: Mobile.Space.gap) {
            IconButton(symbol: "chevron.left", label: "Back") { dismiss() }
            Text(title).font(Mobile.TypeScale.title)
            Spacer()
            trailing
        }
        .frame(height: Mobile.Control.icon)
    }
}

extension BackHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey) { self.init(title: title) { EmptyView() } }
}

/// Hata ya da uyarı satırı.
struct MobileNote: View {
    let text: String
    var tone: Color = Mobile.Palette.warning

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(Mobile.TypeScale.caption)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Mobil ekran zemini.
    func mobileScreen() -> some View { background(MobileBackground()) }
}

extension View {
    /// Alttan açılan sayfanın zemini. `presentationBackground` iOS 16.4'te geldi; öncesinde içerik zemini kenara kadar
    /// boyanır (görünüm aynı).
    @ViewBuilder func sheetBackground(_ color: Color) -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(color)
        } else {
            background(color.ignoresSafeArea())
        }
    }

    /// Küçük bilgi sayfası içeriği kadar açılır (`.medium`/`.large`'daki boş alan olmaz); üstte tutamaç görünür.
    /// İçerik yüksekliği ölçülür, değişince (ör. bir alan gizlenince) sayfa da uyar.
    func fittedSheet() -> some View { modifier(FittedSheet()) }

    /// Seçim değişince hafif dokunsal geri bildirim. `sensoryFeedback` iOS 17'de geldi; iOS 16'da UIKit'in üreteciyle
    /// (yalnız seçilen düğmede, bir kez).
    @ViewBuilder func selectionFeedback(trigger selected: Bool) -> some View {
        if #available(iOS 17, *) {
            sensoryFeedback(.selection, trigger: selected)
        } else {
            onChange(of: selected) { now in
                if now { UISelectionFeedbackGenerator().selectionChanged() }
            }
        }
    }
}

private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Özel yükseklik alttaki güvenli alanı içermez; ölçülen içerik yüksekliği doğrudan kullanılır.
private struct FittedSheet: ViewModifier {
    @State private var height: CGFloat = 320

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(SheetHeightKey.self) { value in
                if value > 0 { height = value.rounded(.up) }
            }
            .presentationDetents([.height(height)])
            .presentationDragIndicator(.visible)
    }
}

// MARK: - Bento ızgara (§6)

private struct BentoWideKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Karo iki sütunu kaplar (geniş/kahraman karo).
    func bentoWide() -> some View { layoutValue(key: BentoWideKey.self, value: true) }
}

/// İki sütunlu bento ızgara: aralık 12; `bentoWide()` karolar tam satır. Bir satırdaki karoların yüksekliği eşittir.
struct BentoGrid: Layout {
    var spacing: CGFloat = Mobile.Space.gap

    private func rows(_ subviews: Subviews) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        for index in subviews.indices {
            if subviews[index][BentoWideKey.self] {
                if !current.isEmpty { rows.append(current); current = [] }
                rows.append([index])
            } else {
                current.append(index)
                if current.count == 2 { rows.append(current); current = [] }
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private func heights(_ rows: [[Int]], width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let column = (width - spacing) / 2
        return rows.map { row in
            let cellWidth = row.count == 1 && subviews[row[0]][BentoWideKey.self] ? width : column
            return row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 350
        let rowHeights = heights(rows(subviews), width: width, subviews: subviews)
        let total = rowHeights.reduce(0, +) + spacing * CGFloat(max(0, rowHeights.count - 1))
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let allRows = rows(subviews)
        let rowHeights = heights(allRows, width: bounds.width, subviews: subviews)
        let column = (bounds.width - spacing) / 2
        var y = bounds.minY
        for (row, height) in zip(allRows, rowHeights) {
            for (position, index) in row.enumerated() {
                let wide = subviews[index][BentoWideKey.self]
                let width = wide ? bounds.width : column
                let x = bounds.minX + (wide ? 0 : CGFloat(position) * (column + spacing))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: height))
            }
            y += height + spacing
        }
    }
}
