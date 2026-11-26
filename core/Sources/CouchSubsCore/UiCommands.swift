// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// İngilizce tuş çubuğundaki kısa komutlar (GameTranslator UiPrompts, bkz. THIRD-PARTY-NOTICES.md).
enum UiCommands {
    private static let commands: [String: String] = [
        "ADD MARKER": "İşaret ekle", "SET DESTINATION": "Hedef belirle", "REMOVE DESTINATION": "Hedefi kaldır",
        "RECENTER": "Ortala", "2D VIEW": "2B görünüm", "3D VIEW": "3B görünüm",
        "ZOOM": "Yakınlaştır", "EXIT": "Çık", "BACK": "Geri",
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
        // GTA 6 duraklatma menüsü ve harita ipuçları (Sinan Bey, 24 Kas: sabit karşılıklar, çeviri motorundan önce).
        "ADD WAYPOINT": "İşaret ekle", "RETRY CHECKPOINT": "Kontrol noktasını yeniden dene",
        "RESTART MISSION": "Görevi yeniden başlat", "QUIT MISSION": "Görevden çık",
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
        // GTA 6 telefonu ve bar menüsü ("SCROLL / SEND / BACK", "TIP $10 / ORDER / BARTENDER").
        "SEND": "Gönder", "TIP": "Bahşiş ver", "BARTENDER": "Barmen",
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
        "STATS": "İstatistikler", "GAME": "Oyun", "BRIEF": "Özet", "PROGRESS": "İlerleme", "VEHICLES": "Araçlar",
        "ANIMALS": "Hayvanlar",
        // Ayarlar › Kumanda şeması önizlemesi (#1362): kısa arayüz komutları diyalog gibi çevriliyordu ("RUN" → "KAÇ!",
        // "MOVE" → "ÇEKİL!", "DETONATE EXPLOSIVES" → "DETONATE EXPLOSIVES YAP"). Etiket olarak sabit karşılıklar.
        "RUN": "Koş", "MOVE": "Hareket", "SPRINT": "Depar", "WALK": "Yürü", "JUMP": "Zıpla", "CLIMB": "Tırman",
        "CROUCH": "Eğil", "COVER": "Siper", "SHOOT": "Ateş et", "AIM": "Nişan al", "MELEE": "Yakın dövüş",
        "RELOAD": "Şarjör değiştir", "HOLSTER": "Silahı kılıfa koy", "CELLPHONE": "Cep telefonu", "PHONE": "Telefon",
        "RADIO CONTROLS": "Radyo kontrolleri", "RADIO MENU": "Radyo menüsü", "RADIO": "Radyo", "OBJECTIVE": "Hedef",
        "MINIMAP": "Mini harita", "DETONATE EXPLOSIVES": "Patlayıcıları patlat", "DETONATE": "Patlat",
        "LOADOUT": "Teçhizat", "QUICK NAVIGATION": "Hızlı gezinme", "PARTNER MENU": "Partner menüsü",
        "PAUSE": "Duraklat", "LOOK BEHIND": "Arkana bak", "WEAPON WHEEL": "Silah çarkı",
        "INTERACTION MENU": "Etkileşim menüsü", "ACCELERATE": "Hızlan", "BRAKE": "Fren", "REVERSE": "Geri vites",
        "HANDBRAKE": "El freni", "HORN": "Korna", "HEADLIGHTS": "Farlar", "SWIM": "Yüz", "TAKE COVER": "Siper al",
        "THROW": "Fırlat", "SPECIAL ABILITY": "Özel yetenek", "SWITCH CHARACTER": "Karakter değiştir",
        "SWITCH WEAPON": "Silah değiştir", "CONTROLS": "Kontroller",
        // Haritanın görev listesi ve görev kartı (#1365): "GOAL" motordan "GOL." dönüyordu; arayüz etiketi olarak sabit.
        "GOAL": "Hedef", "GOALS": "Hedefler", "OBJECTIVES": "Hedefler", "MISSION": "Görev", "MISSIONS": "Görevler",
        "STORY": "Hikâye", "OPTIONAL": "İsteğe bağlı", "REWARD": "Ödül", "REWARDS": "Ödüller",
    ]

