// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>Bir kare için karar: son okuma kullanılır ya da yazı tanıma yapılır.</summary>
/// <param name="Reuse">Bölge değişmedi, <paramref name="Text"/> geçerli.</param>
/// <param name="Deep">Boş bölgede kısa satırlar için büyütülmüş okuma da denenir.</param>
public readonly record struct ReadPlan(bool Reuse, string Text, bool Deep)
{
    public static ReadPlan Reused(string text) => new(true, text, false);
    public static ReadPlan Read(bool deep) => new(false, "", deep);
}

/// <summary>
/// Hangi karede yazı tanıma yapılacağını seçer. Oyun süresinin çoğunda bölge boştur ya da değişmez;
/// işlemcinin büyük kısmı bu karelerde boşa gider.
/// </summary>
public sealed class ReadScheduler(int changeThreshold = ReadScheduler.ChangeThreshold, int maxReuse = 20, int deepEvery = 3)
{
    /// <summary>Bölge izinin (<see cref="RegionCropper.Signature"/>) boyutu: satır başına bu kadar gri örnek, bu kadar satır.</summary>
    public const int SignatureWidth = 64, SignatureHeight = 12;
    /// <summary>Video gürültüsü bu farkı aşmaz; bir harf eklenmesi aşar.</summary>
    public const int ChangeThreshold = 16;

    private byte[]? previous;
    private string lastText = "";
    private int reused;
    private int emptyReads;

    /// <summary>Her kare okunur ve boş kareler hep derin okunur.</summary>
    public static ReadScheduler Always() => new(changeThreshold: -1, maxReuse: 0, deepEvery: 1);

    public ReadPlan Plan(byte[] signature)
    {
        var before = previous;
        previous = signature;
        if (before is not null && reused < maxReuse && !Changed(before, signature))
        {
            reused++;
            return ReadPlan.Reused(lastText);
        }
        reused = 0;
        return ReadPlan.Read(emptyReads % deepEvery == 0);
    }

    public void Record(string text)
    {
        lastText = text;
        // Yazı yeni kalktıysa derin okuma sırası hemen gelmez.
        emptyReads = text.Length == 0 ? emptyReads + 1 : 1;
    }

    public void Reset()
    {
        previous = null;
        lastText = "";
        reused = 0;
        emptyReads = 0;
    }

    private bool Changed(byte[] a, byte[] b) => Changed(a, b, changeThreshold);

    /// <summary>
    /// İki bölge izi farklı mı: bir örnek <paramref name="threshold"/>'dan çok değiştiyse. <paramref name="within"/>
    /// verilirse yalnız o kutunun (bölgenin kenarlarına oranla) örttüğü örneklere bakılır; bölgenin başka yerindeki
    /// kıpırtı sayılmaz (Mac: ReadScheduler.changed).
    /// </summary>
    public static bool Changed(byte[] a, byte[] b, int threshold, TextBox? within = null)
    {
        if (a.Length != b.Length) return true;
        const int columns = SignatureWidth;
        var rows = a.Length / columns;
        if (within is not { } box || rows == 0 || a.Length % columns != 0)
        {
            for (var i = 0; i < a.Length; i++)
                if (Math.Abs(a[i] - b[i]) > threshold) return true;
            return false;
        }
        var left = Math.Clamp((int)Math.Floor(box.Left * columns), 0, columns - 1);
        var right = Math.Clamp((int)Math.Ceiling(box.Right * columns), left + 1, columns);
        var top = Math.Clamp((int)Math.Floor(box.Top * rows), 0, rows - 1);
        var bottom = Math.Clamp((int)Math.Ceiling(box.Bottom * rows), top + 1, rows);
        for (var y = top; y < bottom; y++)
            for (var x = left; x < right; x++)
                if (Math.Abs(a[(y * columns) + x] - b[(y * columns) + x]) > threshold) return true;
        return false;
    }
}
