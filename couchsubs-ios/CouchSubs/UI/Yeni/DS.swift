// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import UIKit

// Yeni arayüzün tasarım sistemi, iPhone karşılığı. Değerler Mac ve Windows'la aynı dosyadan (design/yeni-arayuz/tasarim.json)
// gelir; renkler açık ve koyu görünümde ayrı. Adlar Mac'teki DS ile aynıdır (mac/CouchSubs/UI/Yeni/DS.swift). Telefonda
// yazılar sistemin metin stilleriyle kurulur: varsayılan boyda tablodaki boylara denk düşer, Dinamik Yazı'yla büyür.

struct DSTokens: Decodable {
    struct ColorPair: Decodable {
        let light: String
        let dark: String
    }

    struct FontToken: Decodable {
        let size: Double
        let weight: String
        let tracking: Double?
        let design: String?
    }

    struct Motion: Decodable {
        let short: Double
        let medium: Double
        let page: Double
        let reduced: Double
        let enter: [Double]
        let exit: [Double]
        let adRotate: Double
    }

    let color: [String: ColorPair]
    let font: [String: FontToken]
    let mutedTracking: Double
    let space: [String: Double]
    let radius: [String: Double]
    let size: [String: Double]
    let motion: Motion

    /// "#RRGGBB" ya da "#RRGGBBAA" → 0–1 aralığında kırmızı, yeşil, mavi, saydamlık.
    static func rgba(_ hex: String) -> (Double, Double, Double, Double)? {
        guard hex.first == "#", hex.count == 7 || hex.count == 9, let value = UInt64(hex.dropFirst(), radix: 16) else { return nil }
        if hex.count == 7 {
            return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255, 1)
        }
        return (Double(value >> 24 & 0xFF) / 255, Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

enum DS {
    static let tokens: DSTokens = {
        guard let url = Bundle.main.url(forResource: "tasarim", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tokens = try? JSONDecoder().decode(DSTokens.self, from: data) else {
            fatalError("tasarim.json uygulama paketinde yok ya da bozuk")
        }
        return tokens
    }()

    static func color(_ name: String) -> Color {
        guard let pair = tokens.color[name] else { fatalError("Bilinmeyen renk: \(name)") }
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            let (r, g, b, a) = DSTokens.rgba(hex) ?? (0, 0, 0, 1)
            return UIColor(red: r, green: g, blue: b, alpha: a)
        })
    }

    /// Telefonda yazı biçimleri sistem metin stilleriyle (Dinamik Yazı). Sayfa başlığı telefonda 28 (masaüstünde 32).
    static func font(_ name: String) -> Font {
        switch name {
        case "h1": .system(.title, weight: .semibold)
        case "h2": .system(.title2, weight: .medium)
        case "h3": .system(.title3, weight: .medium)
        case "subtitle", "cardTitle": .system(.body, weight: .medium)
        case "body": .system(.subheadline, weight: .regular)
        case "bodyStrong", "buttonSecondary", "tab", "row": .system(.subheadline, weight: .medium)
        case "button": .system(.subheadline, weight: .semibold)
        case "small": .system(.footnote, weight: .regular)
        case "label": .system(.footnote, weight: .medium)
        case "caption": .system(.caption, weight: .regular)
        case "mono": .system(.caption, design: .monospaced).weight(.medium)
        case "monoValue": .system(.title3, design: .monospaced).weight(.semibold)
        case "adTag": .system(size: 9, weight: .semibold, design: .monospaced)
        default: fatalError("Bilinmeyen yazı biçimi: \(name)")
        }
    }

    static func tracking(_ name: String) -> CGFloat { CGFloat(tokens.font[name]?.tracking ?? 0) }
    static func space(_ name: String) -> CGFloat { CGFloat(tokens.space[name] ?? 0) }
    static func radius(_ name: String) -> CGFloat { CGFloat(tokens.radius[name] ?? 0) }
    static func size(_ name: String) -> CGFloat { CGFloat(tokens.size[name] ?? 0) }
    /// Dikey ritim Mac'le aynı (tasarim.json › space): başlık → denetim 8, denetim → açıklama 6; birimler arası 24.
    static var unitTitleGap: CGFloat { space("unitTitle") }
    static var unitHintGap: CGFloat { space("unitHint") }
    static var unitGap: CGFloat { space("unitGap") }
    static var mutedTracking: CGFloat { CGFloat(tokens.mutedTracking) }

    // MARK: Hareket

    static func enter(_ ms: Double) -> Animation {
        let c = tokens.motion.enter
        return .timingCurve(c[0], c[1], c[2], c[3], duration: ms / 1000)
    }

    enum Motion { case short, medium, page }

    /// Hareketi azalt açıksa yalnız kısa solma kalır.
    static func animation(_ motion: Motion, reduced: Bool) -> Animation {
        if reduced { return .easeOut(duration: tokens.motion.reduced / 1000) }
        switch motion {
        case .short: return enter(tokens.motion.short)
        case .medium: return enter(tokens.motion.medium)
        case .page: return enter(tokens.motion.page)
        }
    }
}

extension Color {
    static let dsBackground = DS.color("background")
    static let dsSurface = DS.color("surface")
    static let dsField = DS.color("field")
    static let dsBorder = DS.color("border")
    static let dsTileBorder = DS.color("tileBorder")
    static let dsText = DS.color("text")
    static let dsMuted = DS.color("muted")
    static let dsFaint = DS.color("faint")
    static let dsCharcoal = DS.color("charcoal")
    static let dsOnCharcoal = DS.color("onCharcoal")
    static let dsLogoBack = DS.color("logoBack")
    static let dsLogoSeat = DS.color("logoSeat")
    static let dsAmber = DS.color("amber")
    static let dsAmberHover = DS.color("amberHover")
    static let dsAmberLine = DS.color("amberLine")
    static let dsOnAmber = DS.color("onAmber")
    static let dsAmberText = DS.color("amberText")
    static let dsAmberSoft = DS.color("amberSoft")
    static let dsSwitchOff = DS.color("switchOff")
    static let dsSuccess = DS.color("success")
    static let dsSuccessText = DS.color("successText")
    static let dsSuccessSoft = DS.color("successSoft")
    static let dsSuccessRing = DS.color("successRing")
    static let dsLive = DS.color("live")
    static let dsLiveText = DS.color("liveText")
    static let dsLiveSoft = DS.color("liveSoft")
    static let dsLiveRing = DS.color("liveRing")
    static let dsLiveDot = DS.color("liveDot")
    static let dsScreenFrame = DS.color("screenFrame")
    static let dsScrim = DS.color("scrim")
}

extension Font {
    static let dsH1 = DS.font("h1")
    static let dsH2 = DS.font("h2")
    static let dsH3 = DS.font("h3")
    static let dsCardTitle = DS.font("cardTitle")
    static let dsLabel = DS.font("label")
    static let dsBody = DS.font("body")
    static let dsBodyStrong = DS.font("bodyStrong")
    static let dsButton = DS.font("button")
    static let dsButtonSecondary = DS.font("buttonSecondary")
    static let dsTab = DS.font("tab")
    static let dsRow = DS.font("row")
    static let dsSmall = DS.font("small")
    static let dsCaption = DS.font("caption")
    static let dsMono = DS.font("mono")
    static let dsMonoValue = DS.font("monoValue")
    static let dsAdTag = DS.font("adTag")
}

extension View {
    /// Gri açıklama/ipucu yazısı: ikincil renk, -0.5 harf aralığı, satıra iner.
    func dsMuted(_ font: Font = .dsSmall) -> some View {
        self.font(font)
            .foregroundStyle(Color.dsMuted)
            .tracking(DS.mutedTracking)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Mac'teki hareket tercihi anahtarı (ortak bileşenler okur); telefonda yalnız sistemin "Hareketi azalt" ayarı vardır.
private struct DSReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dsMotionOff: Bool {
        get { self[DSReducedMotionKey.self] }
        set { self[DSReducedMotionKey.self] = newValue }
    }
}

/// Ortak Card'ın (Components.swift) öğe aralığı; Mac'teki DSComponents.swift ile aynı anahtar ve varsayılan.
private struct DSCardSpacingKey: EnvironmentKey {
    static let defaultValue = DS.space("m")
}

extension EnvironmentValues {
    var dsCardSpacing: CGFloat {
        get { self[DSCardSpacingKey.self] }
        set { self[DSCardSpacingKey.self] = newValue }
    }
}
