// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// "Ekranı çevir"in telefon kartı sohbeti izler. Önceden kart tek bir karenin çevirisiydi: telefonda başka bir sohbete
/// geçince kart eski sohbette kalıyor, süresi dolunca kayboluyordu; yeni sohbet ancak tuşa yeniden basınca geliyordu.
/// Kart ekrandayken uygulama telefonu düzenli aralıkla (<see cref="Interval"/>) yoklar: telefonun ekranı değişip bir yoklama
/// boyunca durulunca (sohbet değişti, yeni mesaj geldi, sohbet kaydı) ekran yeniden çevrilir; değişmeyen telefonda kart
/// ekranda kalır; telefon art arda <see cref="MissTurns"/> yoklamada bulunamazsa (kapandı) kart kalkar. Yeniden çeviri
/// <see cref="PhoneChatMemory"/> ile hızlıdır: daha önce görülen sohbetin mesajları çevirmene gitmez (Mac:
/// ScreenPhoneFollow.swift, Android: ScreenPhoneFollow.kt; ortak deneme dosyası Fixtures/phone-chat.json <c>follow</c> bölümü).
/// </summary>
public sealed class ScreenPhoneFollow
{
    public enum Step
    {
        /// <summary>Bir şey yapma (telefon kıpırdıyor ya da ilk yoklama).</summary>
        Wait,
        /// <summary>Telefonun ekranı değişti ve duruldu: ekranı yeniden çevir.</summary>
        Refresh,
        /// <summary>Telefon aynı: kart ekranda kalsın (süresi uzatılır).</summary>
        Keep,
        /// <summary>Telefon kapandı: kartı kaldır, izlemeyi bırak.</summary>
        Stop,
        /// <summary>
        /// Telefonun ekranı değişti (sohbet kaydı ya da değişti), henüz durulmadı: yerindeki mesaj çevirileri hemen kalksın
        /// (artık başka balonların üstündeler); durulunca Refresh gelir. Yalnız <see cref="HidesOnChange"/> açıkken.
        /// </summary>
        Hide,
    }

    /// <summary>Çeviriler balonların üstünde, yerinde (kartsız): ekran değişir değişmez <see cref="Step.Hide"/>.</summary>
    public bool HidesOnChange { get; init; }

    /// <summary>Yoklama aralığı (ms).</summary>
    public const int Interval = 700;
    /// <summary>Telefon bu kadar yoklama art arda bulunamazsa kapanmış sayılır.</summary>
    public const int MissTurns = 3;
    /// <summary>Telefon bu kadar yer değiştirirse (kenarlara oranla) kart yeniden dizilir.</summary>
    internal const double MoveTolerance = 0.02;
    /// <summary>
    /// Telefonun ekranı bu paydan fazla değişirse (iz örneklerinin) değişmiş sayılır. Elde sallanan telefonun kenar kıpırtısı
    /// birkaç örnektir; sohbet değişince ya da yeni mesajla kayınca ekranın çoğu değişir.
    /// </summary>
    internal const double ChangeShare = 0.08;
    /// <summary>Bir iz örneği bundan fazla değişirse değişmiş sayılır (sıkıştırma kıpırtısı sayılmaz).</summary>
    internal const int SampleChange = 24;

    private readonly object gate = new();
    private (TextBox Box, byte[] Signature)? baseline;
    private (TextBox Box, byte[] Signature)? pending;
    private int misses;

    /// <summary>Ekran bu telefon görüntüsüyle çevrildi (kartın dayandığı hâl).</summary>
    public void Settled(TextBox box, byte[] signature)
    {
        lock (gate)
        {
            baseline = (box, signature);
            pending = null;
            misses = 0;
        }
    }

    /// <summary>Bir yoklama: telefonun yeri ve ekranının izi (telefon yoksa null).</summary>
    public Step Next(TextBox? box, byte[]? signature)
    {
        lock (gate)
        {
            if (box is not { } found || signature is null)
            {
                misses++;
                pending = null;
                return misses >= MissTurns ? Step.Stop : Step.Wait;
            }
            misses = 0;
            var current = (found, signature);
            if (baseline is not { } based)
            {
                baseline = current;
                return Step.Keep;
            }
            if (!Differs(based, current))
            {
                pending = null;
                return Step.Keep;
            }
            if (pending is { } last && !Differs(last, current))
            {
                pending = null;
                return Step.Refresh;
            }
            var first = pending is null;
            pending = current;
            return HidesOnChange && first ? Step.Hide : Step.Wait;
        }
    }

    private static bool Differs((TextBox Box, byte[] Signature) a, (TextBox Box, byte[] Signature) b) =>
        Math.Abs(a.Box.Left - b.Box.Left) > MoveTolerance || Math.Abs(a.Box.Right - b.Box.Right) > MoveTolerance
        || Math.Abs(a.Box.Top - b.Box.Top) > MoveTolerance || Math.Abs(a.Box.Bottom - b.Box.Bottom) > MoveTolerance
        || ChangedShare(a.Signature, b.Signature) > ChangeShare;

    /// <summary>İki izin değişen örneklerinin payı (boyları farklıysa tümü).</summary>
    internal static double ChangedShare(byte[] a, byte[] b)
    {
        if (a.Length != b.Length || a.Length == 0) return 1;
        var changed = 0;
        for (var i = 0; i < a.Length; i++)
            if (Math.Abs(a[i] - b[i]) > SampleChange) changed++;
        return changed / (double)a.Length;
    }

    /// <summary>Karedeki telefonun yeri ve ekranının izi; telefon yoksa null.</summary>
    public static (TextBox Box, byte[] Signature)? Look(Frame frame)
    {
        if (ScreenPhoneCard.Phone(frame) is not { } phone) return null;
        var box = phone.Bounds;
        var region = new CropRegion(box.Top, box.Bottom, box.Left, box.Right);
        return (box, RegionCropper.Signature(RegionCropper.Crop(frame, region)));
    }
}

/// <summary>
/// Telefon sohbetlerinin çevirileri, sohbetin başlığıyla (kişi adı) birlikte saklanır: başka bir sohbete geçip geri dönünce
/// mesajlar yeniden çevrilmez, kart hemen dolar. Çevirmen ya da hedef dil değişince uygulama yenisini kurar.
/// </summary>
public sealed class PhoneChatMemory
{
    /// <summary>En çok bu kadar mesaj saklanır; dolunca en eskisi düşer.</summary>
    public const int Capacity = 600;

    private readonly object gate = new();
    private readonly Dictionary<string, string> saved = new(StringComparer.Ordinal);
    private readonly Queue<string> order = new();

    private static string Key(string chat, string source) => chat + "\u001F" + source;

    public string? Translation(string chat, string source)
    {
        lock (gate) return saved.TryGetValue(Key(chat, source), out var value) ? value : null;
    }

    public void Remember(string chat, string source, string translation)
    {
        if (string.IsNullOrWhiteSpace(translation)) return;
        lock (gate)
        {
            var key = Key(chat, source);
            if (!saved.ContainsKey(key))
            {
                if (order.Count >= Capacity) saved.Remove(order.Dequeue());
                order.Enqueue(key);
            }
            saved[key] = translation;
        }
    }

    public int Count
    {
        get { lock (gate) return saved.Count; }
    }
}
