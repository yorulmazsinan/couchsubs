// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// İngilizce tuş çubuğundaki kısa komutlar (GameTranslator UiPrompts, bkz. THIRD-PARTY-NOTICES.md).
enum UiCommands {
    private static let commands: [String: String] = [
        "ADD MARKER": "İşaret ekle", "SET DESTINATION": "Hedef belirle", "REMOVE DESTINATION": "Hedefi kaldır",
        "RECENTER": "Ortala", "2D VIEW": "2B görünüm", "3D VIEW": "3B görünüm",
        "ZOOM": "Yakınlaştır", "EXIT": "Çıkış", "BACK": "Geri",
        "SELECT": "Seç", "CLOSE": "Kapat", "CLOSE MENU": "Menüyü kapat",
        "MENU": "Menü", "OPEN": "Aç", "NEXT PAGE": "Sonraki sayfa",
        "PREVIOUS PAGE": "Önceki sayfa", "SHOW TEXT": "Metni göster", "SHOW": "Göster",
        "FLIP": "Çevir", "PUT DOWN": "Bırak", "PICK UP": "Al",
        "DRINK": "İç", "EAT": "Ye", "WEAR": "Giy",
        "TAKE OFF": "Çıkar", "BUY": "Satın al", "SELL": "Sat",
        "PAY": "Öde", "PAY LATER": "Sonra öde", "PAY NOW": "Şimdi öde",
        "ACCEPT": "Kabul et", "DECLINE": "Reddet", "YES": "Evet",
        "NO": "Hayır", "CONFIRM": "Onayla", "CANCEL": "İptal",
        "GOODBYE": "Hoşça kal", "GREET": "Selamla", "TALK": "Konuş",
        "DEFUSE": "Yatıştır", "PROVOKE": "Kışkırt", "WARN": "Uyar",
        "OFFER RIDE": "Arabaya çağır", "ENTER": "Gir", "LEAVE": "Ayrıl",
        "SKIP": "Geç", "CONTINUE": "Devam et", "RETRY": "Tekrar dene",
        "RESTORE ALL": "Hepsini geri yükle", "RESTORE DEFAULT": "Varsayılana döndür", "PREVIEW": "Önizle",
        "PAUSE PREVIEW": "Önizlemeyi durdur", "ADJUST": "Ayarla", "SCROLL": "Kaydır",
        "REFUEL": "Yakıt al", "LIFT": "Kaldır", "ORDER": "Sipariş ver",
        "MAYBE LATER": "Belki sonra", "PHOTO STUDIO": "Fotoğraf stüdyosu", "REMINDERS": "Hatırlatıcılar",
        "ROTATE": "Döndür", "INTERACT": "Etkileşim", "USE": "Kullan",
        "KNOCK": "Kapıyı çal", "CALL": "Ara", "HANG UP": "Telefonu kapat",
        "ANSWER": "Cevapla", "IGNORE": "Yoksay", "REPLY": "Yanıtla",
        "DELETE": "Sil", "SAVE": "Kaydet", "VIEW": "Görüntüle",
        "INSPECT": "İncele", "SEARCH": "Ara", "HIDE": "Saklan",
        "JOIN": "Katıl", "TERMS": "Koşullar", "MARKERS": "İşaretler",
        "DROP": "Bırak", "EQUIP": "Kuşan", "UNEQUIP": "Çıkar",
        "STORE": "Dükkân", "HELP": "Yardım", "OPTIONS": "Seçenekler",
        "CAMERA": "Kamera", "TOGGLE": "Aç / kapat", "GRAB": "Tut",
        "SIT": "Otur", "STAND UP": "Kalk", "SLEEP": "Uyu",
        "SHOWER": "Duş al", "TURN OFF": "Kapat", "TURN ON": "Aç",
        "WATCH": "İzle", "LISTEN": "Dinle", "DRIVE": "Sür",
        "GET IN": "Bin", "GET OUT": "İn", "STEAL": "Çal",
        "HACK": "Hackle", "LOOT": "Yağmala", "COLLECT": "Topla",
    ]

