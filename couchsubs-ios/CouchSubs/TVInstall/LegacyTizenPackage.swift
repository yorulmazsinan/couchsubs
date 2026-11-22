// SPDX-License-Identifier: AGPL-3.0-only
// Android'deki LegacyTizenPackage.kt'nin Swift karşılığı.

import Foundation

/// 2016 Samsung TV'ler (Tizen 2.x) için paketin config.xml'i, #71'de 40KU7000'de (Tizen 2.4) elle kurulup çalışan pakete
/// döndürülür. O paketten sonra eklenen iki satır çıkarılır:
/// - `network.public` izni (0.9.30): yalnız TV adresini bulmanın yedeği (webapis.network.getIp); platform.js hatayı yutar,
///   adres bulunamazsa app.js ev ağını tarar.
/// - `base_screen_resolution` ayarı (0.9.30): yalnız 21:9 / 32:9 Samsung monitörler için (#304); 2016 TV'lerde yoktur.
///
/// Tizen 2.4 tanımadığı satırı içeren paketi sebep yazmadan `install failed[118]` ile reddediyor; `power` izni
/// çıkarıldıktan sonra da (#497) 0.9.38 aynı hatayı verdi (#621). Yeni TV'lerde paket değişmez.
///
/// Asıl eksik paket değil, cihaz profilinin yeriydi (#890): Tizen 2.x profili `/home/developer`'da arar (SamsungInstaller).
/// İlk deneme #71'deki gibi SHA-512 imzalıdır; TV yine yalın `install failed[118]` derse aynı kurulumda bir kez de
/// SHA-256 imzalı (`WgtSigner.Digest`) "yalın" paket denenir (#638): `tizen:profile` satırı ile `application.launch` ve
/// `network.get` izinleri de çıkar (uygulama bunlarsız da açılır; TV adresi ağ taramasıyla bulunur). Hangisinin tuttuğu
/// günlükten görülür.
enum LegacyTizenPackage {
    /// Bu sürümden eski TV'lerde (Tizen 2.x) paket sadeleştirilir.
    private static let firstModern = "3.0"

    static func applies(_ platform: String) -> Bool { !platform.isEmpty && Versions.isNewer(firstModern, than: platform) }

    private static let removed = [
        #"[ \t]*<tizen:privilege name="http://developer\.samsung\.com/privilege/network\.public"\s*/>[ \t]*\r?\n?"#,
        #"[ \t]*<tizen:metadata key="http://tizen\.org/metadata/app_ui_type/base_screen_resolution"[^>]*/>[ \t]*\r?\n?"#,
    ]

    /// Yalın pakette ayrıca çıkarılanlar (günlük için).
    static let leanRemovedNames = "tizen:profile, application.launch, network.get"

    private static let leanRemoved = [
        #"[ \t]*<tizen:profile\s[^>]*/>[ \t]*\r?\n?"#,
        #"[ \t]*<tizen:privilege name="http://tizen\.org/privilege/(application\.launch|network\.get)"\s*/>[ \t]*\r?\n?"#,
    ]

    /// config.xml'den yukarıdaki satırlar (`lean` ise yalın paketinkiler de) çıkarılır; değişen bir şey yoksa paket olduğu
    /// gibi döner.
    static func adapt(_ wgt: [UInt8], lean: Bool = false) throws -> [UInt8] {
        var changed = false
        let adapted = try StoredZip.read(wgt).map { entry -> StoredZip.Entry in
            guard entry.name == "config.xml" else { return entry }
            let original = String(decoding: entry.data, as: UTF8.self)
            let config = (lean ? removed + leanRemoved : removed).reduce(original) { text, pattern in
                text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            guard config != original else { return entry }
            changed = true
            return StoredZip.Entry(name: entry.name, data: Array(config.utf8))
        }
        return changed ? StoredZip.write(adapted) : wgt
    }
}
