// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// GTA 6'da elde açık telefon. Algılama yazı tanıma çalıştırmaz; uyumlu gözlemlerle açılır (<see cref="OpenPoints"/>):
/// iki sıkı gözlem, ya da bir sıkı gözlem ve onun yerinde gevşek doğrulama / yanları zayıf aday, ya da üç zayıf gözlem.
/// </summary>
public sealed class GamePhoneTracker
{
    internal const int IntervalMs = 330;
    private readonly Func<Frame, (CropRegion Region, bool Strict)?>? locateOverride;
    private GamePhoneGeometry.Pose? shownPose;
    private long? lastTime;
    private CropRegion? shown;

    private long clock;
    private readonly DropLog trace;

    public GamePhoneTracker() => trace = new DropLog(() => clock);
    internal GamePhoneTracker(Func<Frame, CropRegion?> locate) : this() =>
        locateOverride = frame => locate(frame) is { } region ? (region, true) : null;
    /// <summary>Denemeler: gözlem ve gücü (Strict: sıkı arama; değilse gevşek doğrulama ya da yanları zayıf aday).</summary>
    internal GamePhoneTracker(Func<Frame, (CropRegion Region, bool Strict)?> sight) : this() => locateOverride = sight;

    /// <summary>Telefonun açılması, kapanması ve oynadığı için açılmaması altyazı günlüğüne (<see cref="PhoneTrace"/>; sınırlı).</summary>
    public Action<string>? Log { get; set; }

    private void Trace(string reason)
    {
        if (Log is { } log) trace.Note(PhoneTrace.Component, reason, "", log);
    }

    /// <summary>Sıkı aramayla bulunan telefonun gözlem puanı.</summary>
    internal const int StrongPoints = 2;
    /// <summary>
    /// Gevşek doğrulamanın (doğrulanmayı bekleyen gözlemin yerinde hoparlör, kamera ve alt çentik) ya da yanları zayıf
    /// adayın (<see cref="GamePhoneGeometry.WeakSide"/>) gözlem puanı.
    /// </summary>
    internal const int WeakPoints = 1;
    /// <summary>
    /// Yeni telefon, art arda uyumlu gözlemlerin puanı buna varınca açılır: iki sıkı gözlem (önceki kural), sıkı gözlem ve
    /// gevşek doğrulama, ya da üç zayıf gözlem. Önceden yalnız art arda iki sıkı gözlem açıyordu: sıkı arama telefonu ara
    /// sıra bulunca (açık kasa açık zeminde, el örtüyor, karanlık) telefon hiç açılmıyor, mesajları altyazı gibi okunuyordu
    /// (#1251, beta-102: altyazı süzgeci telefonu tek sıkı gözlem ve gevşek doğrulamayla 3 sn tuttu, izleyici hiç açmadı).
    /// </summary>
    internal const int OpenPoints = 3;
    /// <summary>
    /// Doğrulanmayı bekleyen gözlem, arada ıskalı örnek olsa da bu kadar süre (ms) geçerli kalır; ıskasız art arda örnekler
    /// süreye bakılmadan birleşir (seyrek örneklemede de telefon açılır).
    /// </summary>
    internal const long PendingMs = 1000;
    private CropRegion? pending;
    private GamePhoneGeometry.Pose? pendingPose;
    private long pendingAt;
    private int pendingPoints, pendingMisses;
    private bool pendingStrict;
    private readonly PhoneMissLog missLog = new();

