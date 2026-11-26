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
        ["EXIT"] = "Çık", ["BACK"] = "Geri", ["SELECT"] = "Seç", ["CLOSE"] = "Kapat", ["CLOSE MENU"] = "Menüyü kapat",
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
        ["REMINDERS"] = "Hatırlatıcılar",
        // GTA 6 duraklatma menüsü ve harita ipuçları (Sinan Bey, 24 Kas: sabit karşılıklar, çeviri motorundan önce).
        ["ADD WAYPOINT"] = "İşaret ekle", ["RETRY CHECKPOINT"] = "Kontrol noktasını yeniden dene",
        ["RESTART MISSION"] = "Görevi yeniden başlat", ["QUIT MISSION"] = "Görevden çık", ["ROTATE"] = "Döndür", ["INTERACT"] = "Etkileşim", ["USE"] = "Kullan",
        ["KNOCK"] = "Kapıyı çal", ["CALL"] = "Ara", ["HANG UP"] = "Telefonu kapat", ["ANSWER"] = "Cevapla",
        ["IGNORE"] = "Yoksay", ["REPLY"] = "Yanıtla", ["DELETE"] = "Sil", ["SAVE"] = "Kaydet", ["VIEW"] = "Görüntüle",
        ["INSPECT"] = "İncele", ["SEARCH"] = "Ara", ["HIDE"] = "Saklan", ["JOIN"] = "Katıl", ["TERMS"] = "Koşullar",
        ["MARKERS"] = "İşaretler", ["DROP"] = "Bırak", ["EQUIP"] = "Kuşan", ["UNEQUIP"] = "Çıkar", ["STORE"] = "Dükkân",
        ["HELP"] = "Yardım", ["OPTIONS"] = "Seçenekler", ["CAMERA"] = "Kamera", ["TOGGLE"] = "Aç / kapat", ["GRAB"] = "Tut",
        ["SIT"] = "Otur", ["STAND UP"] = "Kalk", ["SLEEP"] = "Uyu", ["SHOWER"] = "Duş al", ["TURN OFF"] = "Kapat",
        ["TURN ON"] = "Aç", ["WATCH"] = "İzle", ["LISTEN"] = "Dinle", ["DRIVE"] = "Sür", ["GET IN"] = "Bin",
        ["GET OUT"] = "İn", ["STEAL"] = "Çal", ["HACK"] = "Hackle", ["LOOT"] = "Yağmala", ["COLLECT"] = "Topla",
        // GTA 6 telefonu ve bar menüsü ("SCROLL / SEND / BACK", "TIP $10 / ORDER / BARTENDER").
        ["SEND"] = "Gönder", ["TIP"] = "Bahşiş ver", ["BARTENDER"] = "Barmen",
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
        ["STATS"] = "İstatistikler", ["GAME"] = "Oyun", ["BRIEF"] = "Özet", ["PROGRESS"] = "İlerleme", ["VEHICLES"] = "Araçlar",
        ["ANIMALS"] = "Hayvanlar",
        // Ayarlar › Kumanda şeması önizlemesi (#1362): kısa arayüz komutları diyalog gibi çevriliyordu ("RUN" → "KAÇ!",
        // "MOVE" → "ÇEKİL!", "DETONATE EXPLOSIVES" → "DETONATE EXPLOSIVES YAP"). Etiket olarak sabit karşılıklar.
        ["RUN"] = "Koş", ["MOVE"] = "Hareket", ["SPRINT"] = "Depar", ["WALK"] = "Yürü", ["JUMP"] = "Zıpla", ["CLIMB"] = "Tırman",
        ["CROUCH"] = "Eğil", ["COVER"] = "Siper", ["SHOOT"] = "Ateş et", ["AIM"] = "Nişan al", ["MELEE"] = "Yakın dövüş",
        ["RELOAD"] = "Şarjör değiştir", ["HOLSTER"] = "Silahı kılıfa koy", ["CELLPHONE"] = "Cep telefonu", ["PHONE"] = "Telefon",
        ["RADIO CONTROLS"] = "Radyo kontrolleri", ["RADIO MENU"] = "Radyo menüsü", ["RADIO"] = "Radyo", ["OBJECTIVE"] = "Hedef",
        ["MINIMAP"] = "Mini harita", ["DETONATE EXPLOSIVES"] = "Patlayıcıları patlat", ["DETONATE"] = "Patlat",
        ["LOADOUT"] = "Teçhizat", ["QUICK NAVIGATION"] = "Hızlı gezinme", ["PARTNER MENU"] = "Partner menüsü",
        ["PAUSE"] = "Duraklat", ["LOOK BEHIND"] = "Arkana bak", ["WEAPON WHEEL"] = "Silah çarkı",
        ["INTERACTION MENU"] = "Etkileşim menüsü", ["ACCELERATE"] = "Hızlan", ["BRAKE"] = "Fren", ["REVERSE"] = "Geri vites",
        ["HANDBRAKE"] = "El freni", ["HORN"] = "Korna", ["HEADLIGHTS"] = "Farlar", ["SWIM"] = "Yüz", ["TAKE COVER"] = "Siper al",
        ["THROW"] = "Fırlat", ["SPECIAL ABILITY"] = "Özel yetenek", ["SWITCH CHARACTER"] = "Karakter değiştir",
        ["SWITCH WEAPON"] = "Silah değiştir", ["CONTROLS"] = "Kontroller",
        // Haritanın görev listesi ve görev kartı (#1365): "GOAL" motordan "GOL." dönüyordu; arayüz etiketi olarak sabit.
        ["GOAL"] = "Hedef", ["GOALS"] = "Hedefler", ["OBJECTIVES"] = "Hedefler", ["MISSION"] = "Görev", ["MISSIONS"] = "Görevler",
        ["STORY"] = "Hikâye", ["OPTIONAL"] = "İsteğe bağlı", ["REWARD"] = "Ödül", ["REWARDS"] = "Ödüller",
    };

    /// <summary>
    /// Görev başlığı: emir fiili ve ardında özel ad ("Hit Kingpin Bowling", "Meet Bret"). Motor özel adı görüp başlığı
    /// olduğu gibi döndürünce başlık hiç çevrilmiyordu (#1365); yalnız fiil çevrilir, ad olduğu gibi kalır ve Türkçe eki
    /// alır ("Kingpin Bowling'i Soy", "Bret ile Buluş"). Adın her sözcüğü büyük harfle başlar, yalnız harf; bağlaç/edat
    /// ("for", "the") ya da iyelik ("Vicki's") varsa başlık bu kalıba girmez. Yalnız motor çevirmediğinde kullanılır
    /// (Mac/Android aynı).
    /// </summary>
    private static readonly (string Verb, string Suffix, string Turkish)[] TitleVerbs =
    [
        ("hit", "i", "Soy"), ("rob", "i", "Soy"), ("meet", "", "ile Buluş"), ("visit", "i", "Ziyaret Et"),
        ("find", "i", "Bul"), ("check out", "a", "Göz At"), ("go to", "a", "Git"), ("head to", "a", "Git"),
        ("return to", "a", "Dön"), ("call", "i", "Ara"), ("follow", "i", "Takip Et"), ("steal", "i", "Çal"),
        ("protect", "i", "Koru"), ("chase", "i", "Kovala"), ("rescue", "i", "Kurtar"), ("defend", "i", "Savun"),
        ("explore", "i", "Keşfet"), ("investigate", "i", "Araştır"), ("pick up", "i", "Al"), ("help", "a", "Yardım Et"),
    ];

    public static string? MissionTitle(string title)
    {
        var words = title.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length is < 2 or > 6 || TextStyleSampler.IsUpper(title)) return null;
        foreach (var (verb, suffix, turkish) in TitleVerbs)
        {
            var parts = verb.Split(' ');
            if (words.Length <= parts.Length
                || !parts.Select((part, index) => words[index].ToLowerInvariant() == part).All(match => match)
                || !char.IsUpper(words[0][0])) continue;
            var name = words[parts.Length..];
            if (!name.All(word => char.IsUpper(word[0]) && word.Length >= 2 && word.All(c => char.IsLetter(c) || c == '-')))
                return null;
            var joined = string.Join(' ', name);
            var item = suffix.Length == 0 ? joined : TurkishSuffix.Attach(joined, suffix);
            return item + " " + turkish;
        }
        return null;
    }

    /// <summary>
    /// Etiketin sonunda önündeki sözcüklerden ayrı duran tek harf (yazı tanımanın tuş simgesinden okuduğu harf, #1362:
    /// "RADIO CONTROLS f" → "RADYO KONTROLLERİ F", "RADIO MENU (I") atılır. Yalnız en az iki sözcüklü (iki harften uzun)
    /// etiketin sonunda ve şu durumlarda: harf parantezle okunmuş; BÜYÜK HARFLİ etiketin sonunda küçük harf; ya da BÜYÜK
    /// HARFLİ etiketin sonunda tuş yüzü harfi (A, B, X, Y, F, E, Q, R, L, I, O). Harfin sözcüğe ait olduğu etiket ("PRESS A",
    /// "PLAN B"; önündeki sözcük <see cref="GlyphOwners"/>'da) dokunulmaz (Mac/Android aynı).
    /// </summary>
    public static string WithoutKeyGlyph(string label)
    {
        var tokens = label.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length < 3) return label;
        var last = tokens[^1];
        var core = last.Trim('(', '[', '{', ')', ']', '}');
        if (core.Length != 1 || !char.IsLetter(core[0]) || core[0] > 127) return label;
        var letter = core[0];
        var head = tokens[..^1];
        if (head.Count(token => token.Count(char.IsLetter) >= 2) < 2
            || GlyphOwners.Contains(head[^1].ToUpperInvariant())) return label;
        var letters = string.Concat(head).Where(char.IsLetter).ToList();
        var upperHead = letters.Count > 0 && letters.All(char.IsUpper);
        var bracketed = last != core;
        var glyph = bracketed || (upperHead && (char.IsLower(letter) || "ABXYFEQRLIO".Contains(letter)));
        return glyph ? string.Join(' ', head) : label;
    }

    /// <summary>Ardındaki tek harf kendisine ait olan sözcükler ("PRESS A", "PLAN B", "BUTTON X").</summary>
    private static readonly HashSet<string> GlyphOwners = new(StringComparer.Ordinal)
    {
        "PRESS", "HOLD", "TAP", "USE", "KEY", "BUTTON", "PLAN", "TYPE", "CLASS", "GRADE", "PART", "SIDE", "VITAMIN",
        "ROUTE", "LEVEL", "ZONE", "AREA", "SECTOR", "GATE", "BLOCK", "TEAM", "GROUP", "OPTION", "CHAPTER", "ACT",
        "STAGE", "SEASON", "EPISODE", "FLOOR", "ROOM", "SLOT", "PLAYER", "MODE", "SECTION",
    };

    /// <summary>
    /// Menüdeki kısa etiketin Türkçesi ("OFF" → "KAPALI", "Off" → "Kapalı", "off" → "kapalı"): etiketin tamamı sözlükte
    /// olmalı (büyük/küçük harf fark etmez); biçimi Türkçe kurallarıyla korunur (i → İ). Sözlükte yoksa null.
    /// </summary>
    public static string? TranslateLabel(string label)
    {
        var words = label.Trim().Trim('.', ',', ':', '!', '?').Trim();
        if (words.Length == 0 || !words.Any(char.IsLetter)) return null;
        var key = Latin(words).ToUpperInvariant();
        if (!Commands.TryGetValue(key, out var turkish) && !Labels.TryGetValue(key, out turkish))
        {
            if (NearKey(key) is not { } near) return null;
            turkish = Commands.TryGetValue(near, out var command) ? command : Labels[near];
        }
        var letters = words.Where(char.IsLetter).ToList();
        if (letters.All(char.IsUpper)) return TurkishUpper(turkish);
        if (letters.All(char.IsLower)) return TurkishLower(turkish);
        // Her sözcüğü büyük harfle başlayan etiket ("Set Destination", "Photo Studio"): Türkçesi de öyle ("Hedef Belirle").
        var titled = words.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .All(word => char.IsUpper(word[0]) || !word.Any(char.IsLetter));
        if (titled && words.Contains(' '))
            return string.Join(' ', turkish.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Select(word => TurkishUpper(word[..1]) + word[1..]));
        return turkish;
    }

    /// <summary>
    /// Yazı tanımanın tek harfini yanlış okuduğu etiket ("SET DESTINATlON", "SETTINQS"): en az yedi harflik anahtarlardan
    /// tek harf farkla (değişen, eksik ya da fazla) eşleşen tek anahtar; birden çoğu eşleşirse null (Mac/Android aynı).
    /// </summary>
    internal static string? NearKey(string key)
    {
        if (key.Length < 7) return null;
        var found = Commands.Keys.Union(Labels.Keys)
            .Where(k => k.Length >= 7 && Math.Abs(k.Length - key.Length) <= 1 && OneEdit(k, key)).Distinct().ToList();
        return found.Count == 1 ? found[0] : null;
    }

    /// <summary>İki yazı en çok bir düzenlemeyle (bir harf değişmesi, eklenmesi ya da silinmesi) aynı mı.</summary>
    internal static bool OneEdit(string a, string b)
    {
        if (a == b) return true;
        if (a.Length == b.Length) return a.Zip(b).Count(pair => pair.First != pair.Second) == 1;
        var (longer, shorter) = a.Length > b.Length ? (a, b) : (b, a);
        if (longer.Length != shorter.Length + 1) return false;
        int i = 0, j = 0;
        var skipped = false;
        while (i < longer.Length && j < shorter.Length)
        {
            if (longer[i] == shorter[j]) { i++; j++; }
            else if (skipped) return false;
            else { skipped = true; i++; }
        }
        return true;
    }

    /// <summary>Yazı tanımanın Kiril harfle okuduğu Latin harfler ("Мар" → "Map").</summary>
    private static string Latin(string text) => string.Concat(text.Select(c => c switch
    {
        'А' => 'A', 'В' => 'B', 'Е' => 'E', 'К' => 'K', 'М' => 'M', 'Н' => 'H', 'О' => 'O', 'Р' => 'P', 'С' => 'C',
        'Т' => 'T', 'Х' => 'X', 'а' => 'a', 'е' => 'e', 'о' => 'o', 'р' => 'p', 'с' => 'c', 'х' => 'x', 'у' => 'y',
        _ => c,
    }));

    /// <summary>
    /// <see cref="TranslateLabel"/>, yazı tanımanın etikete kattığı kırıntıyla da: simge imleriyle ayrılan her parça ayrı
    /// aranır; baştaki ya da sondaki en çok iki harflik kırıntı (simgenin yanlış okunuşu: "pi Settings", "EXIT OR")
    /// olduğu gibi kalır. Bir parça bulunmazsa null.
    /// </summary>
    public static string? TranslateLabelLoosely(string label)
    {
        if (label.Contains(ButtonIcons.Marker))
        {
            var parts = label.Split(ButtonIcons.Marker);
            var done = new List<string>(parts.Length);
            var any = false;
            foreach (var part in parts)
            {
                if (part.Trim().Length == 0) { done.Add(""); continue; }
                if (TranslateLabelLoosely(part) is not { } turkish) return null;
                done.Add(turkish);
                any = true;
            }
            return any ? string.Join(' ', string.Join($" {ButtonIcons.Marker} ", done).Split(' ', StringSplitOptions.RemoveEmptyEntries)) : null;
        }
        if (TranslateLabel(label) is { } direct) return direct;
        if (TranslateTabs(label) is { } tabs) return tabs;
        var words = label.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length < 2) return null;
        // Baştaki kırıntı tuş adıysa ("R3 LOOK BEHIND") kalır; değilse ("1 Map", "pi Settings": simgenin yanlış okunuşu) atılır.
        if (words[0].Length <= 2 && TranslateLabel(string.Join(' ', words[1..])) is { } rest)
            return ButtonIcons.IsButtonName(words[0]) ? words[0] + " " + rest : rest;
        if (words[^1].Length <= 2 && TranslateLabel(string.Join(' ', words[..^1])) is { } head) return head + " " + words[^1];
        return null;
    }

    /// <summary>Tek satır okunan sekme çubuğu ("JASON &amp; LUCIA MAP BRIEF"): "AD &amp; AD" kalır, kalan her sözcük sözlükte
    /// olmalı; motora gitmez, her karede aynı çeviri (Mac/Android ile aynı). Yalnız BÜYÜK HARFLİ yazıda.</summary>
    public static string? TranslateTabs(string label)
    {
        var words = label.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length < 2 || !TextStyleSampler.IsUpper(label)) return null;
        var output = new List<string>();
        for (var i = 0; i < words.Length;)
        {
            if (i + 2 < words.Length && words[i + 1] == "&")
            {
                output.AddRange(words[i..(i + 3)]);
                i += 3;
                continue;
            }
            if (TranslateLabel(words[i]) is not { } word) return null;
            output.Add(word);
            i++;
        }
        return string.Join(' ', output);
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
