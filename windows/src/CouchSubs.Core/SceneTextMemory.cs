// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Az önce sahne yazısı sayılıp atılan satır (plaka, tabela, telefon mesajı) bir sonraki karede başka okununca altyazı
/// olmaz. Altyazı kapısı (<see cref="SceneText"/>, <see cref="Reading.SubtitleBlock"/>, telefon süzgeci) her kareye ayrı
/// karar verir; yazı tanıma aynı tabelayı kare kare başka okuduğu için bir karede atılan yazı ötekinde kuralın dışında
/// kalıp çevriliyordu. Kullanıcı bildirimi (#1411, GTA 6, Mac, beta-105, "Ekran yazılarını otomatik çevir" ve telefon
/// okuması kapalı): plakanın "GOOD TIME STATE" yazısı çoğu karede "plaka/tabela" sayılıp atılıyor, "NECE / &amp; COCOTIME
/// STATE O." okunan karede ise çevriliyordu; telefon bir karede bulunup mesajı atıldıktan sonra telefon ıskalanınca aynı
/// mesaj altyazı olarak çevriliyordu; sola yaslı sohbet mesajı bir karede "menü açıklaması" sayılıp ötekinde çevriliyordu.
/// Güvenilir nedenle (<see cref="Remembers"/>) atılan satırlar <see cref="HoldMs"/> boyunca hatırlanır; okumadaki satır
/// onlardan birine <see cref="Similarity"/> oranında benziyorsa altyazı bloğu seçilmeden çıkarılır. Kamerayla kayan yazı,
/// düşük güven, ortadaki kısa satır, ürün yazısı ve menü listesi hatırlanmaz; <see cref="MinLetters"/> harften kısa satır
/// ne hatırlanır ne çıkarılır, <see cref="ExactLetters"/> harften kısa satır yalnız harfleri birebir aynıysa çıkarılır;
/// konuşan adlı satır hiç çıkarılmaz; süre her atılışta tazelenir. Mac/iPhone (SceneTextMemory.swift) ve Android
/// (SceneTextMemory.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/scene-text-memory.json.
/// </summary>
public sealed class SceneTextMemory
{
    /// <summary>Atılan satır bu kadar süre hatırlanır (son atılışından).</summary>
    public const long HoldMs = 8000;
    /// <summary>Boşluklar dışında en az bu kadar harf/rakamlı satır hatırlanır ve karşılaştırılır.</summary>
    public const int MinLetters = 5;
    /// <summary>Bu kadar harften kısa satırlar yalnız harfleri (boşluksuz) birebir aynıysa aynı yazı sayılır.</summary>
    public const int ExactLetters = 10;
    /// <summary>Sadeleştirilmiş iki satırın Levenshtein benzerliği bu orandan azsa aynı yazı sayılmaz.</summary>
    public const double Similarity = 0.75;
    /// <summary>En çok bu kadar satır hatırlanır (en eskisi düşer).</summary>
    public const int Capacity = 40;
    /// <summary>Telefonun ekranında okunup atılan satırın nedeni.</summary>
    public const string PhoneReason = "telefon yazısı";
    /// <summary>Günlükte atılma nedeni (ardından ilk atılışın nedeni yazılır).</summary>
    public const string Reason = "az önce sahne yazısı sayılan satırın yeniden okunuşu";
    /// <summary>
    /// Bloğun kalan satırının günlükteki atılma nedeni (ardından bloğun ilk atılış nedeni yazılır, bkz.
    /// <see cref="Leftovers"/>).
    /// </summary>
    public const string BlockReason = "sahne yazısı sayılan bloğun kalan satırı";

    private static readonly HashSet<string> Remembered =
    [
        SceneText.SignReason, SceneText.NumberReason, SceneText.PlateNumberReason, SceneText.MenuItemReason,
        SceneText.TiltedReason, InkTone.Reason, Reading.OffBandReason, PhoneReason,
    ];

    private sealed record Entry(string Text, string Reason, long SeenAt);

    private readonly List<Entry> entries = [];

    /// <summary>Son <see cref="Filter"/> çağrısında çıkarılan satırlar ve ilk atılışlarının nedeni (günlük için).</summary>
    public IReadOnlyList<(TextLine Line, string Reason)> Removed { get; private set; } = [];

    /// <summary>
    /// Son <see cref="Filter"/> çağrısında, satırlarının en az yarısı az önce sahne yazısı sayıldığı için kalanıyla birlikte
    /// çıkarılan bloğun kalan satırları ve bloğun ilk atılış nedeni (günlük için). Tabela, kitap kapağı ya da telefon
    /// sohbeti satır satır hatırlanıp çıkarılınca aynı bloğun tek kalan satırı ("A LIBERTY CITY MEMOIR", "bring it 2 me •",
    /// "Locatlng...") tek başına altyazı sanılıp çevriliyordu (#1414'ün yan etkisi). Blok <see cref="Reading.Blocks"/> ile
    /// (aynı sütun, yakın satır aralığı) ayrılır; konuşan adlı satır taşıyan blok ve bütünüyle oyunun konuşma altyazısının
    /// okunduğu yükseklikte duran blok (<see cref="SubtitleBand.Holds"/>) hiç çıkarılmaz. Kitap kapağının altyazı
    /// yüksekliğine sarkan alt satırı çıkarılır: kapağın bütünü o yüksekliğe sığmaz. Çıkarılan satır da hatırlanır.
    /// </summary>
    public IReadOnlyList<(TextLine Line, string Reason)> Leftovers { get; private set; } = [];

