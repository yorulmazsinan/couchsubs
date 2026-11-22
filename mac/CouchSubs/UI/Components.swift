// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// Ortak bileşenler. Ölçü ve renkler Theme'den (design/tokens.json) gelir; ekranlar sabit değer kullanmaz.
// Bileşenlerin tarifi docs/TASARIM.md'de; Windows sürümü aynı bileşenleri aynı adlarla kurar.

/// Mac'in yeni arayüzü (design/yeni-arayuz) içinde true: eski kartlar yeni sayfalara gömülünce aynı dilde çizilir
/// (düğme, karo, alan, ipucu). iPhone bu değeri hiç vermez; görünümü değişmez.
private struct CSNewLookKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var csNewLook: Bool {
        get { self[CSNewLookKey.self] }
        set { self[CSNewLookKey.self] = newValue }
    }
}

/// Uygulamanın logosu (kanepe + altyazı).
struct LogoView: View {
    var size: CGFloat = 40

    var body: some View {
        // Simge dosyası macOS ızgarasına göre kenar boşluğu içerir (1024'te 824'lük kare); uygulama içinde kırpılır.
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1024 / 824, height: size * 1024 / 824)
            .frame(width: size, height: size)
            .clipped()
            // Koyu temada logonun kenarı zeminden ayrılsın.
            .overlay(RoundedRectangle(cornerRadius: size * 186 / 824, style: .continuous).strokeBorder(Color.csBorder))
            .accessibilityHidden(true)
    }
}

/// Düğme türleri: birincil (düz sarı), ikincil (yüzey-2, çerçeveli), tehlikeli (kırmızı tonlu, çerçevesiz), hayalet (yalnız yazı).
/// Gölge ve parıltı yok. Üzerine gelince birincil biraz açık sarı, ikincil çerçeve rengi, tehlikeli çerçeveli, hayalet yüzey-2
/// zeminli; basılıyken %97 ölçek; klavye odağında 2 pt sarı yazı rengi çerçeve. Devre dışı birincil yüzey-2 zemin ve ikincil
/// yazı (soldurulmuş sarı yok), öbürleri %40 saydamlık.
struct CSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, ghost }
    var kind: Kind = .secondary
    var fullWidth = false
    /// "buttonHeight" (40), "buttonLarge" (44) ya da ana ekrandaki büyük düğme için "primaryActionHeight" (52).
    var height = "buttonHeight"

    func makeBody(configuration: Configuration) -> some View {
        CSButtonSwitch(configuration: configuration, kind: kind, fullWidth: fullWidth, height: height)
    }
}

/// Yeni arayüzde (yalnız Mac) düğme yeni dilde çizilir; değilse eski görünüm.
private struct CSButtonSwitch: View {
    let configuration: ButtonStyleConfiguration
    let kind: CSButtonStyle.Kind
    let fullWidth: Bool
    let height: String
    @Environment(\.csNewLook) private var newLook

    var body: some View {
        #if os(macOS)
        if newLook {
            NewLookButton(configuration: configuration, kind: kind, fullWidth: fullWidth)
        } else {
            CSButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth, height: height)
        }
        #else
        CSButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth, height: height)
        #endif
    }
}

