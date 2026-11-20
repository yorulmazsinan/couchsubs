// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Konuşana göre renk (v2): oturum boyunca (çeviri başlayınca sıfırlanır) her kişiye bir renk. Yazı tanımanın yakın
/// okuması aynı kişidir ("Mattia", "Mattla", "Mattia." aynı renk); yeni kişi, mümkünse başka kişilerin renginden ve renk
/// ailesinden ayrı bir renk alır (iki mavi tonlu kişi yan yana karışmasın). Kurallar ve ortak test vektörü:
/// scripts/speaker_colors_ref.py, docs/speaker-colors-vectors.json (Mac/iPhone ve Android aynı sırada aynı rengi verir).
/// </summary>
public sealed class SpeakerColorBook
{
    /// <summary>Palet renklerinin aileleri: aynı ailedeki iki renk ekranda birbirine benzer.</summary>
    public static readonly IReadOnlyDictionary<string, char> Families = new Dictionary<string, char>
    {
        ["#FFD54F"] = 'A', ["#FFB74D"] = 'A', ["#FF8A65"] = 'A',
        ["#4FC3F7"] = 'B', ["#4DD0E1"] = 'B', ["#90CAF9"] = 'B',
        ["#81C784"] = 'C', ["#AED581"] = 'C',
        ["#CE93D8"] = 'D', ["#F06292"] = 'D',
    };

    private readonly object gate = new();
    private readonly List<(string Key, string Color)> people = [];

    /// <summary>Adın rengi; bilinmeyen kişi eklenir. Ad boşsa null.</summary>
    public string? Color(string name)
    {
        var key = Key(name);
        if (key.Length == 0) return null;
        lock (gate)
        {
            foreach (var (known, color) in people)
                if (SamePerson(known, key)) return color;
            var palette = SpeakerColors.Palette;
            var base0 = (int)(SpeakerColors.Hash(key) % (uint)palette.Count);
            var used = people.Select(person => person.Color).ToHashSet();
            var families = used.Select(color => Families[color]).ToHashSet();
            var order = Enumerable.Range(0, palette.Count).Select(step => palette[(base0 + step) % palette.Count]).ToList();
            var pick = order.FirstOrDefault(color => !used.Contains(color) && !families.Contains(Families[color]))
                       ?? order.FirstOrDefault(color => !used.Contains(color))
                       ?? palette[base0];
            people.Add((key, pick));
            return pick;
        }
    }

    /// <summary>Çeviri yeniden başladı: kişiler unutulur.</summary>
    public void Reset()
    {
        lock (gate) people.Clear();
    }

    /// <summary>Ad anahtarı: kırpılmış, sondaki noktalaması atılmış, küçük harf.</summary>
    public static string Key(string name) => name.Trim().TrimEnd('.', ',', '!', '?', ';', ':', '…').Trim().ToLowerInvariant();

    private static bool SamePerson(string a, string b) =>
        a == b || Confusable(a) == Confusable(b) || (Math.Min(a.Length, b.Length) >= 5 && Distance(a, b) <= 1);

    /// <summary>Yazı tanımanın karıştırdığı harfler eşitlenir: l/1/| → i, 0 → o, rn → m.</summary>
    private static string Confusable(string key) => string.Concat(key.Replace("rn", "m").Select(c => c switch
    {
        'l' or '1' or '|' => 'i',
        '0' => 'o',
        _ => c,
    }));

    private static int Distance(string a, string b)
    {
        var row = Enumerable.Range(0, b.Length + 1).ToArray();
        for (var i = 1; i <= a.Length; i++)
        {
            var previous = (int[])row.Clone();
            row[0] = i;
            for (var j = 1; j <= b.Length; j++)
                row[j] = Math.Min(Math.Min(previous[j] + 1, row[j - 1] + 1), previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
        }
        return row[b.Length];
    }
}
