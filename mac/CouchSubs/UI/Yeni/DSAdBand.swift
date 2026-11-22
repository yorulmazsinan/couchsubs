// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

/// Enmera'nın kendi uygulamalarının reklamı. Üçüncü taraf reklam ağı, izleme ya da kişisel veri yok: liste uygulamanın
/// içinde (şimdilik yerel örnek; uzaktan liste sonra), tıklanınca yalnız bağlantı tarayıcıda açılır.
struct AdItem: Identifiable, Equatable {
    let id: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    /// Bant görselinin yerine iki renkli degrade (görsel gelene kadar).
    let art: [Color]
    let url: URL

    static func == (lhs: AdItem, rhs: AdItem) -> Bool { lhs.id == rhs.id }
}

enum AdCatalog {
    static let home = URL(string: "https://enmera.com.tr")!

    /// Yerel örnek liste (tuvaldeki üç örnek). İçerikler belirlenince uzaktan listeyle değişecek.
    static let band: [AdItem] = [
        AdItem(id: "ornek-1", title: "App Name", text: "Sample ad: a short introduction goes here.",
               art: [Color(red: 0.169, green: 0.176, blue: 0.2), Color(red: 0.353, green: 0.365, blue: 0.4)], url: home),
        AdItem(id: "ornek-2", title: "Second App", text: "Sample ad: ads rotate every 6 seconds.",
               art: [Color(red: 0.961, green: 0.722, blue: 0.239), Color(red: 0.878, green: 0.635, blue: 0.165)], url: home),
        AdItem(id: "ornek-3", title: "Third App", text: "Sample ad: the contents will be decided later.",
               art: [Color(red: 0.31, green: 0.82, blue: 0.773), Color(red: 0.169, green: 0.541, blue: 0.514)], url: home),
    ]
}

/// Uygulama ve ayar sayfalarının altında sabit 64 pt reklam bandı: sağ üstte REKLAM etiketi, reklamlar 6 sn arayla
/// yukarı kayarak değişir, sağda koyu "İncele". Kurulum, açılış ve oyun görüntüsü pencerelerinde gösterilmez.
struct DSAdBand: View {
    var items: [AdItem] = AdCatalog.band
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dsMotionOff) private var motionOff
    @Environment(\.openURL) private var openURL

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        ZStack {
            if let ad = items.indices.contains(index) ? items[index] : items.first {
                row(ad)
                    .id(ad.id)
                    .transition(reduceMotion || motionOff
                                ? .opacity
                                : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity.combined(with: .offset(y: -8))))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: DS.size("adBand"))
        .background(Color.dsSurface, in: shape)
        .overlay(shape.strokeBorder(Color.dsBorder))
        .overlay(alignment: .topTrailing) {
            Text("AD")
                .font(.dsAdTag)
                .tracking(DS.tracking("adTag"))
                .foregroundStyle(Color.dsFaint)
                .padding(.top, 6)
                .padding(.trailing, 10)
                .allowsHitTesting(false)
        }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Advertisement"))
        .task(id: items.count) {
            guard items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(DS.tokens.motion.adRotate * 1_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(DS.animation(.page, reduced: reduceMotion || motionOff)) { index = (index + 1) % items.count }
            }
        }
    }

    private func row(_ ad: AdItem) -> some View {
        HStack(spacing: DS.space("m")) {
            LinearGradient(colors: ad.art, startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: DS.size("adArt"), height: 44)
                .clipShape(RoundedRectangle(cornerRadius: DS.radius("small"), style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.space("xxs")) {
                Text(ad.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsText).lineLimit(1)
                Text(ad.text).font(.dsCaption).foregroundStyle(Color.dsMuted).tracking(DS.mutedTracking).lineLimit(1)
            }
            Spacer(minLength: DS.space("m"))
            Button("Learn More") { openURL(ad.url) }
                .buttonStyle(DSButtonStyle(kind: .small))
        }
        .padding(.leading, DS.space("s"))
        .padding(.trailing, DS.space("m"))
    }
}
