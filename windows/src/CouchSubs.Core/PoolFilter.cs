// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text;

namespace CouchSubs.Core;

/// <summary>
/// Ortak havuza gidecek satırın süzgeci: havuz yalnız pakette olmayan İngilizce oyun konuşmalarını toplamalı. Sunucudaki
/// havuzda (Kasım 2026) en çok görülen "satırlar" PS5'in Türkçe arayüzü ve onun yazı tanıma bozmaları ("Oturum Açtı",
/// "Oturum Aqtl", "Sifirlama Seqenekleri", "PS5 Sistemini Yeniden Baslat"), yarım okumalar ("GO to the", "it Auto V's
/// Story Mode.") ve oyun arayüzü ("PHOTO MODE SELECT") idi. Mac'teki CouchSubsCore/PoolFilter.swift ve sunucudaki
/// server/pool/src/filter.js ile aynı kurallar.
/// </summary>
public static class PoolFilter
{
    /// <summary>Bundan kısa ya da daha az sözcüklü satır ancak cümle noktalamasıyla bitiyorsa alınır ("Get down!").</summary>
    public const int MinShortLength = 15;
    public const int MinShortWords = 3;
    /// <summary>Tümü büyük harfli, noktalamasız ve bu kadar ya da daha az sözcüklü satır arayüz yazısıdır ("FREE MONTH OF GTA+").</summary>
    public const int MaxCapsUiWords = 6;

    /// <summary>Satır İngilizce oyun konuşmasına benziyor mu (Türkçe, sistem yazısı ya da yarım okuma değil).</summary>
    public static bool Accepts(string text) => !IsFragment(text) && !LooksTurkish(text) && !LooksLikeSystemText(text);

    // --- Yarım okumalar ---

    /// <summary>Sonu bu sözcükle biten (noktalamasız) satır cümlenin ortasında kesilmiştir ("Take out the").</summary>
    internal static readonly HashSet<string> DanglingWords = new(StringComparer.Ordinal)
    {
        "the", "a", "an", "to", "of", "and", "or", "but", "with", "for", "from", "my", "your", "his", "her", "their", "our",
        "at", "in", "on", "by", "into", "than", "that", "if", "as", "is", "are", "was", "were",
    };

    /// <summary>
    /// Yarım ya da arayüz okuması: kısa ve noktalamasız, küçük harfle başlayan ("it Auto V's Story Mode."), bağlaçla ya da
    /// tanımlıkla biten, ya da tümü büyük harfli kısa ve noktalamasız ("PHOTO MODE SELECT").
    /// </summary>
    internal static bool IsFragment(string text)
    {
        text = text.Trim();
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Where(w => w.Any(char.IsLetter)).ToList();
        var ends = SubtitleStabilizer.EndsSentence(text);
        if (!ends && (words.Count < MinShortWords || new StringInfo(text).LengthInTextElements < MinShortLength)) return true;
        if (text.Length > 0 && char.IsLetter(text[0]) && char.IsLower(text[0])) return true;
        if (ends) return false;
        if (words.Count > 0 && DanglingWords.Contains(new string([.. words[^1].ToLowerInvariant().Where(char.IsLetter)]))) return true;
        var letters = text.Where(char.IsLetter).ToList();
        return letters.Count > 0 && !letters.Any(char.IsLower) && words.Count <= MaxCapsUiWords;
    }

    // --- Türkçe ---

    /// <summary>Yalnız Türkçede (ve yakın dillerde) geçen harfler.</summary>
    private const string TurkishOnly = "ğĞşŞıİ";
    /// <summary>Türkçede sık, İngilizce oyun metninde yalnız yabancı adlarda ("Müller", "Schrödinger", "façade") geçen harfler.</summary>
    private const string TurkishShared = "üÜöÖçÇ";

    /// <summary>
    /// PS5'in Türkçe arayüzünde sık geçen, İngilizcede olmayan sözcükler (<see cref="Fold"/> edilmiş hâlleriyle
    /// karşılaştırılır; "ile" yok: katlanınca İngilizce "lie" ile aynı olur).
    /// </summary>
    internal static readonly string[] TurkishWords = new[]
    {
        "icin", "lutfen", "bekleyin", "oyunu", "oyun", "oyunlar", "kapat", "ekran", "ekranda", "ekrani", "sistemini",
        "yeniden", "baslat", "ayarlar", "ayarlari", "kupalar", "kupa", "oturum", "acti", "kapatti", "secenekleri",
        "sifirlama", "tut", "kesfet", "ilgili", "takip", "edin", "ilerlemenizi", "cikanlar", "goruntusu", "kaydedildi",
        "bildirimler", "arkadaslar", "medya", "galerisi", "indiriliyor", "guncelleme", "kitaplik", "denetleyici",
    }.Select(word => string.Concat(Fold(word))).ToArray();