    public bool TrySample(Frame frame, long now, out CropRegion? visible)
    {
        if (lastTime is { } last && now >= last && now - last < IntervalMs)
        {
            visible = shown;
            return false;
        }
        lastTime = now;
        clock = now;
        var wasShown = shown is not null;
        GamePhoneGeometry.Pose? pose = null;
        CropRegion? candidate;
        var points = 0;
        var strict = false;
        GamePhoneGeometry.Probe? probe = null;
        if (locateOverride is not null)
        {
            var sighting = locateOverride(frame);
            candidate = sighting?.Region;
            strict = sighting?.Strict == true;
            points = strict ? StrongPoints : WeakPoints;
        }
        else
        {
            // Açık telefonun ya da doğrulanmayı bekleyen gözlemin yerinde gevşek doğrulama da denenir (GamePhoneGeometry.TryLocate,
            // near): beyaz ya da mavi ekranlı uygulamada (haber, ayarlar, hava) telefonun yanları zemine karışıyor, sıkı arama
            // ıskalıyordu. Yeni telefonda sıkı arama ıskalarsa yanları zayıf aday (Probe.Weak) zayıf gözlem sayılır.
            var near = shown is not null ? shownPose : PendingFresh(now) ? pendingPose : null;
            if (GamePhoneGeometry.TryLocate(frame, near, out var found, out var seen))
            {
                pose = found;
                strict = seen.Step == GamePhoneGeometry.Step.Found;
                points = strict ? StrongPoints : WeakPoints;
            }
            else if (shown is null && seen.Weak is { } weak)
            {
                pose = weak;
                points = WeakPoints;
            }
            probe = seen;
            candidate = pose?.Bounds;
        }
        // Akıl sınırı: telefon ekranın küçük, dikey bir parçasıdır. Dışındaki bir aday (ör. menüde ya da koyu ekranda
        // yanlış eşleşme) kabul edilmez; TV'de büyük opak telefon kutusu oyun görüntüsünü kapatırdı.
        if (candidate is not null && !Plausible(candidate, frame))
        {
            if (strict && probe is { } implausible) probe = implausible with { Step = GamePhoneGeometry.Step.Implausible };
            candidate = null;
            pose = null;
            points = 0;
            strict = false;
        }
        long unseenMs = 0;
        var unseenMisses = 0;
        CropRegion? movedFrom = null;
        if (shown is not null && candidate is not null && candidate.IsClose(shown, 0.035))
        {
            // Açık telefonun yakınında tek gözlem: aynı telefon, yeri güncellenir.
            shown = candidate;
            shownPose = pose;
            misses = 0;
            lastSeen = now;
        }
        else if (shown is not null && !Closes(misses + 1, Elapsed(lastSeen, now)))
        {
            // Açık telefon tek bir karede bulunamadı ya da el titredi: hemen kapanmaz. Önceden tek ıska paneli kapatıyor,
            // yeniden açılış iki gözlem bekleyip bütün sayfayı yeniden çeviriyordu; çeviriler gidip geliyordu (X'teki
            // bildirim). Telefon gerçekten indirilince MissGraceMs sonra kapanır (Closes).
            misses++;
        }
        else if (shown is not null)
        {
            unseenMs = Elapsed(lastSeen, now);
            unseenMisses = misses + 1;
            shown = null;
            shownPose = null;
            misses = 0;
            ClearPending();
        }
        else if (candidate is not null)
        {
            // Yeni telefon: doğrulanmayı bekleyen gözlemin yakınındaysa puanı eklenir, değilse yeni bekleyen gözlem olur.
            if (pending is not null && candidate.IsClose(pending, 0.035) && (pendingMisses == 0 || PendingFresh(now)))
                pendingPoints += points;
            else
            {
                if (pending is not null && pendingMisses == 0) movedFrom = pending;
                if (pending is not null) missLog.Unconfirmed(pendingStrict);
                pendingPoints = points;
                pendingStrict = false;
            }
            pending = candidate;
            pendingPose = pose;
            pendingAt = now;
            pendingMisses = 0;
            pendingStrict |= strict;
            if (pendingPoints >= OpenPoints)
            {
                shown = candidate;
                shownPose = pose;
                misses = 0;
                lastSeen = now;
                ClearPending();
            }
        }
        else if (pending is not null)
        {
            pendingMisses++;
            if (!PendingFresh(now))
            {
                missLog.Unconfirmed(pendingStrict);
                ClearPending();
            }
        }
        if (!wasShown && shown is not null) Trace(PhoneTrace.Opened);
        else if (wasShown && shown is null) Trace(PhoneTrace.ClosedAfter(unseenMs, unseenMisses));
        // Telefon art arda iki örnekte bulundu ama yeri çok oynadı: hiç açılmıyor, okuma da başlamıyor (önceden sessizdi).
        if (shown is null && candidate is not null && movedFrom is not null)
            Trace(PhoneTrace.Moving(PhoneTrace.Shift(candidate, movedFrom)));
        // İlk açılış ıskalanınca nedeni (en ileri geçilen ölçüt, en iyi aday) sınırlı aralıkla günlüğe (#1251).
        if (shown is not null) missLog.Reset();
        else if (probe is { } missed) missLog.Note(missed, now, Trace);
        visible = shown;
        return true;
    }

    private bool PendingFresh(long now) => pending is not null && now >= pendingAt && now - pendingAt <= PendingMs;

    private void ClearPending()
    {
        pending = null;
        pendingPose = null;
        pendingPoints = 0;
        pendingMisses = 0;
        pendingStrict = false;
    }

    public WatchedArea WithPose(WatchedArea area) => area with { PhonePose = shownPose };

