// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Açık telefonun izi: kasanın üst (hoparlör yarığı, kamera, kasa kenarı) ve alt (alt çentik, çene) şeridinden örnekler.
/// X'te 3+ kullanıcı (beta-107): GTA 6 telefonu gece, kapalı ya da karanlık sahnede bir kez çevrilip kayboluyor, bir daha
/// gelmiyordu. Sıkı arama karanlıkta telefonu ara sıra buluyor (günlük: parlaklık 7–60/255, "hoparlör yarığı yok"), açılan
/// telefon iki ıskada kapanıyor, yeniden açılış yine üç gözlem bekliyordu. Telefon açıkken sıkı arama ve gevşek doğrulama
/// ıskalarsa son yerin çevresinde iz karşılaştırılır (normalleştirilmiş çapraz ilinti: parlaklıktan, karşıtlıktan ve gamadan
/// bağımsız): iz tutuyorsa telefon yerinde sayılır, okuma sürer. Telefon indirilince son yerde artık arka plan vardır, iz
/// tutmaz ve telefon her zamanki sürede kapanır. Windows (PhonePrint.cs) ve Android (PhonePrint.kt) aynı örnekler ve eşikler.
enum PhonePrint {
    /// Telefonun ekseni boyunca (0: hoparlör yarığı, 1: alt çentik; boy oranı) örnek satırları.
    static let along: [Double] = [-0.045, -0.02, 0, 0.02, 0.04, 0.96, 0.98, 1.0, 1.02, 1.045]
    /// Eksene dik (boyun oranı) örnek sütunları: kasanın içinde, -0,26 … 0,26.
    static let across: [Double] = (0...12).map { -0.26 + Double($0) * 0.52 / 12 }
    /// İz son yerin bu kadar çevresinde aranır (400×225 ızgarada, her yönde): 330 ms'de el titremesi.
    static let reach = 4
    /// İz bu benzerlikten (normalleştirilmiş çapraz ilinti, -1…1) az değilse telefon yerinde sayılır.
    static let holdSimilarity = 0.8
    /// İzdeki örneklerin en az sapması (ham ton; 1024 = 1 ton): düz, simsiyah ya da tek renk yer iz sayılmaz.
    static let minSpread = 2048.0
    /// Güncel izin sapması kayıtlı izinkinin bu oranından az olmamalı (çok karardı, telefon gitti).
    static let minSpreadRatio = 0.08

    /// `pose`'taki (görüntüye göre 0..1) telefonun izi, `dx`/`dy` ızgara noktası kaydırılmış; `raw` 400×225 ızgaranın
    /// ham tonu (dört noktanın tonu × 256).
    static func samples(_ pose: GamePhoneGeometry.Pose, dx: Int, dy: Int, raw: (Int, Int) -> Int) -> [Int]? {
        let topX = pose.topX * 400, topY = pose.topY * 225
        let axisX = (pose.bottomX - pose.topX) * 400, h = (pose.bottomY - pose.topY) * 225
        guard topX.isFinite, topY.isFinite, axisX.isFinite, h.isFinite, h > 20 else { return nil }
        var out: [Int] = []
        out.reserveCapacity(along.count * across.count)
        for t in along {
            for r in across {
                let x = Int((topX + t * axisX + r * h).rounded(.toNearestOrEven)) + dx
                let y = Int((topY + t * h - r * axisX).rounded(.toNearestOrEven)) + dy
                out.append(raw(min(399, max(0, x)), min(224, max(0, y))))
            }
        }
        return out
    }

    /// İki izin benzerliği: üst ve alt şeridin (izin iki yarısı) normalleştirilmiş çapraz ilintisinin (-1…1) küçüğü. Tek
    /// şerit yetmez: telefonsuz karede geniş bir parlaklık geçişi (koyu üst, açık alt) bütün izle %82 benzeşiyordu; hoparlör
    /// yarığı ve kamera üstte, alt çentik altta aynı anda tutmalı. Şerit düzse (`minSpread`) ya da güncel şerit kayıtlı
    /// şeritten çok sönükse (`minSpreadRatio`) 0.
    static func similarity(_ print: [Int], _ current: [Int]) -> Double {
        guard print.count == current.count, print.count >= 2 else { return 0 }
        let half = print.count / 2
        return min(strip(Array(print[..<half]), Array(current[..<half])), strip(Array(print[half...]), Array(current[half...])))
    }

    /// Tek şeridin normalleştirilmiş çapraz ilintisi; düz ya da çok sönükse 0.
    private static func strip(_ print: [Int], _ current: [Int]) -> Double {
        let n = Double(print.count)
        let ma = Double(print.reduce(0, +)) / n, mb = Double(current.reduce(0, +)) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<print.count {
            let a = Double(print[i]) - ma, b = Double(current[i]) - mb
            sab += a * b
            saa += a * a
            sbb += b * b
        }
        let sa = (saa / n).squareRoot(), sb = (sbb / n).squareRoot()
        guard sa >= minSpread, sb >= minSpread, sb >= sa * minSpreadRatio else { return 0 }
        return sab / (saa * sbb).squareRoot()
    }

    /// İzin son yerin `reach` çevresindeki en iyi eşleşmesi: kayma (ızgara noktası) ve benzerlik.
    static func match(_ print: [Int], pose: GamePhoneGeometry.Pose, raw: (Int, Int) -> Int) -> (dx: Int, dy: Int, similarity: Double) {
        var best = (dx: 0, dy: 0, similarity: -1.0)
        for dy in -reach...reach {
            for dx in -reach...reach {
                guard let current = samples(pose, dx: dx, dy: dy, raw: raw) else { return (0, 0, 0) }
                let s = similarity(print, current)
                // Eşitlikte ilk bulunan (her platformda aynı tarama sırası).
                if s > best.similarity + 1e-9 { best = (dx, dy, s) }
            }
        }
        return (best.dx, best.dy, max(0, best.similarity))
    }
}