/// Düğmenin görünümü. Üzerine gelme ve odak durumu ayrı görünümde tutulur (ButtonStyle kendi durumunu tutamaz).
private struct CSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: CSButtonStyle.Kind
    let fullWidth: Bool
    let height: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous)
        let pressed = configuration.isPressed
        let hovered = hovering && isEnabled
        configuration.label
            .font(.csButton)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost ? Theme.space("m") : Theme.space("tile"))
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Theme.size(height))
            .background(background(pressed: pressed, hovered: hovered), in: shape)
            .overlay { border(shape, hovered: hovered) }
            .overlay {
                if isFocused { shape.strokeBorder(Color.csAccentText, lineWidth: 2) }
            }
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled || kind == .primary ? 1 : 0.4)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle, hovered: Bool) -> some View {
        switch kind {
        case .secondary: shape.strokeBorder(Color.csBorder)
        case .danger: if hovered { shape.strokeBorder(Color.csDangerBorder) }
        case .primary, .ghost: EmptyView()
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: isEnabled ? Color.csOnAccent : Color.csSecondary
        case .secondary: .csText
        case .danger: .csDanger
        case .ghost: .csAccentText
        }
    }

    private func background(pressed: Bool, hovered: Bool) -> Color {
        switch kind {
        case .primary: !isEnabled ? Color.csSurface2 : (pressed || hovered ? Color.csAccentHi : Color.csAccent)
        case .secondary: hovered ? Color.csBorder : Color.csSurface2
        case .danger: Color.csDangerSoft
        case .ghost: hovered ? Color.csSurface2 : Color.clear
        }
    }
}

extension ButtonStyle where Self == CSButtonStyle {
    static var primary: CSButtonStyle { CSButtonStyle(kind: .primary) }
    static var secondary: CSButtonStyle { CSButtonStyle(kind: .secondary) }
    static var danger: CSButtonStyle { CSButtonStyle(kind: .danger) }
    static var ghost: CSButtonStyle { CSButtonStyle(kind: .ghost) }
}

/// Karolarla aynı dilde metin alanı: yüzey-2 zemin, ince çerçeve, yuvarlak köşe; odaktayken çerçeve sarı.
/// Yükseklik en az `buttonHeight` (40); PS5 kodu alanı 52.
struct CSTextFieldStyle: TextFieldStyle {
    var font: Font = .csBody
    var height: CGFloat = Theme.size("buttonHeight")

    func _body(configuration: TextField<Self._Label>) -> some View {
        CSTextFieldSwitch(field: configuration.textFieldStyle(.plain), font: font, height: height)
    }
}

private struct CSTextFieldSwitch<Field: View>: View {
    let field: Field
    let font: Font
    let height: CGFloat
    @Environment(\.csNewLook) private var newLook

    var body: some View {
        #if os(macOS)
        if newLook {
            DSFieldChrome { field }
        } else {
            CSTextFieldBody(field: field, font: font, height: height)
        }
        #else
        CSTextFieldBody(field: field, font: font, height: height)
        #endif
    }
}

/// Alanın görünümü; odak durumu ayrı görünümde tutulur (TextFieldStyle kendi durumunu tutamaz).
private struct CSTextFieldBody<Field: View>: View {
    let field: Field
    let font: Font
    let height: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous)
        field
            .focused($focused)
            .font(font)
            .padding(.horizontal, Theme.space("l"))
            .frame(minHeight: height)
            .background(Color.csSurface2, in: shape)
            .overlay(shape.strokeBorder(focused ? Color.csAccent : Color.csBorder))
    }
}

/// Karonun görünümü: düz ya da etkin (seçili seçenek: 1 pt sarı çerçeve). Parıltı ve degrade yok.
enum TileStyle {
    case plain, active
}

/// Karo: düz yüzey, ince çerçeve, karo köşesi (16). Tıklanan karo üzerine gelinince `fill` ile yüzey-2 zemin alır.
struct TileBackground: ViewModifier {
    var style: TileStyle = .plain
    var padding: CGFloat = Theme.space("tile")
    var fill: Color = .csSurface

    func body(content: Content) -> some View {
        TileBody(content: content, style: style, padding: padding, fill: fill)
    }
}

private struct TileBody<Content: View>: View {
    let content: Content
    let style: TileStyle
    let padding: CGFloat
    let fill: Color
    @Environment(\.csNewLook) private var newLook