    /// <summary>
    /// Açık telefon bu kadar süre (ms) görülmezse kapanır; çevirisi hemen kalkar (ClosePhone). Önceden süre değil örnek
    /// sayılıyordu (art arda 4 ıska): örnekler seyrek geldiğinde (ağır kare, takılan akış) telefon indirildikten 3–4 sn
    /// sonra kalkıyordu (#1334). Tek karelik ıska yine kapatmaz: en az <see cref="MinimumMisses"/> ıska gerekir; yalnız
    /// telefon 2 × <see cref="MissGraceMs"/> boyunca hiç görülmediyse tek ıska yeter. 330 ms aralıkla ~1 sn (Mac ve
    /// Android ile aynı).
    /// </summary>
    internal const long MissGraceMs = 900;
    /// <summary>
    /// Altyazı süzgecinin açık telefonu bulunamadığı aramalarda tuttuğu arama sayısı (SubtitlePipeline.HeldPhone); telefon
    /// oturumunun kapanması süreyle ölçülür (<see cref="MissGraceMs"/>).
    /// </summary>
    internal const int MissGrace = 3;
    internal const int MinimumMisses = 2;
    /// <summary>Saat geri giderse süre ölçülemez: art arda bu kadar ıskada her durumda kapanır (eski kural).</summary>
    internal const int MaximumMisses = 4;
    private int misses;
    /// <summary>Telefonun en son görüldüğü an (ms).</summary>
    private long lastSeen;

    /// <summary>Açık telefon <paramref name="misses"/> ıskadan, <paramref name="unseenMs"/> görülmeden sonra kapansın mı.</summary>
    internal static bool Closes(int misses, long unseenMs) =>
        misses >= MaximumMisses || (misses >= MinimumMisses && unseenMs >= MissGraceMs) || unseenMs >= 2 * MissGraceMs;

    private static long Elapsed(long since, long now) => now >= since ? now - since : 0;

    /// <summary>Telefon kutusunun alanı (kareye oranla) bu aralıkta olmalı.</summary>
    internal const double MinArea = 0.04, MaxArea = 0.35;

    /// <summary>
    /// Telefon kutusu akla yatkın mı: alanı karenin %4–%35'i, piksel olarak dikey (yükseklik/genişlik 0,9–2,6; eğik
    /// telefonun sınır kutusu dikey telefondan geniştir), yüksekliği karenin en çok %85'i, genişliği en çok yarısı, merkezi karenin sol kenarında ya da üst üçte birinde değil.
    /// </summary>
    internal static bool Plausible(CropRegion region, Frame frame)
    {
        double width = region.Right - region.Left, height = region.Bottom - region.Top;
        if (width <= 0 || height <= 0 || height > 0.85 || width > 0.5) return false;
        double area = width * height;
        if (area < MinArea || area > MaxArea) return false;
        double aspect = height * Math.Max(1, frame.Height) / (width * Math.Max(1, frame.Width));
        // Test karelerinde (2x2) en-boy anlamsız; gerçek kare 16:9'dur.
        if (frame.Width >= 64 && (aspect < 0.9 || aspect > 2.6)) return false;
        double centerX = (region.Left + region.Right) / 2, centerY = (region.Top + region.Bottom) / 2;
        return centerX >= 0.35 && centerY >= 1.0 / 3;
    }

    public void Reset()
    {
        lastTime = null;
        shown = null;
        misses = 0;
        lastSeen = 0;
        shownPose = null;
        ClearPending();
        missLog.Reset();
    }
}

internal static class GamePhoneGeometry
{
    private const int Width = 400, Height = 225, Left = 95, Right = 305;
    private readonly record struct Slot(double X, int Y, int Length, int Contrast);

    // Noktalar tam kareye göre 0..1; ekran düzleminin yönü hoparlörleri birleştiren eksenden alınabilir.
    internal readonly record struct Pose(double TopX, double TopY, double BottomX, double BottomY)
    {
        internal CropRegion Bounds
        {
            get
            {
                double h = BottomY - TopY, w = h * Height / Width * .25;
                return new CropRegion(TopY + h * .012, BottomY - h * .015,
                    Math.Min(TopX, BottomX) - w, Math.Max(TopX, BottomX) + w);
            }
        }
    }

    internal static CropRegion? Locate(Frame frame) => TryLocate(frame, out var pose) ? pose.Bounds : null;

    /// <summary>Simsiyah şerit: örneklerin hepsi bu tondan koyu (0–255).</summary>
    internal const int DarkTone = 24;

    private static bool Widescreen(int width, int height) => Math.Abs(width / (double)height - Width / (double)Height) <= .04;