    /// <summary>
    /// Türkçe görünen satır: Türkçeye özgü harf (ğ, ş, ı, İ), iki ve daha çok ü/ö/ç ("Ekran görüntüsü"), ya da harfleri
    /// yazı tanımada bozulmuş Türkçe arayüz sözcüklerinden en az ikisi ("Sifirlama Seqenekleri", "Oturum Aqtl").
    /// </summary>
    internal static bool LooksTurkish(string text)
    {
        if (text.Any(c => TurkishOnly.Contains(c))) return true;
        if (text.Count(c => TurkishShared.Contains(c)) >= 2) return true;
        return Fold(text).Count(word => TurkishWords.Any(known => IsClose(word, known))) >= 2;
    }

    // --- Sistem yazıları ---

    /// <summary>
    /// PS5'in kendi bildirim ve arayüz yazıları (İngilizce ve Türkçe); <see cref="Fold"/> edilmiş satırda tam sözcük olarak
    /// aranır ("designed in" "signed in" sayılmaz).
    /// </summary>
    internal static readonly string[] SystemPhrases = new[]
    {
        "signed in", "signed out", "earned a trophy", "trophy earned", "trophy unlocked", "screenshot saved",
        "video clip saved", "media gallery", "is now online", "joined the party", "left the party", "remote play",
        "controller battery", "controller is disconnected", "controller disconnected", "press the ps button",
        "playstation network", "download complete", "installation complete", "update available", "turn off your console",
        "cloud save", "do not quit", "photo mode", "story mode", "press any button",
        "oturum acti", "oturum kapatti", "ekran ve video", "oyunu kapat", "ana ekranda tut", "yeniden baslat",
        "sifirlama secenekleri", "lutfen bekleyin", "ilerlemenizi takip",
    }.Select(phrase => string.Join(' ', Fold(phrase))).ToArray();

    internal static bool LooksLikeSystemText(string text)
    {
        var padded = " " + string.Join(' ', Fold(text)) + " ";
        return SystemPhrases.Any(phrase => padded.Contains(" " + phrase + " ", StringComparison.Ordinal));
    }

    // --- Katlama ---

    /// <summary>
    /// Karşılaştırma için sadeleştirilmiş sözcükler: küçük harf, aksansız (ç→c, ş→s, ğ→g, ö→o, ü→u, ı/İ→i) ve yazı
    /// tanımanın sık karıştırdığı harfler birleşik (q→c: "Seqenekleri"; l ve 1→i: "Aqtl"). Yalnız eşleştirme içindir.
    /// </summary>
    internal static List<string> Fold(string text)
    {
        var plain = text.ToLowerInvariant().Replace('ı', 'i').Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(plain.Length);
        foreach (var c in plain)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.NonSpacingMark) continue;
            builder.Append(c switch { 'q' => 'c', 'l' or '1' => 'i', _ => c });
        }
        var words = new List<string>();
        var word = new StringBuilder();
        foreach (var c in builder.ToString())
        {
            if (char.IsLetterOrDigit(c)) word.Append(c);
            else if (word.Length > 0) { words.Add(word.ToString()); word.Clear(); }
        }
        if (word.Length > 0) words.Add(word.ToString());
        return words;
    }

    /// <summary>Aynı sözcük mü: altı ve daha uzun harflide bir harf farkına (ekleme, silme, değiştirme) izin verilir.</summary>
    internal static bool IsClose(string a, string b)
    {
        if (a == b) return true;
        if (a.Length < 6 || b.Length < 6 || Math.Abs(a.Length - b.Length) > 1) return false;
        int i = 0, j = 0, edits = 0;
        while (i < a.Length && j < b.Length)
        {
            if (a[i] == b[j]) { i++; j++; continue; }
            if (++edits > 1) return false;
            if (a.Length > b.Length) i++;
            else if (b.Length > a.Length) j++;
            else { i++; j++; }
        }
        return edits + (a.Length - i) + (b.Length - j) <= 1;
    }
}
