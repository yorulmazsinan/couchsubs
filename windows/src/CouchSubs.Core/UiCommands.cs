// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Oyunların tuş çubuğundaki ve etkileşim istemlerindeki kısa büyük harfli komutların Türkçesi ("OPEN ✕", "PUT DOWN ○",
/// "SET DESTINATION ✕ EXIT ○"). Çeviri motoru bu tek sözcükleri bağlamsız görünce yanlış anlıyordu ("OPEN" → "AÇIK",
/// "DRINK" → "İÇECEK") ya da hiç çevirmiyordu; sözlükteki komut motora gitmez, tuş simgeleri yerinde kalır.
/// Sözlük GameTranslator'ın (AGPL-3.0) UiPrompts sınıfından alındı.
/// </summary>
public static class UiCommands
{
    private static readonly Dictionary<string, string> Commands = new(StringComparer.Ordinal)
    {
        ["ADD MARKER"] = "İşaret ekle", ["SET DESTINATION"] = "Hedef belirle", ["REMOVE DESTINATION"] = "Hedefi kaldır",
        ["RECENTER"] = "Ortala", ["2D VIEW"] = "2B görünüm", ["3D VIEW"] = "3B görünüm", ["ZOOM"] = "Yakınlaştır",
        ["EXIT"] = "Çıkış", ["BACK"] = "Geri", ["SELECT"] = "Seç", ["CLOSE"] = "Kapat", ["CLOSE MENU"] = "Menüyü kapat",
        ["MENU"] = "Menü", ["OPEN"] = "Aç", ["NEXT PAGE"] = "Sonraki sayfa", ["PREVIOUS PAGE"] = "Önceki sayfa",
        ["SHOW TEXT"] = "Metni göster", ["SHOW"] = "Göster", ["FLIP"] = "Çevir", ["PUT DOWN"] = "Bırak", ["PICK UP"] = "Al",
        ["DRINK"] = "İç", ["EAT"] = "Ye", ["WEAR"] = "Giy", ["TAKE OFF"] = "Çıkar", ["BUY"] = "Satın al", ["SELL"] = "Sat",
        ["PAY"] = "Öde", ["PAY LATER"] = "Sonra öde", ["PAY NOW"] = "Şimdi öde", ["ACCEPT"] = "Kabul et",
        ["DECLINE"] = "Reddet", ["YES"] = "Evet", ["NO"] = "Hayır", ["CONFIRM"] = "Onayla", ["CANCEL"] = "İptal",
        ["GOODBYE"] = "Hoşça kal", ["GREET"] = "Selamla", ["TALK"] = "Konuş", ["DEFUSE"] = "Yatıştır",
        ["PROVOKE"] = "Kışkırt", ["WARN"] = "Uyar", ["OFFER RIDE"] = "Arabaya çağır", ["ENTER"] = "Gir",
        ["LEAVE"] = "Ayrıl", ["SKIP"] = "Geç", ["CONTINUE"] = "Devam et", ["RETRY"] = "Tekrar dene",
        ["RESTORE ALL"] = "Hepsini geri yükle", ["RESTORE DEFAULT"] = "Varsayılana döndür", ["PREVIEW"] = "Önizle",
        ["PAUSE PREVIEW"] = "Önizlemeyi durdur", ["ADJUST"] = "Ayarla", ["SCROLL"] = "Kaydır", ["REFUEL"] = "Yakıt al",
        ["LIFT"] = "Kaldır", ["ORDER"] = "Sipariş ver", ["MAYBE LATER"] = "Belki sonra", ["PHOTO STUDIO"] = "Fotoğraf stüdyosu",
        ["REMINDERS"] = "Hatırlatıcılar", ["ROTATE"] = "Döndür", ["INTERACT"] = "Etkileşim", ["USE"] = "Kullan",
        ["KNOCK"] = "Kapıyı çal", ["CALL"] = "Ara", ["HANG UP"] = "Telefonu kapat", ["ANSWER"] = "Cevapla",
        ["IGNORE"] = "Yoksay", ["REPLY"] = "Yanıtla", ["DELETE"] = "Sil", ["SAVE"] = "Kaydet", ["VIEW"] = "Görüntüle",
        ["INSPECT"] = "İncele", ["SEARCH"] = "Ara", ["HIDE"] = "Saklan", ["JOIN"] = "Katıl", ["TERMS"] = "Koşullar",
        ["MARKERS"] = "İşaretler", ["DROP"] = "Bırak", ["EQUIP"] = "Kuşan", ["UNEQUIP"] = "Çıkar", ["STORE"] = "Dükkân",
        ["HELP"] = "Yardım", ["OPTIONS"] = "Seçenekler", ["CAMERA"] = "Kamera", ["TOGGLE"] = "Aç / kapat", ["GRAB"] = "Tut",
        ["SIT"] = "Otur", ["STAND UP"] = "Kalk", ["SLEEP"] = "Uyu", ["SHOWER"] = "Duş al", ["TURN OFF"] = "Kapat",
        ["TURN ON"] = "Aç", ["WATCH"] = "İzle", ["LISTEN"] = "Dinle", ["DRIVE"] = "Sür", ["GET IN"] = "Bin",
        ["GET OUT"] = "İn", ["STEAL"] = "Çal", ["HACK"] = "Hackle", ["LOOT"] = "Yağmala", ["COLLECT"] = "Topla",
    };

