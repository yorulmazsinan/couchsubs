// SPDX-License-Identifier: AGPL-3.0-only
// Mac ve iPhone uygulamalarının ortak parçası (iPhone projesi de bu dosyayı derler).

import CouchSubsCore
import SwiftUI

/// Altyazı bölgesinin canlı önizlemesi: son PS5 karesi (yoksa yer tutucu) ve üstünde bölgenin çerçevesi. Çerçeve
/// sürüklenerek taşınır, sağ alt köşesinden sürüklenerek boyutlandırılır; her değişiklik `onChange` ile bildirilir.
struct RegionPreview: View {
    let region: CropRegion
    let frame: CGImage?
    /// Kare yokken gösterilen yazı.
    var placeholder: LocalizedStringKey = "The game picture appears here once translating starts."
    let onChange: (CropRegion) -> Void

    /// Sürükleme başladığında bölge (çeviriler hep bu bölgeye göre hesaplanır).
    @State private var dragStart: CropRegion? = nil
    @State private var resizeStart: CropRegion? = nil

    private static let handle: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let box = CGRect(x: size.width * region.left, y: size.height * region.top,
                             width: size.width * (region.right - region.left), height: size.height * (region.bottom - region.top))
            ZStack(alignment: .topLeading) {
                if let frame {
                    Image(decorative: frame, scale: 1).resizable()
                } else {
                    RoundedRectangle(cornerRadius: Theme.radius("inner")).fill(Color.csBackground)
                    Text(placeholder)
                        .font(.csCaption).foregroundStyle(Color.csSecondary)
                        .multilineTextAlignment(.center)
                        .padding(Theme.space("m"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Rectangle()
                    .fill(Color.csAccent.opacity(0.14))
                    .overlay(Rectangle().strokeBorder(Color.csAccent, lineWidth: 2))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .gesture(move(in: size))
                    .accessibilityLabel(Text("Subtitle area"))
                Rectangle()
                    .fill(Color.csAccent)
                    .frame(width: Self.handle, height: Self.handle)
                    .offset(x: box.maxX - Self.handle, y: box.maxY - Self.handle)
                    .gesture(resize(in: size))
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius("inner")))
    }

    private func move(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? region
                dragStart = start
                onChange(start.moved(dx: value.translation.width / max(1, size.width), dy: value.translation.height / max(1, size.height)))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resize(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = resizeStart ?? region
                resizeStart = start
                onChange(start.resized(right: start.right + value.translation.width / max(1, size.width),
                                       bottom: start.bottom + value.translation.height / max(1, size.height)))
            }
            .onEnded { _ in resizeStart = nil }
    }
}

extension AreaPreset {
    /// Seçimin ekrandaki adı.
    var title: LocalizedStringKey {
        switch self {
        case .bottom: "Bottom area"
        case .top: "Top area"
        case .full: "Full screen"
        case .custom: "Custom"
        }
    }
}

/// Yüzde değeri ("40%"; Türkçede "%40").
func percentText(_ value: Double) -> String {
    String(format: String(localized: "%lld%%"), Int(value.rounded()))
}
