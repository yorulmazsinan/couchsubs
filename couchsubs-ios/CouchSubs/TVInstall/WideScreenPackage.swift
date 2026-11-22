// SPDX-License-Identifier: AGPL-3.0-only
// Android'deki WideScreenPackage.kt ve Windows'taki WideScreenPackage.cs'in Swift karşılığı.

import Foundation

/// 21:9 / 32:9 Samsung akıllı monitörler (Odyssey G9 49", #886) için paket, 0.9.27–0.9.54'teki gibi geniş uygulama
/// yüzeyiyle kurulur: config.xml'e `base_screen_resolution=fullscreen`, index.html'e `width=device-width` görünümü.
/// Samsung yüzeyi ancak ikisi birlikteyken ekranın tamamı yapar; platform.js geniş yüzeyi görünce HDMI görüntüsünü 16:9
/// sığdırır, Sarı ile ekranı doldurur. 0.9.55'te ayar her TV'den kaldırılmıştı (4K/8K TV'de yüzeyi panel pikselinde açıp
/// PS5 görüntüsünü sol üst köşede bırakıyordu, #799); o günden beri G9'da uygulama 16:9 kutuda, TVWindow da 3840x1080'i
/// NotSupportedError ile reddediyor. TV'lere (16:9) paket değişmeden gider.
enum WideScreenPackage {
    /// 16:9'dan (1,78) belirgin geniş (21:9 = 2,33; 32:9 = 3,56); platform.js'teki WIDE_RATIO.
    private static let wideRatio = 1.9

    static let metadata = #"<tizen:metadata key="http://tizen.org/metadata/app_ui_type/base_screen_resolution" value="fullscreen"/>"#

    /// TV'nin 8001 yanıtındaki model adı (`LS49…` 32:9, `LS34…` 21:9, `LS57…` 32:9 Samsung monitör) ya da çözünürlüğü
    /// (`5120x1440`) ultra geniş bir ekran mı söylüyor?
    static func applies(model: String?, resolution: String?) -> Bool {
        if let model, model.trimmingCharacters(in: .whitespaces)
            .range(of: #"^L?[SC](34|49|57)[A-Z]"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let parts = (resolution ?? "").trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == "x" || $0 == "X" || $0 == "*" })
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let width = parts[0], let height = parts[1], height > 0 else { return false }
        return width / height >= wideRatio
    }

    static func adaptConfig(_ config: String) -> String {
        if config.contains(#"app_ui_type/base_screen_resolution""#) { return config }
        guard let end = config.range(of: "</widget>", options: .backwards) else { return config }
        return config.replacingCharacters(in: end.lowerBound..<end.lowerBound, with: "    " + metadata + "\n")
    }

    static func adaptPage(_ html: String) -> String {
        html.replacingOccurrences(of: #"<meta name="viewport" content="width=1920">"#,
                                  with: #"<meta name="viewport" content="width=device-width">"#)
    }

    /// config.xml ve index.html geniş yüzeye göre yazılır; değişen bir şey yoksa paket olduğu gibi döner.
    static func adapt(_ wgt: [UInt8]) throws -> [UInt8] {
        var changed = false
        let adapted = try StoredZip.read(wgt).map { entry -> StoredZip.Entry in
            let adapt: ((String) -> String)?
            switch entry.name {
            case "config.xml": adapt = adaptConfig
            case "index.html": adapt = adaptPage
            default: adapt = nil
            }
            guard let adapt else { return entry }
            let original = String(decoding: entry.data, as: UTF8.self)
            let text = adapt(original)
            guard text != original else { return entry }
            changed = true
            return StoredZip.Entry(name: entry.name, data: Array(text.utf8))
        }
        return changed ? StoredZip.write(adapted) : wgt
    }
}
