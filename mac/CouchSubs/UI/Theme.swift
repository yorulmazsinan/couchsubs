// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// design/tokens.json: renkler, yazı boyutları, boşluklar, köşeler. Parıltı ve degrade yoktur (docs/TASARIM.md). Windows sürümü de aynı dosyayı kullanır;
/// bir değeri değiştirmek için yalnız o dosya düzenlenir.
struct DesignTokens: Decodable {
    struct ColorPair: Decodable {
        let light: String
        let dark: String
    }

    struct FontToken: Decodable {
        let size: Double
        let weight: String
    }

    let name: String
    let color: [String: ColorPair]
    let font: [String: FontToken]
    let space: [String: Double]
    let radius: [String: Double]
    let size: [String: Double]

    /// "#RRGGBB" → 0–1 aralığında kırmızı, yeşil, mavi.
    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// WCAG 2 kontrast oranı (1–21).
    static func contrast(_ a: String, _ b: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let (r, g, b) = rgb(hex) ?? (0, 0, 0)
            func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

enum Theme {
    static let tokens: DesignTokens = {
        guard let url = Bundle.main.url(forResource: "tokens", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tokens = try? JSONDecoder().decode(DesignTokens.self, from: data) else {
            fatalError("tokens.json uygulama paketinde yok ya da bozuk")
        }
        return tokens
    }()

    static func color(_ name: String) -> Color {
        guard let pair = tokens.color[name] else { fatalError("Bilinmeyen renk: \(name)") }
        #if os(macOS)
        return Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark : pair.light
            let (r, g, b) = DesignTokens.rgb(hex) ?? (0, 0, 0)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #else
        // iPhone/iPad uygulaması da aynı tokens.json'u kullanır (bkz. couchsubs-ios/project.yml).
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            let (r, g, b) = DesignTokens.rgb(hex) ?? (0, 0, 0)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }

    static func font(_ name: String) -> Font {
        guard let token = tokens.font[name] else { fatalError("Bilinmeyen yazı biçimi: \(name)") }
        let weight: Font.Weight = switch token.weight {
        case "bold": .bold
        case "semibold": .semibold
        case "medium": .medium
        default: .regular
        }
        return .system(size: token.size, weight: weight)
    }

    static func space(_ name: String) -> CGFloat { CGFloat(tokens.space[name] ?? 0) }
    static func radius(_ name: String) -> CGFloat { CGFloat(tokens.radius[name] ?? 0) }
    static func size(_ name: String) -> CGFloat { CGFloat(tokens.size[name] ?? 0) }
}

extension Color {
    static let csBackground = Theme.color("background")
    static let csSurface = Theme.color("surface")
    static let csSurface2 = Theme.color("surface2")
    static let csTileBorder = Theme.color("tileBorder")
    static let csBorder = Theme.color("border")
    static let csText = Theme.color("textPrimary")
    static let csSecondary = Theme.color("textSecondary")
    static let csAccent = Theme.color("accent")
    static let csAccentHi = Theme.color("accentHi")
    static let csOnAccent = Theme.color("onAccent")
    static let csAccentText = Theme.color("accentText")
    static let csAccentSoft = Theme.color("accentSoft")
    static let csPro = Theme.color("pro")
    static let csProSoft = Theme.color("proSoft")
    static let csSuccess = Theme.color("success")
    static let csSuccessSoft = Theme.color("successSoft")
    static let csWarning = Theme.color("warning")
    static let csDanger = Theme.color("danger")
    static let csDangerSoft = Theme.color("dangerSoft")
    static let csDangerBorder = Theme.color("dangerBorder")
    static let csOnDanger = Theme.color("onDanger")
}

extension Font {
    /// Ekran başlığı (28, yarı kalın, harf aralığı 0); ekranda en çok bir.
    static let csDisplay = Theme.font("display")
    static let csTitle = Theme.font("title")
    static let csHeadline = Theme.font("headline")
    static let csBody = Theme.font("body")
    static let csCallout = Theme.font("callout")
    static let csCaption = Theme.font("caption")
    static let csButton = Theme.font("button")
    static let csCode = Theme.font("code").monospacedDigit()
}
