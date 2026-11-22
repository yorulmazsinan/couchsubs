// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Telefondaki "Günlükleri paylaş" (Profil › Hakkında): remoteplay.log, altyazi.log ve varsa tvinstall.log tek bir
/// metin dosyasında birleştirilir; dosyada kişisel veri kalmaz. Yerel ağ adresleri (IP) sorunu anlamak için kalır;
/// PSN hesap kimliği, e-posta, jetonlar, eşleştirme anahtarları (RegistKey, RP key, morning), oturum kimliği ve uzun
/// kimlik dizileri `***` olur. Android'deki core/LogShare.kt ile aynı kurallar; ikisi de ortak deneme dosyası
/// log-redaction.json ile sınanır. Masaüstünde (Mac, Windows) aynı iş "Günlük dosyasını göster" düğmesidir.
public enum LogShare {
    /// Paylaşılan dosyanın adı.
    public static let fileName = "couchsubs-logs.txt"
    /// Her günlükten alınan en çok bayt (dosyanın sonu; en yeni satırlar).
    public static let maxBytesPerLog = 1_500_000

    /// Değeri maskelenen alan adları ("ad: değer", "ad=değer", "\"ad\":\"değer\"" biçimleri).
    static let secretKeys = [
        "hesap kimliği", "account ?id", "account_id", "accountid", "psn ?id", "online ?id", "user ?id", "user_id",
        "rp-?regist-?key", "regist_?key", "registkey", "rp_?key", "rp-key", "rpkey", "morning", "rp-auth", "rp-did",
        "session ?id", "sessionid", "host-?id", "npsso", "access_token", "refresh_token", "id_token", "token",
        "authorization", "password", "passcode", "client_secret", "xuid", "gamertag", "uhs", "userhash", "email", "e-posta",
    ]

    private static let rules: [(NSRegularExpression, String)] = {
        func rule(_ pattern: String, _ template: String) -> (NSRegularExpression, String) {
            (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), template)
        }
        let keys = secretKeys.joined(separator: "|")
        return [
            // E-posta adresi.
            rule(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "***@***"),
            // Bearer / XBL3.0 yetki başlığı.
            rule(#"\b(Bearer|XBL3\.0)\s+[^\s"',]+"#, "$1 ***"),
            // "ad: değer", "ad=değer", "\"ad\":\"değer\"", "ad değer" (yalnız "hesap kimliği" gibi boşluklu Türkçe biçim).
            rule(#"(\b(?:"# + keys + #")["']?\s*[:=]\s*["']?)[^\s"',;&}\])]+"#, "$1***"),
            rule(#"(\b(?:hesap kimliği|session ?id)\s+["']?)[^\s"',;&}\])]+"#, "$1***"),
            // URL'deki tek kullanımlık kod (?code=…&…).
            rule(#"([?&](?:code|state)=)[^\s&"']+"#, "$1***"),
            // Uzun base64/onaltılık dizi (jeton, anahtar): 32 karakter ve üstü. "/" sayılmaz; dosya yolları kalır.
            rule(#"(?<![A-Z0-9+_-])[A-Z0-9+_-]{32,}={0,2}"#, "***"),
        ]
    }()

    /// Metindeki kişisel verileri maskeler; IP adresleri, saatler ve hata kodları kalır.
    public static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in rules {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// Paylaşılacak metin: başlık (uygulama, sürüm, cihaz) ve her günlük kendi başlığıyla, maskelenmiş. Olmayan ya da boş
    /// dosya "(yok)" diye yazılır. `.1` yedeği varsa önce o gelir (zaman sırası).
    public static func combined(header: String, logs: [(name: String, file: URL)]) -> String {
        var parts = [header]
        for (name, file) in logs {
            let backup = file.appendingPathExtension("1")
            let text = [backup, file].compactMap(read).joined()
            parts.append("===== \(name) =====")
            parts.append(text.isEmpty ? "(yok)" : redact(text))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// `combined` metnini `folder` içine yazar ve dosyanın adresini döner (paylaşım sayfasına verilir).
    public static func write(header: String, logs: [(name: String, file: URL)], to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(fileName)
        try Data(combined(header: header, logs: logs).utf8).write(to: target, options: .atomic)
        return target
    }

    private static func read(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytesPerLog) ? size - UInt64(maxBytesPerLog) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // Kesilen ilk satır atılır.
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text.hasSuffix("\n") ? text : text + "\n"
    }
}