    /// <summary>
    /// Karedeki 16:9 oyun görüntüsü (piksel). Pencereden okunan kare (PS Remote Play, chiaki-ng, OBS penceresi) başlık
    /// çubuğunu ve pencere görüntüden farklı oransa siyah şeritleri de taşır; önceden telefon yalnız tam 16:9 karede
    /// aranıyordu, pencerede hiç bulunmuyordu (ne otomatik telefon okuması ne "Ekranı çevir"in telefon kartı). Alttaki ve
    /// yanlardaki simsiyah şeritler atılır, görüntü kalan genişliğin 16:9'u kadar yüksekliktedir ve alta yaslıdır (başlık
    /// çubuğu üstte). Kare zaten 16:9 ise tamamı; görüntü bulunamazsa null (Mac/iPhone ve Android ile aynı kural).
    /// </summary>
    internal static (int X, int Y, int Width, int Height)? Picture(int width, int height, Func<int, int, int> tone)
    {
        if (width < Width || height < Height) return null;
        if (Widescreen(width, height)) return (0, 0, width, height);
        var columns = Enumerable.Range(0, 64).Select(i => Math.Min(width - 1, (int)((i + 0.5) * width / 64))).ToArray();
        bool DarkRow(int y) => columns.All(x => tone(x, y) < DarkTone);
        var bottom = height;
        while (bottom > height / 2 && DarkRow(bottom - 1)) bottom--;
        // Yan şeritlere başlık çubuğunun altından bakılır (başlık çubuğu bütün genişlikte uzanır).
        var from = height * 2 / 5;
        var rows = Enumerable.Range(0, 48).Select(i => from + (int)((i + 0.5) * (bottom - from) / 48)).ToArray();
        bool DarkColumn(int x) => rows.All(y => tone(x, y) < DarkTone);
        int left = 0, right = width;
        while (left < width / 4 && DarkColumn(left)) left++;
        while (right > width * 3 / 4 && DarkColumn(right - 1)) right--;
        var w = right - left;
        var h = (int)Math.Round(w * 9 / 16.0, MidpointRounding.AwayFromZero);
        if (h > bottom)
        {
            h = bottom;
            w = (int)Math.Round(h * 16 / 9.0, MidpointRounding.AwayFromZero);
            left = (left + right - w) / 2;
        }
        if (w < Width || h < Height || left < 0 || left + w > width) return null;
        return (left, bottom - h, w, h);
    }

    internal static bool TryLocate(Frame frame, out Pose pose) => TryLocate(frame, null, out pose);

    /// <summary>
    /// Karedeki telefon. <paramref name="near"/>: açık telefonun son yeri; sıkı arama ıskalarsa o yerin hemen çevresinde
    /// gevşek doğrulama yapılır (<see cref="Confirm"/>): hoparlör yarığı ve kamera üstte, alt çentik altta aynı yerde
    /// duruyorsa telefon yerindedir. Sinan Bey (beta.100, 3418–3425): beyaz/mavi ekranlı uygulamalarda (haber, makale, hava,
    /// ayarlar, eklenti) telefonun yan kenarları elin ve gövdenin rengine karışıyor, sıkı arama telefonu kaybediyordu;
    /// telefon kaybolunca balonlar kalkıyor ("arada kaçıyor", 3417), telefonun yazıları altyazıya (3418, 3420, 3421) ve
    /// ekran yazısı kutularına (3420–3425) gidiyordu. Gevşek doğrulama yalnız açık telefonun yerinde yapılır: yeni telefon
    /// yine sıkı aramayla ve iki gözlemle açılır (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static bool TryLocate(Frame frame, Pose? near, out Pose pose) => TryLocate(frame, near, out pose, out _);