    var body: some View {
        #if os(macOS)
        if newLook {
            // Yeni arayüzde gömülü karo: kart içinde alan zemini, 16 köşe, ince halka (etkin: 2 pt amber).
            let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
            content
                .padding(padding)
                .background(fill == .csSurface ? Color.dsSurface : Color.dsField, in: shape)
                .overlay(shape.strokeBorder(style == .active ? Color.dsAmber : Color.dsBorder, lineWidth: style == .active ? 2 : 1))
        } else {
            legacy
        }
        #else
        legacy
        #endif
    }

    private var legacy: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("card"), style: .continuous)
        return content
            .padding(padding)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(style == .active ? Color.csAccent : Color.csTileBorder))
    }
}

extension View {
    func tile(_ style: TileStyle = .plain, padding: CGFloat = Theme.space("tile"), fill: Color = .csSurface) -> some View {
        modifier(TileBackground(style: style, padding: padding, fill: fill))
    }
}

/// Başlıklı ya da başlıksız içerik karosu.
struct Card<Content: View>: View {
    var title: LocalizedStringKey?
    var style: TileStyle = .plain
    @ViewBuilder var content: Content
    @Environment(\.csNewLook) private var newLook

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("m")) {
            if let title {
                if newLook {
                    // Yeni arayüzde kart başlığı mono bölüm etiketi (büyük harf, dile göre: i → İ); altına 8 ek boşluk.
                    Text(title).font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.96)
                        .textCase(.uppercase).foregroundStyle(Color.csSecondary).padding(.bottom, 8)
                } else {
                    Text(title).font(.csHeadline)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(style)
    }
}

/// Bilgi karosu: durum değil, ayar bilgisi gösteren düz karo; satırlar (`InfoRow`) arasında `InfoDivider`. Simge yok.
/// Karonun iç boşluğu satırın kendi boşluğuyla birlikte `tile` olur; tıklanan satırın zemini kenara yakın uzanır.
struct InfoCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile(padding: Theme.space("s"))
    }
}

/// Bilgi karosunun satırı: solda ad (`body`, ikincil), sağda değer; en az `rowHeight`. `action` verilirse satır bir
/// ayara götürür: sonunda `›` durur, üzerine gelince yüzey-2 zemin alır.
struct InfoRow<Value: View>: View {
    private let title: LocalizedStringKey
    private let action: (() -> Void)?
    private let value: Value

    init(_ title: LocalizedStringKey, @ViewBuilder value: () -> Value, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
        self.value = value()
    }

    var body: some View {
        if let action {
            Button(action: action) { row(chevron: true) }
                .buttonStyle(RowButtonStyle(radius: "inner"))
        } else {
            row(chevron: false)
        }
    }

    private func row(chevron: Bool) -> some View {
        HStack(spacing: Theme.space("inline")) {
            Text(title).font(.csBody).foregroundStyle(Color.csSecondary)
            Spacer(minLength: Theme.space("m"))
            value
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.csCaption.weight(.semibold))
                    .foregroundStyle(Color.csSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.space("s"))
        .frame(maxWidth: .infinity, minHeight: Theme.size("rowHeight"))
        .accessibilityElement(children: .combine)
    }
}

extension InfoRow where Value == InfoValue {
    /// Yazı değerli satır (`body` yarı kalın, ana renk).
    init(_ title: LocalizedStringKey, value: String, action: (() -> Void)? = nil) {
        self.init(title, value: { InfoValue(text: value) }, action: action)
    }
}

/// Bilgi karosundaki yazı değeri.
struct InfoValue: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.csBody.weight(.semibold))
            .foregroundStyle(Color.csText)
            .lineLimit(1)
    }
}

/// Bilgi karosunda satırlar arasındaki 1 pt ayraç (satır yazısıyla aynı hizada).
struct InfoDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.csBorder)
            .frame(height: 1)
            .padding(.horizontal, Theme.space("s"))
            .accessibilityHidden(true)
    }
}

/// Kısayol tuşu: `keycap` (24) yükseklik, etiket köşesi, yüzey-2 zemin, ince çerçeve, `caption` yazı.
struct Keycap: View {
    let keys: String

