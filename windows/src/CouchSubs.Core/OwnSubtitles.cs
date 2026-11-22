// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// CouchSubs'ın gösterdiği çeviriler: okunan karede kendi altyazımız varsa yeni satır sayılmasın. Kullanıcı bildirimi (X,
/// capture card + OBS ile yayın): görüntü kaynağı OBS'in Program/Önizleme projektörüyken karede CouchSubs'ın OBS katmanı
/// (tarayıcı kaynağı) da vardır. Türkçe altyazı İngilizce satırın üstüne düşünce (örtme ya da alttaki sabit yer) yazı
/// tanıma onu okuyor, hat onu yeni satır sanıp yeniden çeviriyor ("Çeviri: Çeviri: …"), sonra İngilizce yeniden görünüp
/// eski çeviri geri geliyordu; altyazı yanıp sönüyordu. Ayrı yerde duran Türkçe satır İngilizce bloğa katılıyordu.
/// <para>
/// Kural: gösterilen çeviri ekranda kaldıkça (ve kalktıktan sonra <see cref="TextGraceMs"/>) okunan bir satır ona
/// benziyorsa (yazı tanımanın Türkçe harfleri düz harfe çevirdiği hâliyle, bkz. <see cref="PoolFilter.Fold"/>) ya da
/// onun bir parçasıysa (katman uzun çeviriyi satırlara böler) "kendi altyazısı" sayılır, atılır. Kaynağına (İngilizce
/// satıra) benzeyen okuma hiçbir zaman atılmaz. Kendi altyazısı bir kez metinden tanınınca okunduğu yer öğrenilir;
/// çeviri ekrandayken o dikdörtgene düşen öbür satırlar da atılır. OBS'i okumayan kurulumda karede bizim altyazımız
/// yoktur; süzgeç bir şey atmaz. Mac/iPhone (OwnSubtitles.swift) ve Android (OwnSubtitles.kt) aynı kuralları uygular.
/// İş parçacığı güvenlidir.
/// </para>
/// </summary>
public sealed class OwnSubtitles
{
    /// <summary>Çeviri kalktıktan sonra metin eşleşmesi bu kadar süre geçerli (OBS projektörünün ve okumanın gecikmesi).</summary>
    public const int TextGraceMs = 3000;
    /// <summary>Öğrenilen yer kuralı çeviri kalktıktan sonra bu kadar süre geçerli.</summary>
    public const int PlaceGraceMs = 500;
    internal const double Similarity = 0.8;
    internal const double PartShare = 0.8;
    internal const int PartWords = 2;
    internal const int MinimumLetters = 4;
    internal const int Remembered = 6;

    private sealed class Shown(List<string> words, List<string> source, long until)
    {
        public List<string> Words { get; } = words;
        public string Text { get; } = string.Join(' ', words);
        public List<string> Source { get; } = source;
        public string SourceText { get; } = string.Join(' ', source);
        public long Until { get; set; } = until;
        public TextBox? Seen { get; set; }
    }

    private readonly object gate = new();
    private readonly Func<long> clock;
    private readonly List<Shown> shown = [];

    public OwnSubtitles(Func<long>? clock = null) => this.clock = clock ?? (() => Environment.TickCount64);

    /// <summary>Çeviri ekrana gitti; <paramref name="durationMs"/>: ekranda kalma süresi. Yer karede okunduğu yerden öğrenilir.</summary>
    public void Record(string translation, string source, int durationMs)
    {
        var words = PoolFilter.Fold(IconText.Plain(translation));
        if (words.Count == 0) return;
        var sourceWords = PoolFilter.Fold(IconText.Plain(source));
        var time = clock();
        lock (gate)
        {
            shown.Add(new Shown(words, sourceWords, time + durationMs));
            if (shown.Count > Remembered) shown.RemoveRange(0, shown.Count - Remembered);
        }
    }

    /// <summary>Ekrandaki çeviri kaldırıldı.</summary>
    public void Cleared()
    {
        var time = clock();
        lock (gate) foreach (var entry in shown) entry.Until = Math.Min(entry.Until, time);
    }

    public void Reset()
    {
        lock (gate) shown.Clear();
    }

    /// <summary><paramref name="text"/> ekrandaki (ya da az önce kalkan) bir çevirimize benziyor ya da onun parçası.</summary>
    public bool IsOwn(string text)
    {
        var probe = PoolFilter.Fold(IconText.Plain(text));
        var time = clock();
        lock (gate) return MatchIndex(probe, time) is not null;
    }