    /// <summary><see cref="TryLocate(Frame, Pose?, out Pose)"/>; <paramref name="probe"/>: sıkı aramanın ıska nedeni ve en iyi adayı.</summary>
    internal static bool TryLocate(Frame frame, Pose? near, out Pose pose, out Probe probe)
    {
        pose = default;
        probe = Probe.Missed(Step.NoPicture);
        if (frame.Width < Width || frame.Height < Height) return false;
        if (Widescreen(frame.Width, frame.Height)) return TryLocate(frame, (0, 0, frame.Width, frame.Height), near, out pose, out probe);
        if (!frame.IsConsistent) return false;
        int Tone(int x, int y)
        {
            var p = (y * frame.Stride) + (x * 4);
            return (frame.Pixels[p] * 29 + frame.Pixels[p + 1] * 150 + frame.Pixels[p + 2] * 77) >> 8;
        }
        if (Picture(frame.Width, frame.Height, Tone) is not { } area) return false;
        // Açık telefonun yeri görüntünün içine taşınır.
        Pose? local = near is { } last
            ? new Pose((last.TopX * frame.Width - area.X) / area.Width, (last.TopY * frame.Height - area.Y) / area.Height,
                       (last.BottomX * frame.Width - area.X) / area.Width, (last.BottomY * frame.Height - area.Y) / area.Height)
            : null;
        double X(double value) => (area.X + value * area.Width) / frame.Width;
        double Y(double value) => (area.Y + value * area.Height) / frame.Height;
        Pose Outside(Pose inside) => new(X(inside.TopX), Y(inside.TopY), X(inside.BottomX), Y(inside.BottomY));
        var located = TryLocate(frame, area, local, out var within, out probe);
        if (probe.Candidate is { } candidate) probe = probe with { Candidate = Outside(candidate) };
        if (!located) return false;
        pose = Outside(within);
        return true;
    }

    // Telefon karenin içindeki 16:9 görüntüde (area) aranır; yer görüntüye göre 0..1.
    private static bool TryLocate(Frame frame, (int X, int Y, int Width, int Height) area, Pose? near, out Pose pose, out Probe probe)
    {
        pose = default;
        probe = Probe.Missed(Step.NoPicture);
        if (area.Width < Width || area.Height < Height || !Widescreen(area.Width, area.Height)) return false;
        Span<int> columns = stackalloc int[Width * 2];
        var grid = new Samples(frame, columns, area);
        if (Strict(grid, out pose, out probe)) return true;
        return near is { } last && Confirm(grid, last, out pose);
    }

    /// <summary>Gevşek doğrulamada yarıklar açık telefonun son yerinden en çok bu kadar (400×225 ızgarada) uzak olabilir.</summary>
    internal const double ConfirmReach = 4.0;

    /// <summary>
    /// Açık telefonun son yerinde gevşek doğrulama: üstte kameralı hoparlör yarığı ve altta alt çentik, son yerin
    /// <see cref="ConfirmReach"/> kadar çevresinde, sıkı aramayla aynı boy ve oran kurallarıyla; yan kenarların ve çerçevenin
    /// gücüne bakılmaz (beyaz ekranda yanlar zemine karışır). Bulunmazsa false (Mac/iPhone ve Android ile aynı).
    /// </summary>
    private static bool Confirm(Samples grid, Pose near, out Pose pose)
    {
        pose = default;
        double topX = near.TopX * Width, topY = near.TopY * Height, bottomX = near.BottomX * Width, bottomY = near.BottomY * Height;
        var reach = (int)ConfirmReach;
        int upperFrom = Math.Max(17, (int)Math.Round(topY, MidpointRounding.AwayFromZero) - reach);
        int upperTo = Math.Min(75, (int)Math.Round(topY, MidpointRounding.AwayFromZero) + reach + 1);
        int lowerFrom = Math.Max(145, (int)Math.Round(bottomY, MidpointRounding.AwayFromZero) - reach);
        int lowerTo = Math.Min(217, (int)Math.Round(bottomY, MidpointRounding.AwayFromZero) + reach + 1);
        if (upperFrom >= upperTo || lowerFrom >= lowerTo) return false;
        Span<Slot> upper = stackalloc Slot[12], lower = stackalloc Slot[16];
        int tops = FindSlots(grid, upperFrom, upperTo, 8, 19, upper);
        if (tops < 1) return false;
        int bottoms = FindSlots(grid, lowerFrom, lowerTo, 5, 14, lower);
        if (bottoms < 1) return false;
        double best = double.PositiveInfinity;
        var found = false;
        foreach (var top in upper[..tops])
        {
            if (Math.Abs(top.X - topX) > ConfirmReach || !HasCamera(grid, top)) continue;
            foreach (var bottom in lower[..bottoms])
            {
                if (Math.Abs(bottom.X - bottomX) > ConfirmReach) continue;
                int h = bottom.Y - top.Y;
                double dx = bottom.X - top.X;
                if (h is < 115 or > 179 || Math.Abs(dx) > h * .24 ||
                    bottom.Length < top.Length * .46 || bottom.Length > top.Length ||
                    h < 7.9 * top.Length || h > 16.5 * top.Length ||
                    h < 12 * bottom.Length || h > 30 * bottom.Length) continue;
                var distance = Math.Abs(top.X - topX) + Math.Abs(top.Y - topY) + Math.Abs(bottom.X - bottomX) + Math.Abs(bottom.Y - bottomY);
                if (distance >= best) continue;
                best = distance;
                found = true;
                pose = new Pose(top.X / Width, (double)top.Y / Height, bottom.X / Width, (double)bottom.Y / Height);
            }
        }
        return found;
    }