    /// Görev başlığı: emir fiili ve ardında özel ad ("Hit Kingpin Bowling", "Meet Bret"). Motor özel adı görüp başlığı
    /// olduğu gibi döndürünce başlık hiç çevrilmiyordu (#1365); yalnız fiil çevrilir, ad olduğu gibi kalır ve Türkçe eki
    /// alır ("Kingpin Bowling'i Soy", "Bret ile Buluş"). Adın her sözcüğü büyük harfle başlar, yalnız harf; bağlaç/edat
    /// ("for", "the") ya da iyelik ("Vicki's") varsa başlık bu kalıba girmez. Yalnız motor çevirmediğinde kullanılır
    /// (Windows/Android aynı).
    private static let titleVerbs: [(verb: String, suffix: String, turkish: String)] = [
        ("hit", "i", "Soy"), ("rob", "i", "Soy"), ("meet", "", "ile Buluş"), ("visit", "i", "Ziyaret Et"),
        ("find", "i", "Bul"), ("check out", "a", "Göz At"), ("go to", "a", "Git"), ("head to", "a", "Git"),
        ("return to", "a", "Dön"), ("call", "i", "Ara"), ("follow", "i", "Takip Et"), ("steal", "i", "Çal"),
        ("protect", "i", "Koru"), ("chase", "i", "Kovala"), ("rescue", "i", "Kurtar"), ("defend", "i", "Savun"),
        ("explore", "i", "Keşfet"), ("investigate", "i", "Araştır"), ("pick up", "i", "Al"), ("help", "a", "Yardım Et"),
    ]

    static func missionTitle(_ title: String) -> String? {
        let words = title.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard (2...6).contains(words.count), !TextStyleSampler.isUpper(title) else { return nil }
        let posix = Locale(identifier: "en_US_POSIX")
        for entry in titleVerbs {
            let verb = entry.verb.split(separator: " ").map(String.init)
            guard words.count > verb.count,
                  zip(words, verb).allSatisfy({ $0.0.lowercased(with: posix) == $0.1 }),
                  words[0].first?.isUppercase == true else { continue }
            let name = Array(words.dropFirst(verb.count))
            guard name.allSatisfy({ word in
                word.first?.isUppercase == true && word.count >= 2 && word.allSatisfy { $0.isLetter || $0 == "-" }
            }) else { return nil }
            let joined = name.joined(separator: " ")
            let object = entry.suffix.isEmpty ? joined : TurkishSuffix.attach(joined, suffix: entry.suffix)
            return object + " " + entry.turkish
        }
        return nil
    }

    /// Etiketin sonunda önündeki sözcüklerden ayrı duran tek harf (yazı tanımanın tuş simgesinden okuduğu harf, #1362:
    /// "RADIO CONTROLS f" → "RADYO KONTROLLERİ F", "RADIO MENU (I") atılır. Yalnız en az iki sözcüklü (iki harften uzun)
    /// etiketin sonunda ve şu durumlarda: harf parantezle okunmuş; BÜYÜK HARFLİ etiketin sonunda küçük harf; ya da BÜYÜK
    /// HARFLİ etiketin sonunda tuş yüzü harfi (A, B, X, Y, F, E, Q, R, L, I, O). Harfin sözcüğe ait olduğu etiket ("PRESS A",
    /// "PLAN B"; önündeki sözcük `glyphOwners`'da) dokunulmaz (Windows/Android aynı).
    static func withoutKeyGlyph(_ label: String) -> String {
        let tokens = label.split(separator: " ").map(String.init)
        guard tokens.count >= 3, let last = tokens.last else { return label }
        let core = last.trimmingCharacters(in: CharacterSet(charactersIn: "([{)]}"))
        guard core.count == 1, let letter = core.first, letter.isLetter, letter.isASCII else { return label }
        let head = Array(tokens.dropLast())
        let posix = Locale(identifier: "en_US_POSIX")
        guard head.filter({ $0.filter(\.isLetter).count >= 2 }).count >= 2,
              !glyphOwners.contains(head[head.count - 1].uppercased(with: posix)) else { return label }
        let letters = head.joined().filter(\.isLetter)
        let upperHead = !letters.isEmpty && letters.allSatisfy(\.isUppercase)
        let bracketed = last != core
        let glyph = bracketed || (upperHead && (letter.isLowercase || "ABXYFEQRLIO".contains(letter)))
        return glyph ? head.joined(separator: " ") : label
    }

