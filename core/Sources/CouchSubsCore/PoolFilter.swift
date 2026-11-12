// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Ortak havuza gidecek satırın süzgeci: havuz yalnız pakette olmayan İngilizce oyun konuşmalarını toplamalı. Sunucudaki
/// havuzda (Kasım 2026) en çok görülen "satırlar" PS5'in Türkçe arayüzü ve onun yazı tanıma bozmaları ("Oturum Açtı",
/// "Oturum Aqtl", "Sifirlama Seqenekleri", "PS5 Sistemini Yeniden Baslat"), yarım okumalar ("GO to the", "it Auto V's
/// Story Mode.") ve oyun arayüzü ("PHOTO MODE SELECT") idi. Windows'taki CouchSubs.Core/PoolFilter.cs ve sunucudaki
/// server/pool/src/filter.js ile aynı kurallar.
public enum PoolFilter {
    /// Bundan kısa ya da daha az sözcüklü satır ancak cümle noktalamasıyla bitiyorsa alınır ("Get down!").
    public static let minShortLength = 15
    public static let minShortWords = 3
    /// Tümü büyük harfli, noktalamasız ve bu kadar ya da daha az sözcüklü satır arayüz yazısıdır ("FREE MONTH OF GTA+").
    public static let maxCapsUIWords = 6

    /// Satır İngilizce oyun konuşmasına benziyor mu (Türkçe, sistem yazısı ya da yarım okuma değil).
    public static func accepts(_ text: String) -> Bool {
        !isFragment(text) && !looksTurkish(text) && !looksLikeSystemText(text)
    }

    // MARK: - Yarım okumalar

    /// Sonu bu sözcükle biten (noktalamasız) satır cümlenin ortasında kesilmiştir ("Take out the").
    static let danglingWords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "or", "but", "with", "for", "from", "my", "your", "his", "her", "their", "our",
        "at", "in", "on", "by", "into", "than", "that", "if", "as", "is", "are", "was", "were",
    ]

    /// Yarım ya da arayüz okuması: kısa ve noktalamasız, küçük harfle başlayan ("it Auto V's Story Mode."), bağlaçla ya da
    /// tanımlıkla biten, ya da tümü büyük harfli kısa ve noktalamasız ("PHOTO MODE SELECT").
    static func isFragment(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
        let ends = SubtitleStabilizer.endsSentence(text)
        if !ends && (words.count < minShortWords || text.count < minShortLength) { return true }
        if let first = text.first, first.isLetter, first.isLowercase { return true }
        guard !ends else { return false }
        if let last = words.last {
            let word = String(last).lowercased().filter(\.isLetter)
            if danglingWords.contains(word) { return true }
        }
        let letters = text.filter(\.isLetter)
        return !letters.isEmpty && !letters.contains(where: \.isLowercase) && words.count <= maxCapsUIWords
    }

    // MARK: - Türkçe

    /// Yalnız Türkçede (ve yakın dillerde) geçen harfler.
    static let turkishOnly: Set<Character> = ["ğ", "Ğ", "ş", "Ş", "ı", "İ"]
    /// Türkçede sık, İngilizce oyun metninde yalnız yabancı adlarda ("Müller", "Schrödinger", "façade") geçen harfler.
    static let turkishShared: Set<Character> = ["ü", "Ü", "ö", "Ö", "ç", "Ç"]

    /// PS5'in Türkçe arayüzünde sık geçen, İngilizcede olmayan sözcükler (`fold` edilmiş hâlleriyle karşılaştırılır;
    /// "ile" yok: katlanınca İngilizce "lie" ile aynı olur).
    static let turkishWords: [String] = [
        "icin", "lutfen", "bekleyin", "oyunu", "oyun", "oyunlar", "kapat", "ekran", "ekranda", "ekrani", "sistemini",
        "yeniden", "baslat", "ayarlar", "ayarlari", "kupalar", "kupa", "oturum", "acti", "kapatti", "secenekleri",
        "sifirlama", "tut", "kesfet", "ilgili", "takip", "edin", "ilerlemenizi", "cikanlar", "goruntusu", "kaydedildi",
        "bildirimler", "arkadaslar", "medya", "galerisi", "indiriliyor", "guncelleme", "kitaplik", "denetleyici",
    ].map { fold($0).joined() }

    /// Türkçe görünen satır: Türkçeye özgü harf (ğ, ş, ı, İ), iki ve daha çok ü/ö/ç ("Ekran görüntüsü"), ya da harfleri
    /// yazı tanımada bozulmuş Türkçe arayüz sözcüklerinden en az ikisi ("Sifirlama Seqenekleri", "Oturum Aqtl").
    static func looksTurkish(_ text: String) -> Bool {
        if text.contains(where: turkishOnly.contains) { return true }
        if text.filter(turkishShared.contains).count >= 2 { return true }
        let hits = foldedWords(text).filter { word in turkishWords.contains { isClose(word, $0) } }.count
        return hits >= 2
    }

    // MARK: - Sistem yazıları

    /// PS5'in kendi bildirim ve arayüz yazıları (İngilizce ve Türkçe); `fold` edilmiş satırda tam sözcük olarak aranır
    /// ("designed in" "signed in" sayılmaz).
    static let systemPhrases: [String] = [
        "signed in", "signed out", "earned a trophy", "trophy earned", "trophy unlocked", "screenshot saved",
        "video clip saved", "media gallery", "is now online", "joined the party", "left the party", "remote play",
        "controller battery", "controller is disconnected", "controller disconnected", "press the ps button",
        "playstation network", "download complete", "installation complete", "update available", "turn off your console",
        "cloud save", "do not quit", "photo mode", "story mode", "press any button",
        "oturum acti", "oturum kapatti", "ekran ve video", "oyunu kapat", "ana ekranda tut", "yeniden baslat",
        "sifirlama secenekleri", "lutfen bekleyin", "ilerlemenizi takip",
    ].map { fold($0).joined(separator: " ") }

    static func looksLikeSystemText(_ text: String) -> Bool {
        let padded = " " + foldedWords(text).joined(separator: " ") + " "
        return systemPhrases.contains { padded.contains(" \($0) ") }
    }

    // MARK: - Katlama

    /// Karşılaştırma için sadeleştirilmiş sözcükler: küçük harf, aksansız (ç→c, ş→s, ğ→g, ö→o, ü→u, ı/İ→i) ve yazı
    /// tanımanın sık karıştırdığı harfler birleşik (q→c: "Seqenekleri"; l ve 1→i: "Aqtl"). Yalnız eşleştirme içindir.
    static func fold(_ text: String) -> [String] {
        let plain = text.lowercased().replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive], locale: nil)
        let mapped = String(plain.map { character -> Character in
            switch character {
            case "q": "c"
            case "l", "1": "i"
            default: character
            }
        })
        return mapped.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func foldedWords(_ text: String) -> [String] { fold(text) }

    /// Aynı sözcük mü: altı ve daha uzun harflide bir harf farkına (ekleme, silme, değiştirme) izin verilir.
    static func isClose(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 6, b.count >= 6, abs(a.count - b.count) <= 1 else { return false }
        let x = Array(a), y = Array(b)
        var i = 0, j = 0, edits = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count > y.count { i += 1 } else if y.count > x.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }
}