    /// <summary>
    /// Sıkı aramanın ıska nedeni: aramanın geçemediği ilk ölçüt (sırayla). Telefon ekrandayken ilk açılış ıskalanınca
    /// hangi ölçütün tuttuğu günlükte görünsün diye (#1251; Mac/iPhone ve Android ile aynı adlar).
    /// </summary>
    internal enum Step
    {
        /// <summary>Karede 16:9 oyun görüntüsü yok.</summary>
        NoPicture,
        /// <summary>Üst şeritte hoparlör yarığına benzer koyu çizgi yok.</summary>
        NoTopSlot,
        /// <summary>Üst şeritte çok aday (menü, yazı satırları): arama bırakıldı.</summary>
        TopCrowded,
        /// <summary>Hoparlör yarığının yanında ön kamera yok.</summary>
        NoCamera,
        /// <summary>Alt şeritte alt çentiğe benzer koyu çizgi yok.</summary>
        NoBottomSlot,
        /// <summary>Alt şeritte çok aday: arama bırakıldı.</summary>
        BottomCrowded,
        /// <summary>Yarık ile çentik telefon boyunda ve oranında değil.</summary>
        Shape,
        /// <summary>Yarığın ya da çentiğin çevresi düz kasa değil.</summary>
        Rim,
        /// <summary>Telefonun yan kenarları zayıf (açık kasa açık zeminde, el örtüyor).</summary>
        Sides,
        /// <summary>Sıkı arama buldu ama kutu akla yatkın değil (<see cref="GamePhoneTracker.Plausible"/>; izleyici koyar).</summary>
        Implausible,
        /// <summary>Bulundu.</summary>
        Found,
    }

    /// <summary>Yan kenarların sıkı aramadaki eşiği (ikisi de en az bu kadar güçlü olmalı).</summary>
    internal const int SideThreshold = 12;

    /// <summary>
    /// Yanları zayıf adayın zayıf gözlem sayılması için zayıf yanının en az gücü. Gerçek telefonsuz karelerin (testdata/frames;
    /// karartılmış, açılmış, düşük karşıtlıklı hâlleriyle) hiçbiri yan ölçütüne gelmiyor; gerçek telefon (480p akış, yukarıda
    /// tutulan) 10–11'de kalıp bulunmuyordu.
    /// </summary>
    internal const int WeakSide = 8;

    /// <summary>
    /// Sıkı aramanın sonucu: <see cref="Step"/> ıskanın nedeni; <see cref="Side"/> yan ölçütüne gelen adaylardan zayıf yanı
    /// en güçlü olanın zayıf yanı (yoksa -1); <see cref="Candidate"/> o aday (yarık, kamera, çentik, oran ve kasa tutuyor,
    /// yanları zayıf). Aday tek başına telefon açmaz.
    /// </summary>
    internal readonly record struct Probe(Step Step, int Side, Pose? Candidate)
    {
        internal static Probe Missed(Step step) => new(step, -1, null);

        /// <summary>Zayıf gözlem sayılan aday (<see cref="WeakSide"/>).</summary>
        internal Pose? Weak => Side >= WeakSide ? Candidate : null;
    }

    private static bool Strict(Samples grid, out Pose pose) => Strict(grid, out pose, out _);

