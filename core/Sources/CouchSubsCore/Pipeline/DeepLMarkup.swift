// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Sözlük terimlerini DeepL'e "çevirme" etiketiyle gönderir (Windows: CouchSubs.Core/DeepLMarkup.cs, aynı kurallar).
/// Terim Türkçesiyle (`keep` adlarında kendisiyle) değiştirilip `<x>…</x>` içine alınır; istek `tag_handling: xml` ve
/// `ignore_tags: ["x"]` ile gider, DeepL etiket içini değiştirmez. Etiketsiz gönderilince DeepL "Soul began…" gibi
/// cümlelerde adı sıradan sözcük gibi çeviriyor, ardından gelen sözcüğü de adın parçası sanıyordu ("began" → "Pegan";
/// Phantom Blade Zero, 2026-11-13).
public enum DeepLMarkup {
    public static let tag = "x"

    /// Sözlükte geçen terim varsa etiketli (XML'e kaçırılmış) metin, yoksa nil.
    public static func wrap(_ text: String, glossary: Glossary) -> String? {
        let matches = glossary.find(text)
        guard !matches.isEmpty else { return nil }
        let string = text as NSString
        var result = ""
        var cursor = 0
        for match in matches {
            result += escape(string.substring(with: NSRange(location: cursor, length: match.start - cursor)))
            result += "<\(tag)>\(escape(match.turkish))</\(tag)>"
            cursor = match.start + match.length
        }
        result += escape(string.substring(from: cursor))
        return result
    }

    /// Etiketsiz gönderilen cümle de etiketli istekte XML olarak okunur; özel karakterleri kaçırılır.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// DeepL'in döndürdüğü etiketli çeviriden düz metin.
    public static func unwrap(_ text: String) -> String {
        text.replacingOccurrences(of: "<\(tag)>", with: "").replacingOccurrences(of: "</\(tag)>", with: "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Terim içeren satırın önbellek anahtarına sözlüğün izi girer; sözlük değişince yeniden çevrilir.
    public static func cacheKey(_ text: String, glossary: Glossary) -> String {
        glossary.matches(text) ? glossary.fingerprint + "\u{1F}" + text : text
    }
}