    init(_ keys: String) {
        self.keys = keys
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("tag"), style: .continuous)
        Text(verbatim: keys)
            .font(.csCaption)
            .foregroundStyle(Color.csText)
            .lineLimit(1)
            .padding(.horizontal, Theme.space("s"))
            .frame(height: Theme.size("keycap"))
            .background(Color.csSurface2, in: shape)
            .overlay(shape.strokeBorder(Color.csBorder))
            .fixedSize()
    }
}

/// Kendi zeminini çizen satır düğmeleri (kenar çubuğu satırı, bilgi karosu satırı, öneri listesi): üzerine gelince ve
/// basılıyken yüzey-2 zemin (`hoverFill` nil ise zemini düğmenin kendisi değiştirir), klavye odağında 2 pt sarı yazı
/// rengi çerçeve.
struct RowButtonStyle: ButtonStyle {
    /// Zeminin köşesi: "inner" (8) ya da "control" (12) ya da "card" (16).
    var radius = "inner"
    var hoverFill: Color? = .csSurface2

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, radius: radius, hoverFill: hoverFill)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: String
    let hoverFill: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius(radius), style: .continuous)
        let highlighted = isEnabled && (hovering || configuration.isPressed)
        configuration.label
            .background((highlighted ? hoverFill : nil) ?? Color.clear, in: shape)
            .overlay {
                if isFocused { shape.strokeBorder(Color.csAccentText, lineWidth: 2) }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

extension View {
    /// "Kopyalandı" gibi kısa onayı ~1,5 sn sonra geri alır (düğme yeniden "Kopyala" olur).
    func resetsAfterDelay(_ flag: Binding<Bool>, seconds: Double = 1.5) -> some View {
        task(id: flag.wrappedValue) {
            guard flag.wrappedValue else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            flag.wrappedValue = false
        }
    }
}

/// Karodaki simge: kutusuz, 18 pt, ikincil renkte (paket simgesi mor).
struct TileIcon: View {
    let symbol: String
    var tint: Color = .csSecondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

/// Etiket: 24 yükseklik, etiket köşesi (6), nötr zemin; paket için mor. Canlı durum (`live`) etiket değil,
/// atan nokta ve yazıdır.
struct Pill: View {
    enum Tone { case pro, muted }
    let text: String
    var tone: Tone = .muted
    var live = false

    var body: some View {
        if live {
            HStack(spacing: Theme.space("inline")) {
                LiveDot()
                Text(verbatim: text).lineLimit(1)
            }
            .font(.csCaption.monospacedDigit())
            .foregroundStyle(Color.csText)
        } else {
            Text(verbatim: text)
                .lineLimit(1)
                .font(.csCaption.monospacedDigit())
                .foregroundStyle(tone == .pro ? Color.csPro : Color.csSecondary)
                .padding(.horizontal, Theme.space("s"))
                .frame(height: 24)
                .background(tone == .pro ? Color.csProSoft : Color.csSurface2,
                            in: RoundedRectangle(cornerRadius: Theme.radius("tag"), style: .continuous))
        }
    }
}

/// Durum noktası (8 pt): bağlı, hazır, sorun var. Atmaz; atan nokta yalnız canlı çeviride (`LiveDot`).
struct StatusDot: View {
    var color: Color = .csSuccess

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Theme.size("statusDot"), height: Theme.size("statusDot"))
            .accessibilityHidden(true)
    }
}

/// Canlı nokta: yeşil nokta ve 2 sn'de bir genişleyip sönen halka; yalnız çeviri canlıyken (azaltılmış harekette halka yok).
struct LiveDot: View {
    var color: Color = .csSuccess
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        let size = Theme.size("statusDot")
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if !reduceMotion {
                    Circle()
                        .stroke(color, lineWidth: 2)
                        .frame(width: size + 8, height: size + 8)
                        .scaleEffect(pulsing ? 1.2 : 0.5)
                        .opacity(pulsing ? 0 : 0.7)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                // ai-design-check-ignore-next-line pulse-for-live-only -- yalnız canlı çeviride gösterilir; azaltılmış harekette durur
                withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { pulsing = true }
            }
            .accessibilityHidden(true)
    }
}

