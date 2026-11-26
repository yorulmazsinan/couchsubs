// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Video parlaklığının aralığı. Çözücünün YUV karesi sınırlı (video, Y 16–235) ya da tam (0–255) aralıklı olabilir;
/// telefon araması ve renk örnekleri tam aralıklı sRGB değerleri bekler (dosyadaki kareler, VideoToolbox'ın BGRA'sı,
/// Windows'un sws_scale çıktısı). Sınırlı aralıklı gri resim tam aralığa açılır: kara 16 yerine 0, beyaz 235 yerine 255.
/// Android aynı dönüşümü tersinden yapar (tam aralıklı kare sınırlıya çevrilir, `PhoneFrames` sınırlı bekler; VideoRange.kt).
public enum VideoRange {
    /// Sınırlı aralıklı Y → tam aralık: (Y − 16) × 255 / 219, 0–255'e sıkıştırılmış.
    public static let limitedToFull: [UInt8] = (0..<256).map { UInt8(max(0, min(255, (($0 - 16) * 255 + 109) / 219))) }

    /// `data`'daki her bayt (sınırlı aralıklı Y) tam aralığa çevrilir.
    public static func expandLuma(_ data: inout Data) {
        limitedToFull.withUnsafeBufferPointer { table in
            data.withUnsafeMutableBytes { raw in
                for i in 0..<raw.count { raw[i] = table[Int(raw[i])] }
            }
        }
    }
}
