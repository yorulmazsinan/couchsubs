// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// Ortak bileşenler. Ölçü ve renkler Theme'den (design/tokens.json) gelir; ekranlar sabit değer kullanmaz.
// Bileşenlerin tarifi docs/TASARIM.md'de; Windows sürümü aynı bileşenleri aynı adlarla kurar.

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
/// Gölge ve parıltı yok; basılıyken %97 ölçek (birincilde biraz açık sarı), devre dışıyken %40 saydamlık.
struct CSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, ghost }
    var kind: Kind = .secondary
    var fullWidth = false
    /// "buttonHeight" (44), "buttonLarge" (52) ya da ana ekrandaki büyük düğme için "primaryActionHeight".
    var height = "buttonHeight"
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous)
        let pressed = configuration.isPressed
        return configuration.label
            .font(.csButton)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost ? Theme.space("m") : Theme.space("tile"))
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Theme.size(height))
            .background(background(pressed: pressed), in: shape)
            .overlay { border(shape) }
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle) -> some View {
        switch kind {
        case .secondary: shape.strokeBorder(Color.csBorder)
        case .primary, .danger, .ghost: EmptyView()
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .csOnAccent
        case .secondary: .csText
        case .danger: .csDanger
        case .ghost: .csAccentText
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? .csAccentHi : .csAccent
        case .secondary: .csSurface2
        case .danger: .csDangerSoft
        case .ghost: .clear
        }
    }
}

extension ButtonStyle where Self == CSButtonStyle {
    static var primary: CSButtonStyle { CSButtonStyle(kind: .primary) }
    static var secondary: CSButtonStyle { CSButtonStyle(kind: .secondary) }
    static var danger: CSButtonStyle { CSButtonStyle(kind: .danger) }
    static var ghost: CSButtonStyle { CSButtonStyle(kind: .ghost) }
}

/// Karolarla aynı dilde metin alanı: yüzey-2 zemin, ince çerçeve, yuvarlak köşe.
struct CSTextFieldStyle: TextFieldStyle {
    var font: Font = .csBody
    var height: CGFloat = 44

    func _body(configuration: TextField<Self._Label>) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous)
        return configuration
            .textFieldStyle(.plain)
            .font(font)
            .padding(.horizontal, Theme.space("l"))
            .frame(minHeight: height)
            .background(Color.csSurface2, in: shape)
            .overlay(shape.strokeBorder(Color.csBorder))
    }
}

/// Karonun görünümü: düz ya da etkin (seçili seçenek: 1 pt sarı çerçeve). Parıltı ve degrade yok.
enum TileStyle {
    case plain, active
}

/// Karo: düz yüzey, ince çerçeve, karo köşesi (16).
struct TileBackground: ViewModifier {
    var style: TileStyle = .plain
    var padding: CGFloat = Theme.space("tile")

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("card"), style: .continuous)
        return content
            .padding(padding)
            .background(Color.csSurface, in: shape)
            .overlay(shape.strokeBorder(style == .active ? Color.csAccent : Color.csTileBorder))
    }
}

extension View {
    func tile(_ style: TileStyle = .plain, padding: CGFloat = Theme.space("tile")) -> some View {
        modifier(TileBackground(style: style, padding: padding))
    }
}

/// Başlıklı ya da başlıksız içerik karosu.
struct Card<Content: View>: View {
    var title: LocalizedStringKey?
    var style: TileStyle = .plain
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("m")) {
            if let title {
                Text(title).font(.csHeadline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(style)
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
    enum Tone { case accent, pro, success, muted }
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

    var body: some View {
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

    var body: some View {
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
