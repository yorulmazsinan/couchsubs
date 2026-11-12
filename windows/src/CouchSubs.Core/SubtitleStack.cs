// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// TV uygulamasındaki altyazı yığınının (tv-webos/app.js: showSubtitle, onClear, showPrevious) aynısı; bilgisayar
/// ekranındaki altyazı penceresi bunu kullanır, böylece ekranda TV'dekiyle aynı satırlar aynı sürelerle görünür.
/// Hızlı konuşmada önceki satır yeni satırın üstünde küçük ve soluk kalır, sonra solarak kalkar; üç kişi art arda
/// konuşursa iki önceki satır da en üstte durur (en çok üç satır). Zaman dışarıdan verilir (saniye); testler saati
/// kendisi ilerletir. Mac'teki SubtitleStack ile aynı kurallar.
/// </summary>
public sealed class SubtitleStack
{
    /// <summary>Yeni satır öncekinden bu süre içinde gelirse önceki üstte kalır.</summary>
    public const double StackWithin = 1.5;
    /// <summary>Üstteki satırın tam görünür kaldığı süre; sonra solmaya başlar.</summary>
    public const double PreviousHold = 1.5;
    public const double PreviousFade = 0.4;
    /// <summary>Yeni satırla yer değiştirmedikçe hiçbir satır bundan kısa görünmez.</summary>
    public const double MinVisible = 1.2;
    /// <summary>"Temizle" olayı satırı okuma süresinden erken kaldırmaz; bu sürenin üst sınırı.</summary>
    public const double HoldMax = 5;

    public enum Role { Current, Previous, Older }

    /// <param name="Paragraphs">Başlık ve maddeli yazılar (görev paneli gibi) satır satır, sola yaslı gösterilir.</param>
    /// <param name="Fading">Üstteki satır solarak kalkıyor.</param>
    public sealed record Line(int Id, string Text, Role Role, bool Paragraphs, bool Fading);

    private sealed record Current(int Id, string Text, bool Paragraphs, double ShownAt, double HideAt, double HoldUntil);

    private sealed record Slot(int Id, string Text, double ShownAt)
    {
        public double FadeAt => ShownAt + PreviousHold;
        public double HideAt => FadeAt + PreviousFade;
    }

    /// <summary>Kapalıysa önceki satır üste çıkmaz, yeni satır eskisinin yerine geçer (ayarlardaki seçenek).</summary>
    public bool StackPrevious { get; set; } = true;

    private Current? current;
    private Slot? previous;
    private Slot? older;
    private int lastId;

    /// <summary>Ekranda hiçbir satır yok.</summary>
    public bool IsEmpty(double now) => Lines(now).Count == 0;

    /// <summary>Yeni altyazı. <paramref name="durationMs"/>: bilgisayarın bildirdiği süre (0 ya da eksi ise yazının uzunluğundan hesaplanır).</summary>
    /// <param name="replaces">Bilgisayar bu satırı öncekinin uzamış ya da düzelmiş okuması saydı; önceki üste çıkmaz, bunun yerine geçer (üstteki daha eski satırlar kalır).</param>
    public void Show(string text, int durationMs, bool paragraphs, double now, bool replaces = false)
    {
        Prune(now);
        // Önceki satır kısa göründüyse yeni satırın üstünde kalır. Aynı cümlenin başka bir okunuşu ikinci çeviri gibi
        // durmasın diye üste çıkmaz; görev paneli gibi çok satırlı yazılar da üst üste binmez.
        if (replaces && current is not null && !paragraphs)
        {
            // Üstteki satırlar olduğu gibi kalır.
        }
        else if (StackPrevious && current is { } shown && now - shown.ShownAt < StackWithin && !paragraphs && !shown.Paragraphs && !SameLine(shown.Text, text))
        {
            PushPrevious(shown.Text, now);
        }
        else
        {
            previous = null;
            older = null;
        }
        var reading = 2 + text.Length * 0.06;
        var visible = durationMs > 0 ? Math.Max(MinVisible, durationMs / 1000.0) : Math.Min(8, reading);
        current = new Current(NextId(), text, paragraphs, now, now + visible, now + Math.Min(HoldMax, reading));
    }

    /// <summary>Bilgisayardan gelen "temizle": yazı okunacak kadar görünmediyse kalan süre dolunca kalkar.</summary>
    public void Clear(double now)
    {
        Prune(now);
        if (current is not { } shown) return;
        if (shown.HoldUntil <= now) Hide();
        else current = shown with { HideAt = shown.HoldUntil };
    }

    /// <summary>Her şeyi hemen kaldırır (çeviri durdu).</summary>
    public void Hide()
    {
        current = null;
        previous = null;
        older = null;
    }

    /// <summary><paramref name="now"/> anında görünen satırlar, yukarıdan aşağıya.</summary>
    public IReadOnlyList<Line> Lines(double now)
    {
        if (current is not { } shown || now >= shown.HideAt) return [];
        var result = new List<Line>();
        foreach (var (slot, role) in new[] { (older, Role.Older), (previous, Role.Previous) })
        {
            if (slot is null || now >= slot.HideAt) continue;
            result.Add(new Line(slot.Id, slot.Text, role, false, now >= slot.FadeAt));
        }
        result.Add(new Line(shown.Id, shown.Text, Role.Current, shown.Paragraphs, false));
        return result;
    }

    /// <summary>Görünümün değişeceği bir sonraki an (satır solmaya başlar ya da kalkar); değişecek bir şey yoksa null.</summary>
    public double? NextChange(double now)
    {
        if (current is not { } shown || now >= shown.HideAt) return null;
        var times = new List<double> { shown.HideAt };
        foreach (var slot in new[] { older, previous })
            if (slot is not null) times.AddRange([slot.FadeAt, slot.HideAt]);
        var future = times.Where(t => t > now).ToList();
        return future.Count == 0 ? null : future.Min();
    }

    /// <summary>Önceki satır üste çıkar. Orada hâlâ tam görünen bir satır varsa o da bir üst sıraya (iki önceki) kayar.</summary>
    private void PushPrevious(string text, double now)
    {
        older = previous is { } shown && now < shown.FadeAt && !SameLine(shown.Text, text) ? new Slot(NextId(), shown.Text, now) : null;
        previous = new Slot(NextId(), text, now);
    }

    /// <summary>Süresi dolan satırları atar; son satır kalktıysa üsttekiler de kalkar (TV'deki hideSubtitle gibi).</summary>
    private void Prune(double now)
    {
        if (current is { } shown && now >= shown.HideAt) Hide();
        if (previous is { } p && now >= p.HideAt) previous = null;
        if (older is { } o && now >= o.HideAt) older = null;
    }

    private int NextId() => ++lastId;

    /// <summary>Büyük-küçük harf ve noktalama dışında aynı mı, ya da biri ötekinin başı/devamı mı ("Kapı" → "Kapı daha fazla…").</summary>
    public static bool SameLine(string a, string b)
    {
        var x = Plain(a);
        var y = Plain(b);
        if (x.Length == 0 || y.Length == 0) return x == y;
        return x == y || x.Contains(y, StringComparison.Ordinal) || y.Contains(x, StringComparison.Ordinal);
    }

    private const string Punctuation = ".,!?;:…\"'“”‘’«»()[]-–—";

    private static string Plain(string text) =>
        new([.. text.ToLowerInvariant().Where(c => !char.IsWhiteSpace(c) && !Punctuation.Contains(c))]);
}