/// Sihirbaz adımlarının ortak düzeni: başlık, açıklama, içerik (simge kutusu yok).
struct StepLayout<Content: View>: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var content: Content
    @Environment(\.csNewLook) private var newLook

    var body: some View {
        // Yeni arayüzde başlık ve açıklamayı sihirbazın kendisi (tuvaldeki metinlerle) çizer; adım yalnız içeriğini verir.
        if newLook {
            VStack(alignment: .leading, spacing: 16) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: Theme.space("l")) {
                Text(title)
                    .font(.csDisplay)
                Text(message)
                    .font(.csBody)
                    .foregroundStyle(Color.csSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                content
                    .padding(.top, Theme.space("s"))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Numaralı talimat satırı.
struct NumberedRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.space("m")) {
            Text("\(number)")
                .font(.csCallout.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.csText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.csSurface2))
            Text(text)
                .font(.csBody)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Durum noktasının rengi: bağlı (yeşil), sorun var (turuncu), boşta (gri).
enum StatusTone: Equatable {
    case idle, warning, good

    var color: Color {
        switch self {
        case .good: .csSuccess
        case .warning: .csWarning
        case .idle: .csSecondary
        }
    }
}

/// Renkli durum noktası, adı ve değeri.
struct StatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: Theme.space("m")) {
            Circle()
                .fill(tone.color)
                .frame(width: Theme.size("statusDot"), height: Theme.size("statusDot"))
            Text(title).font(.csBody.weight(.semibold))
            Spacer()
            Text(value)
                .font(.csBody)
                .foregroundStyle(tone == .good ? Color.csText : Color.csSecondary)
                .lineLimit(1)
        }
    }
}

/// Durum karosu: üstte etiket satırı (simge, ad, durum noktası), altında değer.
struct StatusTile<Accessory: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    var tone: StatusTone = .idle
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("s")) {
            HStack(spacing: Theme.space("inline")) {
                TileIcon(symbol: symbol)
                Text(title).font(.csCaption).foregroundStyle(Color.csSecondary)
                Spacer(minLength: 0)
                if tone != .idle { StatusDot(color: tone.color) }
            }
            Text(verbatim: value)
                .font(.csHeadline)
                .fixedSize(horizontal: false, vertical: true)
            accessory
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
        .accessibilityElement(children: .combine)
    }
}

extension StatusTile where Accessory == EmptyView {
    init(symbol: String, title: LocalizedStringKey, value: String, tone: StatusTone = .idle) {
        self.init(symbol: symbol, title: title, value: value, tone: tone) { EmptyView() }
    }
}

/// Tamamlanan bir adımın onayı.
struct DoneLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.csBody.weight(.semibold))
            .foregroundStyle(Color.csSuccess)
    }
}

/// İkincil açıklama metni.
struct HintText: View {
    let text: LocalizedStringKey
    @Environment(\.csNewLook) private var newLook

    var body: some View {
        #if os(macOS)
        if newLook {
            Text(text).dsMuted()
        } else {
            legacy
        }
        #else
        legacy
        #endif
    }

    private var legacy: some View {
        Text(text)
            .font(.csCallout)
            .foregroundStyle(Color.csSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Bir işlem başarısız olunca gösterilen hata metni.
struct ErrorText: View {
    let error: String?

    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.csCallout)
                .foregroundStyle(Color.csWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Uygulamanın tamamına zemin rengi, yazı rengi ve temel yazı boyutunu verir.
struct AppSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.csBody)
            .foregroundStyle(Color.csText)
            .tint(Color.csAccentText)
            .background(Color.csBackground.ignoresSafeArea())
    }
}

extension View {
    func appSurface() -> some View { modifier(AppSurface()) }
}