    /// Ardındaki tek harf kendisine ait olan sözcükler ("PRESS A", "PLAN B", "BUTTON X").
    private static let glyphOwners: Set<String> = [
        "PRESS", "HOLD", "TAP", "USE", "KEY", "BUTTON", "PLAN", "TYPE", "CLASS", "GRADE", "PART", "SIDE", "VITAMIN",
        "ROUTE", "LEVEL", "ZONE", "AREA", "SECTOR", "GATE", "BLOCK", "TEAM", "GROUP", "OPTION", "CHAPTER", "ACT",
        "STAGE", "SEASON", "EPISODE", "FLOOR", "ROOM", "SLOT", "PLAYER", "MODE", "SECTION",
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
        if let tabs = translateTabs(label) { return tabs }
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

    /// Tek satır okunan sekme çubuğu ("JASON & LUCIA MAP BRIEF"): "AD & AD" olduğu gibi kalır, kalan her sözcük sözlükte
    /// olmalı. Motora gitmez, her karede aynı çeviri (beta.100: aynı çubuk "MAP ÖZET", "HARİTA ÖZET", "MAP ÖZETİ" oluyordu).
    /// Yalnız BÜYÜK HARFLİ yazıda (Windows/Android ile aynı).
    static func translateTabs(_ label: String) -> String? {
        let words = label.split(separator: " ").map(String.init)
        guard words.count >= 2, TextStyleSampler.isUpper(label) else { return nil }
        var out: [String] = []
        var i = 0
        while i < words.count {
            if i + 2 < words.count, words[i + 1] == "&" {
                out += words[i...(i + 2)]
                i += 3
                continue
            }
            guard let word = translateLabel(words[i]) else { return nil }
            out.append(word)
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// Menüdeki kısa etiketin Türkçesi ("OFF" → "KAPALI", "Off" → "Kapalı", "off" → "kapalı"): etiketin tamamı sözlükte
    /// olmalı (büyük/küçük harf fark etmez); biçimi Türkçe kurallarıyla korunur (i → İ). Sözlükte yoksa nil.
    static func translateLabel(_ label: String) -> String? {
        let words = label.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:!?"))
            .trimmingCharacters(in: .whitespaces)
        guard words.contains(where: \.isLetter) else { return nil }
        let key = latin(words).uppercased(with: Locale(identifier: "en_US_POSIX"))
        guard let turkish = commands[key] ?? labels[key] ?? commands[nearKey(key) ?? ""] ?? labels[nearKey(key) ?? ""] else { return nil }
        let letters = words.filter(\.isLetter)
        let turkishLocale = Locale(identifier: "tr_TR")
        if letters.allSatisfy(\.isUppercase) { return turkish.uppercased(with: turkishLocale) }
        if letters.allSatisfy(\.isLowercase) { return turkish.lowercased(with: turkishLocale) }
        // Her sözcüğü büyük harfle başlayan etiket ("Set Destination", "Photo Studio"): Türkçesi de öyle ("Hedef Belirle").
        let titled = words.split(separator: " ").allSatisfy { $0.first?.isUppercase == true || !$0.contains(where: \.isLetter) }
        if titled, words.contains(" ") {
            return turkish.split(separator: " ").map { word in
                String(word.prefix(1)).uppercased(with: turkishLocale) + word.dropFirst()
            }.joined(separator: " ")
        }
        return turkish
    }

    /// Yazı tanımanın tek harfini yanlış okuduğu etiket ("SET DESTINATlON", "SETTINQS"): en az yedi harflik anahtarlardan
    /// tek harf farkla (değişen, eksik ya da fazla) eşleşen tek anahtar; birden çoğu eşleşirse nil (Windows/Android aynı).
    static func nearKey(_ key: String) -> String? {
        guard key.count >= 7 else { return nil }
        let found = Set(commands.keys).union(labels.keys).filter { $0.count >= 7 && abs($0.count - key.count) <= 1 && oneEdit($0, key) }
        return found.count == 1 ? found.first : nil
    }

    /// İki yazı en çok bir düzenlemeyle (bir harf değişmesi, eklenmesi ya da silinmesi) aynı mı.
    static func oneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x == y { return true }
        if x.count == y.count { return zip(x, y).filter { $0 != $1 }.count == 1 }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        guard long.count == short.count + 1 else { return false }
        var i = 0, j = 0, skipped = false
        while i < long.count, j < short.count {
            if long[i] == short[j] { i += 1; j += 1 }
            else if skipped { return false }
            else { skipped = true; i += 1 }
        }
        return true
    }
}