    /// Bütün parçalar bilinen büyük harfli komutlarsa çevirir; aralarındaki ve sondaki simgeleri korur.
    static func translate(_ paragraph: String) -> String? {
        let marker = String(ButtonIcons.marker)
        var translated: [String] = []
        var found = false
        for part in paragraph.components(separatedBy: marker) {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,:!?"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                translated.append("")
            } else {
                guard let command = commands[text] else { return nil }
                translated.append(command)
                found = true
            }
        }
        guard found else { return nil }
        return translated.joined(separator: " \(marker) ").split(separator: " ").joined(separator: " ")
    }

    /// Menülerin kısa etiketleri (ayar değerleri, sekme ve düğme adları). `commands`'ta olan bir etiketin orada kayıtlı
    /// Türkçesi kullanılır; bunlar yalnız orada olmayanlardır (Windows/Android: UiCommands ile aynı).
    private static let labels: [String: String] = [
        "ON": "Açık", "OFF": "Kapalı", "LOAD": "Yükle", "SETTINGS": "Ayarlar", "MAP": "Harita",
        "RESUME": "Sürdür", "QUIT": "Çık", "NEXT": "İleri", "PREVIOUS": "Önceki", "ALL": "Tümü",
        "NONE": "Hiçbiri", "DEFAULT": "Varsayılan", "APPLY": "Uygula", "RESET": "Sıfırla",
        "INVENTORY": "Envanter", "OUTFITS": "Kıyafetler", "OUTFIT": "Kıyafet", "WEAPONS": "Silahlar",
        "STATS": "İstatistikler", "GAME": "Oyun",
    ]

    /// Yazı tanımanın Kiril harfle okuduğu Latin harfler ("Мар" → "Map").
    static func latin(_ text: String) -> String {
        let map: [Character: Character] = [
            "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X",
            "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y",
        ]
        return String(text.map { map[$0] ?? $0 })
    }

    /// `translateLabel`, yazı tanımanın etikete kattığı kırıntıyla da: simge imleriyle ayrılan her parça ayrı aranır;
    /// baştaki ya da sondaki en çok iki harflik kırıntı (simgenin yanlış okunuşu: "pi Settings", "EXIT OR") olduğu gibi
    /// kalır (baştaki tuş adı değilse atılır). Bir parça bulunmazsa nil (Windows/Android ile aynı).
    static func translateLabelLoosely(_ label: String) -> String? {
        let marker = ButtonIcons.marker
        if label.contains(marker) {
            var done: [String] = []
            var any = false
            for part in label.split(separator: marker, omittingEmptySubsequences: false) {
                if part.trimmingCharacters(in: .whitespaces).isEmpty { done.append(""); continue }
                guard let turkish = translateLabelLoosely(String(part)) else { return nil }
                done.append(turkish)
                any = true
            }
            guard any else { return nil }
            return done.joined(separator: " \(marker) ").split(separator: " ").joined(separator: " ")
        }
        if let direct = translateLabel(label) { return direct }
        let words = label.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        // Baştaki kırıntı tuş adıysa ("R3 LOOK BEHIND") kalır; değilse ("1 Map", "pi Settings") atılır.
        if words[0].count <= 2, let rest = translateLabel(words.dropFirst().joined(separator: " ")) {
            return ButtonIcons.isButtonName(words[0]) ? words[0] + " " + rest : rest
        }
        if words[words.count - 1].count <= 2, let head = translateLabel(words.dropLast().joined(separator: " ")) {
            return head + " " + words[words.count - 1]
        }
        return nil
    }

    /// Menüdeki kısa etiketin Türkçesi ("OFF" → "KAPALI", "Off" → "Kapalı", "off" → "kapalı"): etiketin tamamı sözlükte
    /// olmalı (büyük/küçük harf fark etmez); biçimi Türkçe kurallarıyla korunur (i → İ). Sözlükte yoksa nil.
    static func translateLabel(_ label: String) -> String? {
        let words = label.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:!?"))
            .trimmingCharacters(in: .whitespaces)
        guard words.contains(where: \.isLetter) else { return nil }
        let key = latin(words).uppercased(with: Locale(identifier: "en_US_POSIX"))
        guard let turkish = commands[key] ?? labels[key] else { return nil }
        let letters = words.filter(\.isLetter)
        let turkishLocale = Locale(identifier: "tr_TR")
        if letters.allSatisfy(\.isUppercase) { return turkish.uppercased(with: turkishLocale) }
        if letters.allSatisfy(\.isLowercase) { return turkish.lowercased(with: turkishLocale) }
        return turkish
    }
}
