// SPDX-License-Identifier: AGPL-3.0-only
// Xbox karesinin düzeni ve parlaklık aralığı (#1385): telefon aramasının durum satırında kare biçimi (boyut, düzlem adımları,
// düzlem düzeni, aralık) ve yazılım çözücüsünün I420 karesinde aralık ölçümü. Android'deki XboxLumaRange ve
// XboxFrameHandoff.describeSource (XboxFramePipe.kt) ile aynı ölçüm ve aynı satır parçaları.

import Foundation

/// Xbox akışının parlaklık aralığı. VideoToolbox karesi aralığını kendisi bilir (420v sınırlı, 420f tam) ve CGImage'a
/// doğru çevrilir; yazılım çözücüsünün I420 karesi aralık bildirmez, sınırlı (Y 16–235) varsayılıp tam aralığa açılıyordu
/// (`VideoRange.expandLuma`). Tam aralıklı akışta bu açma koyu tonları kırpar, karanlık sahnede telefonun hoparlör yarığı
/// ve kamerası kasaya karışır. Aralık karelerden ölçülür: `columns`×`rows` noktanın en az `sharePercent`'i sınırlı aralığın
/// belirgin dışındaysa (`low` altı ya da `high` üstü) kare bir oy alır; `votes` oyda akış tam aralıklı sayılır (bağlantı boyunca).
public final class XboxLumaRange: @unchecked Sendable {
    public static let columns = 64, rows = 36
    public static let low = 12, high = 247
    public static let sharePercent = 2
    public static let votes = 3

    private let lock = NSLock()
    private var isFull = false
    private var count = 0
    private var outside = 0

    public init() {}

    /// Akış tam aralıklı ölçüldü.
    public var full: Bool { lock.withLock { isFull } }

    /// Son ölçülen karede aralık dışı noktaların binde oranı (tanı).
    public var outsidePerMille: Int { lock.withLock { outside } }

    /// Y düzlemi (`stride` aralıklı satırlar) ölçülür.
    public func observe(_ plane: UnsafeRawBufferPointer, width: Int, height: Int, stride: Int) {
        guard width > 0, height > 0, !full else { return }
        var outsideCount = 0
        for row in 0..<Self.rows {
            let y = min(height - 1, max(0, Int((Double(row) + 0.5) * Double(height) / Double(Self.rows))))
            for column in 0..<Self.columns {
                let x = min(width - 1, max(0, Int((Double(column) + 0.5) * Double(width) / Double(Self.columns))))
                let index = y * stride + x
                guard index < plane.count else { continue }
                let value = Int(plane[index])
                if value < Self.low || value > Self.high { outsideCount += 1 }
            }
        }
        let total = Self.columns * Self.rows
        lock.withLock {
            outside = outsideCount * 1000 / total
            if outsideCount * 100 >= Self.sharePercent * total {
                count += 1
                if count >= Self.votes { isFull = true }
            }
        }
    }

    public func reset() {
        lock.withLock {
            isFull = false
            count = 0
            outside = 0
        }
    }
}

/// Telefon aramasının durum satırındaki Xbox kare biçimi. Oturum her yeni biçimde günceller, bağlantı bitince temizler;
/// PS5 oturumunda boştur.
public enum XboxFrameFormat {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var text: String?
    }
    private static let box = Box()

    /// Son Xbox karesinin biçimi (yoksa nil).
    public static var current: String? { box.lock.withLock { box.text } }

    public static func update(_ text: String?) {
        box.lock.withLock { if box.text != text { box.text = text } }
    }

    /// Yazılım çözücüsünün I420 karesi: ayrı Y, U, V düzlemleri; telefon araması yalnız Y'yi okur.
    public static func i420(width: Int, height: Int, strideY: Int, strideU: Int, strideV: Int, full: Bool) -> String {
        let chroma = strideU == strideV ? "\(strideU)" : "\(strideU)/\(strideV)"
        return "Xbox I420 \(width)×\(height), Y adımı \(strideY), U/V adımı \(chroma) (ayrı düzlemler, yalnız Y), "
            + (full ? "aralık tam, olduğu gibi okunuyor" : "aralık sınırlı, tam aralığa açılıyor")
    }

    /// VideoToolbox karesi (CVPixelBuffer): piksel biçimi, boyut, düzlem adımları; aralığı biçiminden.
    public static func pixelBuffer(fourCC: UInt32, width: Int, height: Int, strides: [Int]) -> String {
        let code = String(bytes: [24, 16, 8, 0].map { UInt8((fourCC >> UInt32($0)) & 0xff) }, encoding: .ascii) ?? "\(fourCC)"
        let layout: String
        switch strides.count {
        case 0, 1: layout = "adım \(strides.first ?? 0) (tek düzlem)"
        case 2: layout = "Y adımı \(strides[0]), UV adımı \(strides[1]) (iki düzlem)"
        default: layout = "düzlem adımları " + strides.map(String.init).joined(separator: "/")
        }
        let range: String
        switch code {
        case "420v", "x420": range = "aralık sınırlı"
        case "420f", "xf20": range = "aralık tam"
        default: range = "aralık biçimden"
        }
        return "Xbox VideoToolbox \(code) \(width)×\(height), \(layout), \(range)"
    }
}
