// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Konuşma değişirken ekranda sabit duran satırı (görev/HUD yazısı) okumadan çıkarır. GTA 6'da görev yazısı ("Get in
/// the sea plane") konuşma altyazısının hemen altında dakikalarca durur; yazı tanıma ikisini tek blok okuyordu. Konuşma
/// kalkıp görev tek başına kalınca kararlayıcı bunu gönderilenin bir satırı eksik okuması sayıyor, TV'de eski konuşmanın
/// çevirisi kalıyordu; kısa yeni konuşma da uzun görev satırı yüzünden aynı altyazı sayılıp çevrilmiyordu. Bir satır en
/// az <see cref="StickyMs"/> ekranda kaldıysa ve yanında ondan en az <see cref="YoungerByMs"/> sonra gelmiş başka bir
/// satır varsa sabit sayılır; sabit satır, ekrandan kalkana dek (tek başına kalsa da) okumadan çıkarılır. Satırları
/// birlikte beliren konuşma kutusu etkilenmez (Mac: StickyRows.swift, Android: StickyRows.kt).
/// </summary>
public sealed class StickyRows
{
    /// <summary>Satır bu kadar ekranda kalmadan sabit sayılmaz.</summary>
    public const int StickyMs = 6000;
    /// <summary>Yanındaki satırın en az bu kadar sonra gelmiş olması gerekir (birlikte beliren satırlar konuşmadır).</summary>
    public const int YoungerByMs = 3000;
    /// <summary>Bu kadar okunmayan satır ekrandan kalkmış sayılır (birkaç karelik okuma kaçağı satırı unutturmaz).</summary>
    public const int ForgetAfterMs = 1500;

    private sealed class Row(string text, long since)
    {
        public string Text { get; } = text;
        public long Since { get; } = since;
        public long LastSeen { get; set; } = since;
        public bool Sticky { get; set; }
    }

    private readonly List<Row> rows = [];

    /// <summary>Son <see cref="Filter"/> çağrısında ilk kez sabit sayılan satırlar (günlük için).</summary>
    public IReadOnlyList<string> NewlySticky { get; private set; } = [];

    /// <summary>Okumanın sabit (HUD) satırları çıkarılmış hali. <paramref name="time"/>: milisaniye saati.</summary>
    public Reading Filter(Reading reading, long time)
    {
        var newly = new List<string>();
        var matched = new List<Row?>();
        var used = new HashSet<Row>();
        foreach (var line in reading.Lines)
        {
            var text = TextMatch.Normalize(line.Text);
            if (text.Length < 3) { matched.Add(null); continue; }
            var row = rows.FirstOrDefault(r => !used.Contains(r) && TextMatch.IsSimilar(text, r.Text));
            if (row is null) { row = new Row(text, time); rows.Add(row); }
            row.LastSeen = time;
            used.Add(row);
            matched.Add(row);
        }
        var present = matched.OfType<Row>().ToList();
        for (var i = 0; i < matched.Count; i++)
        {
            if (matched[i] is not { Sticky: false } row || time - row.Since < StickyMs) continue;
            if (present.Any(other => other.Since - row.Since >= YoungerByMs))
            {
                row.Sticky = true;
                newly.Add(reading.Lines[i].Text);
            }
        }
        NewlySticky = newly;
        var kept = reading.Lines.Where((_, i) => matched[i] is not { Sticky: true }).ToList();
        rows.RemoveAll(r => time - r.LastSeen > ForgetAfterMs);
        return kept.Count == reading.Lines.Count ? reading : new Reading(kept);
    }

    public void Reset()
    {
        rows.Clear();
        NewlySticky = [];
    }
}