    private static bool Strict(Samples grid, out Pose pose, out Probe probe)
    {
        pose = default;
        Span<Slot> upper = stackalloc Slot[12], lower = stackalloc Slot[16];
        int tops = FindSlots(grid, 17, 75, 8, 19, upper);
        if (tops < 1)
        {
            probe = Probe.Missed(tops < 0 ? Step.TopCrowded : Step.NoTopSlot);
            return false;
        }
        // Ön kamerası olan yarıklar (Mac/iPhone ve Android'de olduğu gibi alt şeritten önce).
        var cameras = 0;
        for (var i = 0; i < tops; i++)
            if (HasCamera(grid, upper[i])) upper[cameras++] = upper[i];
        if (cameras == 0)
        {
            probe = Probe.Missed(Step.NoCamera);
            return false;
        }
        int bottoms = FindSlots(grid, 145, 217, 5, 14, lower);
        if (bottoms < 1)
        {
            probe = Probe.Missed(bottoms < 0 ? Step.BottomCrowded : Step.NoBottomSlot);
            return false;
        }
        double best = 0;
        var step = Step.Shape;
        int weakSide = -1;
        Pose? weak = null;
        foreach (var top in upper[..cameras])
        {
            foreach (var bottom in lower[..bottoms])
            {
                int h = bottom.Y - top.Y;
                double dx = bottom.X - top.X;
                if (h is < 115 or > 179 || Math.Abs(dx) > h * .24 ||
                    bottom.Length < top.Length * .46 || bottom.Length > top.Length ||
                    h < 7.9 * top.Length || h > 16.5 * top.Length ||
                    h < 12 * bottom.Length || h > 30 * bottom.Length) continue;
                if (step < Step.Rim) step = Step.Rim;
                if (!SmoothRim(grid, top, dx, h) || !SmoothRim(grid, bottom, dx, h)) continue;
                if (step < Step.Sides) step = Step.Sides;
                int left = SideStrength(grid, top, dx, h, -1);
                int right = SideStrength(grid, top, dx, h, 1);
                var found = new Pose(top.X / Width, (double)top.Y / Height, bottom.X / Width, (double)bottom.Y / Height);
                if (left < SideThreshold || right < SideThreshold)
                {
                    if (Math.Min(left, right) > weakSide)
                    {
                        weakSide = Math.Min(left, right);
                        weak = found;
                    }
                    continue;
                }
                double score = Math.Min(left, right) + .25 * Math.Max(left, right) + .1 * Math.Min(top.Contrast, bottom.Contrast)
                    + .5 * RimBoundary(grid, bottom, dx, h, lower: true) + .5 * RimBoundary(grid, top, dx, h, lower: false);
                if (score <= best) continue;
                best = score;
                pose = found;
            }
        }
        probe = best > 0 ? new Probe(Step.Found, -1, null) : new Probe(step, weakSide, weak);
        return best > 0;
    }

    // Üst ve alt şeritler ayrı okunur. Yarık bulunmazsa görüntünün ortasına ve altına bakılmaz.
    private static int FindSlots(Samples grid, int from, int to, int min, int max, Span<Slot> slots)
    {
        const int stride = Right - Left + 1;
        Span<byte> band = stackalloc byte[(to - from + 8) * stride];
        for (int y = from - 4; y < to + 4; y++)
            grid.Row(y, band.Slice((y - from + 4) * stride, stride));
        int count = 0;
        for (int y = from; y < to; y++)
        {
            var row = band.Slice((y - from + 4) * stride, stride);
            var above = band.Slice((y - from + 1) * stride, stride);
            var below = band.Slice((y - from + 7) * stride, stride);
            var rimAbove = band.Slice((y - from) * stride, stride);
            var rimBelow = band.Slice((y - from + 8) * stride, stride);
            int start = -1;
            for (int x = 105 - Left; x <= 294 - Left; x++)
            {
                int surround = Math.Min(above[x], below[x]);
                if (x < 294 - Left && surround - row[x] >= Math.Clamp(surround / 3, 14, 25))
                {
                    if (start < 0) start = x;
                    continue;
                }
                int length = x - start;
                if (start >= 0 && length >= min && length <= max)
                {
                    int center = start + length / 2, end = x + 1, border = start - 2;
                    Span<byte> rim = [rimAbove[border], rimAbove[center], rimAbove[end], rimBelow[border],
                        rimBelow[center], rimBelow[end], row[border], row[end]];
                    rim.Sort();
                    int rimTone = (rim[3] + rim[4]) / 2;
                    int contrast = rimTone - row[center];
                    if (contrast >= Math.Clamp(rimTone / 3, 20, 33) && rim[7] - rim[0] <= Math.Max(24, contrast * 3 / 4))
                    {
                        if (count == slots.Length) return -1; // Fazla adaylı menüde OCR açma (-1: çok aday, Probe için).
                        slots[count++] = new Slot(Left + (start + x - 1) * .5, y, length, contrast);
                    }
                }
                start = -1;
            }
        }
        return count;
    }

    private static bool HasCamera(Samples grid, Slot top)
    {
        for (int side = -1; side <= 1; side += 2)
            for (int d = Math.Max(5, (int)Math.Round(top.Length * .62)); d <= (int)Math.Round(top.Length * 1.15); d++)
                for (int y = top.Y - 2; y <= top.Y + 2; y++)
                {
                    int x = (int)Math.Round(top.X) + side * d;
                    int center = grid.At(x, y);
                    int a = grid.At(x, y - 3), b = grid.At(x, y + 3), c = grid.At(x - 3, y), e = grid.At(x + 3, y);
                    int min = Math.Min(Math.Min(a, b), Math.Min(c, e));
                    int max = Math.Max(Math.Max(a, b), Math.Max(c, e));
                    if (min - center >= Math.Clamp(min / 3, 15, 23) && max - min < Math.Max(25, top.Contrast * .9)) return true;
                }
        return false;
    }