    /// <summary>Okumanın kendi altyazımız olan satırları ayrılmış hali. <paramref name="place"/>: okumanın karedeki yeri; Own kutuları kareye oranla.</summary>
    public (Reading Kept, IReadOnlyList<TextLine> Own) Split(Reading reading, TextBox? place = null)
    {
        var area = place ?? new TextBox(0, 0, 1, 1);
        var time = clock();
        lock (gate)
        {
            if (!shown.Any(entry => time <= entry.Until + TextGraceMs)) return (reading, []);
            var keep = Enumerable.Repeat(true, reading.Lines.Count).ToArray();
            var own = new List<TextLine>();
            for (var i = 0; i < reading.Lines.Count; i++)
            {
                var line = reading.Lines[i];
                if (MatchIndex(PoolFilter.Fold(IconText.Plain(line.Text)), time) is not { } match) continue;
                keep[i] = false;
                var box = line.Box?.PlacedIn(area);
                if (box is { } placed) shown[match].Seen = shown[match].Seen?.Union(placed) ?? placed;
                own.Add(line with { Box = box });
            }
            for (var i = 0; i < reading.Lines.Count; i++)
            {
                if (!keep[i]) continue;
                var line = reading.Lines[i];
                if (line.Box?.PlacedIn(area) is not { } box) continue;
                var probe = PoolFilter.Fold(IconText.Plain(line.Text));
                var inside = shown.Any(entry => time <= entry.Until + PlaceGraceMs && entry.Seen is { } seen
                                                && Covers(seen, box) && !Resembles(probe, entry.Source, entry.SourceText));
                if (!inside) continue;
                keep[i] = false;
                own.Add(line with { Box = box });
            }
            if (own.Count == 0) return (reading, []);
            return (new Reading(reading.Lines.Where((_, i) => keep[i])), own);
        }
    }

    /// <summary>
    /// Kendi altyazımız İngilizce satırın yerine mi düştü (örtme ya da üst üste binen sabit yer): öyleyse altyazı yalnız
    /// bizim çevirimiz okunduğu için "kalktı" sayılmaz. Yeri bilinmeyen okumada da öyle sayılır.
    /// </summary>
    public static bool CoversLine(IReadOnlyList<TextLine> own, TextBox? line)
    {
        if (line is not { } target) return true;
        return own.Any(item =>
        {
            if (item.Box is not { } box) return true;
            var overlap = Math.Min(box.Bottom, target.Bottom) - Math.Max(box.Top, target.Top);
            var height = Math.Min(box.Bottom - box.Top, target.Bottom - target.Top);
            return height > 0 && overlap >= 0.5 * height;
        });
    }

    private int? MatchIndex(List<string> probe, long time)
    {
        var joined = string.Join(' ', probe);
        if (joined.Count(c => c != ' ') < MinimumLetters) return null;
        for (var i = shown.Count - 1; i >= 0; i--)
        {
            var entry = shown[i];
            if (time > entry.Until + TextGraceMs) continue;
            if (Resembles(probe, entry.Source, entry.SourceText)) continue;
            if (TextMatch.IsSimilar(joined, entry.Text, Similarity)) return i;
            if (probe.Count < PartWords) continue;
            var found = probe.Where(word => entry.Words.Any(other => PoolFilter.IsClose(word, other))).ToList();
            var foreign = found.Count(word => !entry.Source.Any(other => PoolFilter.IsClose(word, other)));
            if (found.Count >= PartShare * probe.Count && foreign >= PartWords) return i;
        }
        return null;
    }

    internal static bool Resembles(List<string> probe, List<string> source, string sourceText)
    {
        if (probe.Count == 0 || source.Count == 0) return false;
        if (TextMatch.IsSimilar(string.Join(' ', probe), sourceText, Similarity)) return true;
        var found = probe.Count(word => source.Any(other => PoolFilter.IsClose(word, other)));
        return found >= 0.6 * probe.Count;
    }

    internal static bool Covers(TextBox area, TextBox box)
    {
        const double pad = 0.01;
        var w = Math.Min(box.Right, area.Right + pad) - Math.Max(box.Left, area.Left - pad);
        var h = Math.Min(box.Bottom, area.Bottom + pad) - Math.Max(box.Top, area.Top - pad);
        var size = (box.Right - box.Left) * (box.Bottom - box.Top);
        return w > 0 && h > 0 && size > 0 && w * h >= 0.7 * size;
    }
}