    /// <summary>Bu nedenle atılan satır hatırlanır mı.</summary>
    public static bool Remembers(string reason) => Remembered.Contains(reason);

    /// <summary>
    /// Atılan satırları hatırlar (<paramref name="reason"/> hatırlanan nedenlerden değilse hiçbir şey yapmaz).
    /// <paramref name="time"/>: milisaniye saati.
    /// </summary>
    public void Remember(IEnumerable<string> lines, string reason, long time)
    {
        if (!Remembers(reason)) return;
        foreach (var line in lines)
        {
            var key = TextMatch.Normalize(line);
            if (!IsLongEnough(key)) continue;
            entries.RemoveAll(entry => entry.Text == key);
            entries.Add(new Entry(key, reason, time));
        }
        if (entries.Count > Capacity) entries.RemoveRange(0, entries.Count - Capacity);
    }

    /// <summary>
    /// Okumanın az önce atılan satırlara benzeyenleri çıkarılmış hali. <paramref name="area"/> verilirse satırlarının en
    /// az yarısı böyle çıkarılan bloğun kalan satırları da çıkarılır (<see cref="Leftovers"/>; satır kutuları
    /// <paramref name="area"/>'ya oranlı); <paramref name="band"/>: bu oturumda altyazının okunduğu yükseklikler.
    /// </summary>
    public Reading Filter(Reading reading, long time, TextBox? area = null, SubtitleBand? band = null)
    {
        var removed = new List<(TextLine, string)>();
        var leftovers = new List<(TextLine, string)>();
        Removed = removed;
        Leftovers = leftovers;
        entries.RemoveAll(entry => time - entry.SeenAt > HoldMs || time < entry.SeenAt);
        if (entries.Count == 0) return reading;
        var reasons = new Dictionary<TextLine, string>(ReferenceEqualityComparer.Instance);
        foreach (var line in reading.Lines)
            if (Match(line.Text) is { } entry)
            {
                removed.Add((line, entry.Reason));
                reasons[line] = entry.Reason;
            }
        if (removed.Count == 0) return reading;
        if (area is { } place)
            foreach (var block in Reading.Blocks(reading.Lines.Where(line => line.Box is not null), place))
            {
                var gone = block.Where(reasons.ContainsKey).ToList();
                if (gone.Count == 0 || gone.Count == block.Count) continue;
                // Konuşan adlı satırın bloğu konuşmadır; bloğu oyunun altyazısının okunduğu yükseklikteyse altyazıdır.
                if (block.Any(line => SpeakerPrefix.Parse(line.Text) is not null)) continue;
                if (band is { IsEmpty: false } && band.Holds(new Reading(block).Box!.Value.PlacedIn(place), text => Match(text) is not null)) continue;
                // Bloğun kalanı yalnız en az yarısı çıkarıldıysa gider; MinLetters harf/rakamdan kısa satır ("[TOM E")
                // oylamaya katılmaz.
                var judged = block.Count(line => !reasons.ContainsKey(line) && line.Text.Count(char.IsLetterOrDigit) >= MinLetters);
                if (gone.Count < judged) continue;
                var first = reasons[gone[0]];
                foreach (var line in block.Where(line => !reasons.ContainsKey(line)))
                {
                    leftovers.Add((line, first));
                    reasons[line] = first;
                }
            }
        foreach (var (line, first) in leftovers) Remember([line.Text], first, time);
        return new Reading(reading.Lines.Where(line => !reasons.ContainsKey(line)));
    }

    /// <summary>Bu nedenle hatırlanan satırları unutur (oyunun altyazısı koyu yazı sayılınca <see cref="InkTone.Reason"/>).</summary>
    public void Forget(string reason) => entries.RemoveAll(entry => entry.Reason == reason);

    public void Reset()
    {
        entries.Clear();
        Removed = [];
        Leftovers = [];
    }

    /// <summary>Satırın benzediği hatırlanan satır (en yenisi); yoksa null.</summary>
    private Entry? Match(string text)
    {
        if (SpeakerPrefix.Parse(text) is not null) return null;
        var key = TextMatch.Normalize(text);
        if (!IsLongEnough(key)) return null;
        var letters = Letters(key);
        for (var i = entries.Count - 1; i >= 0; i--)
        {
            var entry = entries[i];
            var other = Letters(entry.Text);
            var same = letters.Length < ExactLetters || other.Length < ExactLetters
                ? letters == other
                : TextMatch.IsSimilar(key, entry.Text, Similarity);
            if (same) return entry;
        }
        return null;
    }

    private static bool IsLongEnough(string key) => Letters(key).Length >= MinLetters;

    private static string Letters(string key) => key.Replace(" ", "");
}