    /// <summary>
    /// Menülerin kısa etiketleri (ayar değerleri, sekme ve düğme adları). <see cref="Commands"/>'ta olan bir etiketin
    /// orada kayıtlı Türkçesi kullanılır; bunlar yalnız orada olmayanlardır.
    /// </summary>
    private static readonly Dictionary<string, string> Labels = new(StringComparer.Ordinal)
    {
        ["ON"] = "Açık", ["OFF"] = "Kapalı", ["LOAD"] = "Yükle", ["SETTINGS"] = "Ayarlar", ["MAP"] = "Harita",
        ["RESUME"] = "Sürdür", ["QUIT"] = "Çık", ["NEXT"] = "İleri", ["PREVIOUS"] = "Önceki", ["ALL"] = "Tümü",
        ["NONE"] = "Hiçbiri", ["DEFAULT"] = "Varsayılan", ["APPLY"] = "Uygula", ["RESET"] = "Sıfırla",
        ["INVENTORY"] = "Envanter", ["OUTFITS"] = "Kıyafetler", ["OUTFIT"] = "Kıyafet", ["WEAPONS"] = "Silahlar",
        ["STATS"] = "İstatistikler",
    };

    /// <summary>
    /// Menüdeki kısa etiketin Türkçesi ("OFF" → "KAPALI", "Off" → "Kapalı", "off" → "kapalı"): etiketin tamamı sözlükte
    /// olmalı (büyük/küçük harf fark etmez); biçimi Türkçe kurallarıyla korunur (i → İ). Sözlükte yoksa null.
    /// </summary>
    public static string? TranslateLabel(string label)
    {
        var words = label.Trim().Trim('.', ',', ':', '!', '?').Trim();
        if (words.Length == 0 || !words.Any(char.IsLetter)) return null;
        var key = words.ToUpperInvariant();
        if (!Commands.TryGetValue(key, out var turkish) && !Labels.TryGetValue(key, out turkish)) return null;
        var letters = words.Where(char.IsLetter).ToList();
        if (letters.All(char.IsUpper)) return TurkishUpper(turkish);
        if (letters.All(char.IsLower)) return TurkishLower(turkish);
        return turkish;
    }

    private static string TurkishUpper(string text) => text.Replace('i', 'İ').Replace('ı', 'I').ToUpperInvariant();

    private static string TurkishLower(string text) => text.Replace('I', 'ı').Replace('İ', 'i').ToLowerInvariant();

    /// <summary>
    /// Tuş çubuğunun Türkçesi: simgelerle (<see cref="ButtonIcons.Marker"/>) ayrılan her parça sözlükte olan büyük harfli
    /// bir komutsa simgeler yerinde kalarak çevrilir; tek başına büyük harfli komut da ("REFUEL"). Parçalardan biri
    /// sözlükte yoksa ya da sıradan cümleyse (küçük harfli "Open the door") null.
    /// </summary>
    public static string? Translate(string paragraph)
    {
        var parts = paragraph.Split(ButtonIcons.Marker);
        var translated = new List<string>(parts.Length);
        var any = false;
        foreach (var part in parts)
        {
            var words = part.Trim().Trim('.', ',', ':', '!', '?').Trim();
            if (words.Length == 0) { translated.Add(""); continue; }
            if (!words.Any(char.IsLetter) || words != words.ToUpperInvariant() || !Commands.TryGetValue(words, out var turkish))
                return null;
            translated.Add(turkish);
            any = true;
        }
        if (!any) return null;
        return string.Join(' ', string.Join($" {ButtonIcons.Marker} ", translated).Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }
}
