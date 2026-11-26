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
/// <para>
/// Elde sallanan telefon (#1253, #1326): GTA 6'nın telefonu elde durur, her karede birkaç piksel kayar. Önceden kutunun
/// kenarı %2 oynayınca ya da iz örneklerinin %8'i değişince ekran "değişti" sayılıyor, yerindeki çeviriler ilk yoklamada
/// kalkıyordu (Hide); yeniden çeviri için iki yoklamanın aynı çıkması gerekiyordu, sallanan telefon bunu nadiren veriyordu:
/// "Ekranı çevir"in çevirisi 1–2 sn'de kayboluyordu. Artık iz telefonun kendi koordinatında, hücre ortalamasıyla alınır
/// (<see cref="Look"/>), iki iz yatayda <see cref="MaxShift"/> hücreye dek kaydırılarak karşılaştırılır, kenar payı
/// <see cref="MoveTolerance"/>; çeviriler ancak art arda <see cref="HideTurns"/> yoklama değişirse kalkar.
/// </para>
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
        /// Telefonun ekranı art arda <see cref="HideTurns"/> yoklama değişti, henüz durulmadı: yerindeki mesaj çevirileri
        /// kalksın (artık başka balonların üstündeler); durulunca Refresh gelir. Yalnız <see cref="HidesOnChange"/> açıkken.
        /// </summary>
        Hide,
    }

    /// <summary>Çeviriler balonların üstünde, yerinde (kartsız): ekran durulmadan değişmeye devam ederse <see cref="Step.Hide"/>.</summary>
    public bool HidesOnChange { get; init; }

    /// <summary>Yoklama aralığı (ms).</summary>
    public const int Interval = 700;
    /// <summary>Telefon bu kadar yoklama art arda bulunamazsa kapanmış sayılır.</summary>
    public const int MissTurns = 3;
    /// <summary>
    /// Telefon bu kadar yer değiştirirse (kenarlara oranla) kart yeniden dizilir. Önceden 0,02'ydi: elde sallanan telefonun
    /// bulunan kutusu bundan çok oynuyordu.
    /// </summary>
    internal const double MoveTolerance = 0.04;
    /// <summary>
    /// Yerindeki çeviriler ancak telefonun ekranı art arda bu kadar yoklama (baştaki hâlinden) değişirse kalkar; tek
    /// yoklamalık değişim (sallanma, geçiş karesi) kaldırmaz. Değişip duruldıysa zaten Refresh gelir.
    /// </summary>
    internal const int HideTurns = 2;
    /// <summary>
    /// Telefonun ekranı bu paydan fazla değişirse (iz örneklerinin) değişmiş sayılır. Elde sallanan telefonun kıpırtısı
    /// (hücre ortalaması ve kaydırmalı karşılaştırmadan sonra) birkaç örnektir; sohbet değişince ya da yeni mesajla kayınca
    /// ekranın çoğu değişir. Önceden 0,08'di.
    /// </summary>
    internal const double ChangeShare = 0.12;
    /// <summary>
    /// Bir iz örneği bundan fazla değişirse değişmiş sayılır (sıkıştırma kıpırtısı ve kelime kenarının hücre içinde kayması
    /// sayılmaz; balon zemini ile yazı arasındaki fark bundan çok büyüktür). Önceden 24'tü.
    /// </summary>
    internal const int SampleChange = 32;
    /// <summary>
    /// İki iz yatayda en çok bu kadar hücre kaydırılarak karşılaştırılır (telefonun bulunan kutusu elde birkaç piksel kayar;
    /// bir hücre telefon eninin 1/64'ü). Dikeyde kaydırılmaz: yeni mesajla sohbetin kayması değişim sayılmalı.
    /// </summary>
    internal const int MaxShift = 2;
    /// <summary>
    /// İzin her hücresi, hücrenin bu kadar sütun × satır alt örneğinin ortalamasıdır (birkaç piksellik kayma hücrenin
    /// değerini az oynatır; önceden hücrenin tek pikseliydi, yazı satırına denk gelip gelmemesi değişiyordu).
    /// </summary>
    internal const int SubColumns = 4, SubRows = 8;

    private readonly object gate = new();
    private (TextBox Box, byte[] Signature)? baseline;
    private (TextBox Box, byte[] Signature)? pending;
    private int misses;
    /// <summary>Baştaki hâlinden art arda değişen yoklama sayısı.</summary>
    private int changes;
    /// <summary>Altyazı günlüğü: çevirinin neden gizlendiği, yeniden çevrildiği ya da kalktığı (sınırlı; testlerde yazılmaz).</summary>
    private readonly DropLog drops = new();

    /// <summary>Ekran bu telefon görüntüsüyle çevrildi (kartın dayandığı hâl).</summary>
    public void Settled(TextBox box, byte[] signature)
    {
        lock (gate)
        {
            baseline = (box, signature);
            pending = null;
            misses = 0;
            changes = 0;
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
                changes = 0;
                if (misses >= MissTurns) Note($"telefon {misses} yoklamadır yok, çeviri kalktı");
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
                changes = 0;
                return Step.Keep;
            }
            changes++;
            if (pending is { } last && !Differs(last, current))
            {
                pending = null;
                changes = 0;
                Note($"telefon ekranı değişti ve duruldu, yeniden çevriliyor ({Describe(based, current)})");
                return Step.Refresh;
            }
            pending = current;
            if (!HidesOnChange || changes != HideTurns) return Step.Wait;
            Note($"telefon ekranı {changes} yoklamadır değişiyor, yerindeki çeviriler gizlendi ({Describe(based, current)})");
            return Step.Hide;
        }
    }

    private void Note(string reason) => drops.Note("ScreenPhoneFollow", reason, "");

    private static bool Differs((TextBox Box, byte[] Signature) a, (TextBox Box, byte[] Signature) b) =>
        Shift(a.Box, b.Box) > MoveTolerance || ChangedShare(a.Signature, b.Signature) > ChangeShare;

    /// <summary>İki kutunun en çok oynayan kenarı (kareye oranla).</summary>
    internal static double Shift(TextBox a, TextBox b) =>
        Math.Max(Math.Max(Math.Abs(a.Left - b.Left), Math.Abs(a.Right - b.Right)),
                 Math.Max(Math.Abs(a.Top - b.Top), Math.Abs(a.Bottom - b.Bottom)));

    /// <summary>Günlük için: izin değişen payı ve kutunun oynaması (yüzde).</summary>
    private static string Describe((TextBox Box, byte[] Signature) a, (TextBox Box, byte[] Signature) b) =>
        $"%{PhoneTrace.Percent(ChangedShare(a.Signature, b.Signature))} değişim, %{PhoneTrace.Percent(Shift(a.Box, b.Box))} oynama";

    /// <summary>
    /// İki izin değişen örneklerinin payı: yatayda <see cref="MaxShift"/> hücreye dek kaydırmaların en küçüğü, örtüşen
    /// sütunlarda (boyları farklıysa tümü).
    /// </summary>
    internal static double ChangedShare(byte[] a, byte[] b)
    {
        if (a.Length != b.Length || a.Length == 0) return 1;
        const int width = ReadScheduler.SignatureWidth;
        if (a.Length % width != 0)
        {
            var changed = 0;
            for (var i = 0; i < a.Length; i++)
                if (Math.Abs(a[i] - b[i]) > SampleChange) changed++;
            return changed / (double)a.Length;
        }
        var rows = a.Length / width;
        var best = 1.0;
        for (var dx = -MaxShift; dx <= MaxShift; dx++)
        {
            int changed = 0, total = 0;
            for (var y = 0; y < rows; y++)
                for (var x = Math.Max(0, -dx); x < Math.Min(width, width - dx); x++)
                {
                    total++;
                    if (Math.Abs(a[y * width + x] - b[y * width + x + dx]) > SampleChange) changed++;
                }
            if (total > 0) best = Math.Min(best, changed / (double)total);
        }
        return best;
    }

    /// <summary>
    /// Karedeki telefonun yeri ve ekranının izi; telefon yoksa null. İz telefonun kutusundan (telefonun koordinatında)
    /// alınır, her hücresi alt örneklerin ortalamasıdır (<see cref="Signature"/>).
    /// </summary>
    public static (TextBox Box, byte[] Signature)? Look(Frame frame)
    {
        if (ScreenPhoneCard.Phone(frame) is not { } phone) return null;
        var box = phone.Bounds;
        var region = new CropRegion(box.Top, box.Bottom, box.Left, box.Right);
        return (box, Signature(RegionCropper.Crop(frame, region)));
    }

    /// <summary>
    /// Görüntünün <see cref="ReadScheduler.SignatureWidth"/> × <see cref="ReadScheduler.SignatureHeight"/> gri izi; her hücre
    /// <see cref="SubColumns"/> × <see cref="SubRows"/> alt örneğin (alt hücrenin ortasındaki piksel) ortalaması (Mac ve
    /// Android aynı hesap).
    /// </summary>
    internal static byte[] Signature(Frame image)
    {
        const int width = ReadScheduler.SignatureWidth, height = ReadScheduler.SignatureHeight;
        const int fineWidth = width * SubColumns, fineHeight = height * SubRows;
        var fine = new byte[fineWidth * fineHeight];
        if (image.Width == 0 || image.Height == 0 || !image.IsConsistent) return new byte[width * height];
        for (var y = 0; y < fineHeight; y++)
        {
            var row = Math.Min(image.Height - 1, (int)((y + 0.5) * image.Height / fineHeight)) * image.Stride;
            for (var x = 0; x < fineWidth; x++)
            {
                var pixel = row + Math.Min(image.Width - 1, (int)((x + 0.5) * image.Width / fineWidth)) * 4;
                fine[y * fineWidth + x] = (byte)((image.Pixels[pixel] + image.Pixels[pixel + 1] * 2 + image.Pixels[pixel + 2]) / 4);
            }
        }
        return Average(fine, width, height);
    }

    /// <summary>İnce örnekleri (genişlik·<see cref="SubColumns"/> × yükseklik·<see cref="SubRows"/>) hücre ortalamasına indirir.</summary>
    internal static byte[] Average(byte[] fine, int width, int height)
    {
        var stride = width * SubColumns;
        var output = new byte[width * height];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var sum = 0;
                for (var j = 0; j < SubRows; j++)
                {
                    var row = (y * SubRows + j) * stride + x * SubColumns;
                    for (var i = 0; i < SubColumns; i++) sum += fine[row + i];
                }
                output[y * width + x] = (byte)(sum / (SubColumns * SubRows));
            }
        return output;
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