    private static bool SmoothRim(Samples grid, Slot slot, double dx, int h)
    {
        int r = (int)(h * .14), flat = 0;
        ReadOnlySpan<int> offsets = [-r, 3 - r, r - 3, r];
        foreach (int k in offsets)
        {
            int x = (int)Math.Round(slot.X) + k, y = slot.Y + (int)Math.Round(-k * dx / h);
            if (Math.Abs(grid.At(x, y - 2) - grid.At(x, y + 2)) < 16) flat++;
        }
        return flat >= 3;
    }

    // İki yarık da yazı alanının dışında kalmalı: üst yarığın altında, alt yarığın üstünde ekran-kasa sınırını ara.
    private static int RimBoundary(Samples grid, Slot slot, double dx, int h, bool lower)
    {
        Span<int> samples = stackalloc int[5];
        int best = 0;
        for (int distance = lower ? -10 : 3; distance <= (lower ? -4 : 7); distance += 2)
        {
            for (int i = -2; i <= 2; i++)
            {
                double k = i * .08;
                int x = (int)Math.Round(slot.X + k * h + dx * distance * .01);
                int y = (int)Math.Round(slot.Y + h * distance * .01 - (lower ? .8 : .52) * dx * k);
                samples[i + 2] = Math.Abs(grid.At(x, y - 2) - grid.At(x, y + 2));
            }
            samples.Sort();
            best = Math.Max(best, samples[2]);
        }
        return best;
    }

    // İki paralel uzun kenarı ayrı ayrı doğrula; ekrandaki bir metin çizgisi hoparlör gibi görünebilir.
    private static int SideStrength(Samples grid, Slot top, double dx, int h, int side)
    {
        ReadOnlySpan<double> heights = [.1, .24, .39, .54, .69, .84];
        Span<int> samples = stackalloc int[6];
        int best = 0;
        for (int width = 23; width <= 27; width++)
        {
            double radius = side * width * .01;
            for (int i = 0; i < heights.Length; i++)
            {
                int x = (int)Math.Round(top.X + heights[i] * dx + radius * h);
                int y = (int)Math.Round(top.Y + heights[i] * h - radius * dx);
                int strongest = 0;
                for (int k = -2; k <= 2; k += 2)
                    strongest = Math.Max(strongest, Math.Abs(grid.At(x + k - 2, y) - grid.At(x + k + 2, y)));
                samples[i] = strongest;
            }
            samples.Sort();
            best = Math.Max(best, (samples[2] + samples[3]) / 2);
        }
        return best;
    }

    // İki bant ve birkaç kenar noktası, kaynak çözünürlüğünden bağımsız sayıda örnek.
    private readonly ref struct Samples
    {
        private readonly Frame frame;
        private readonly Span<int> x1, x2;
        private readonly int top, height;
        internal Samples(Frame frame, Span<int> columns, (int X, int Y, int Width, int Height) area)
        {
            this.frame = frame;
            top = area.Y;
            height = area.Height;
            x1 = columns[..Width];
            x2 = columns[Width..];
            for (int x = 0; x < Width; x++)
            {
                x1[x] = (area.X + (4 * x + 1) * area.Width / (4 * Width)) * 4;
                x2[x] = (area.X + (4 * x + 3) * area.Width / (4 * Width)) * 4;
            }
        }

        internal void Row(int y, scoped Span<byte> dest)
        {
            (int a, int b) = Rows(y);
            for (int i = 0; i < dest.Length; i++)
                dest[i] = (byte)Sample(Left + i, a, b);
        }

        internal int At(int x, int y)
        {
            (int a, int b) = Rows(y);
            return Sample(x, a, b);
        }

        private (int, int) Rows(int y) => (
            (top + (4 * y + 1) * height / (4 * Height)) * frame.Stride,
            (top + (4 * y + 3) * height / (4 * Height)) * frame.Stride);

        private int Sample(int x, int row1, int row2)
        {
            int a = x1[x], b = x2[x];
            return (Tone(row1 + a) + Tone(row1 + b) + Tone(row2 + a) + Tone(row2 + b)) >> 10;
        }

        private int Tone(int p) => frame.Pixels[p] * 29 + frame.Pixels[p + 1] * 150 + frame.Pixels[p + 2] * 77;
    }
}
