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
    /// <summary>
    /// Işık denemeleri: gözlem telefonun yeriyle; açık telefon ıskalanınca ekran ışığına gerçek karede bakılır
    /// (<see cref="PhoneGlow"/>; iz karşılaştırılmaz).
    /// </summary>
    internal GamePhoneTracker(Func<Frame, (GamePhoneGeometry.Pose Pose, bool Strict)?> sight, bool glows) : this()
    {
        poseOverride = sight;
        this.glows = glows;
    }
    private readonly Func<Frame, (GamePhoneGeometry.Pose Pose, bool Strict)?>? poseOverride;
    /// <summary>Açık telefon ıskalanınca son yerinde izi karşılaştırılır mı (<see cref="PhonePrint"/>; yalnız gerçek aramada).</summary>
    private bool Holds => locateOverride is null && poseOverride is null;
    /// <summary>
    /// Açık telefon arama ve izde ıskalanınca son yerinde ekranının ışığına bakılır mı (<see cref="PhoneGlow"/>; gerçek
    /// aramada ve ışık denemelerinde).
    /// </summary>
    private readonly bool glows = true;
    /// <summary>Son gerçek gözlemde ışıklı ekran (karanlık sahnede; yoksa null), alındığı an, ışıkla tutuluyor mu ve son ölçülen ışık.</summary>
    private PhoneGlow.Glow? glow;
    private long? glowAt;
    private bool glowing;
    private PhoneGlow.Glow? lastGlow;

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
    private readonly PhoneSearchStatus status = new();

    /// <summary>
    /// Açık telefonun yeni gözlemi en çok bu kadar oynadıysa (kutunun her kenarı, kareye oranla) aynı telefondur; sıkı
    /// aramanın gözleminde <see cref="StrictMoveTolerance"/> (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal const double SameTolerance = .035, StrictMoveTolerance = .1;

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
        if (poseOverride is not null)
        {
            var sighting = poseOverride(frame);
            pose = sighting?.Pose;
            candidate = pose?.Bounds;
            strict = sighting?.Strict == true;
            points = strict ? StrongPoints : WeakPoints;
        }
        else if (locateOverride is not null)
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
        // Açık telefon bu örnekte bulunamadı: son yerinde izi tutuyorsa telefon yerinde sayılır (PhonePrint). Karanlıkta sıkı
        // arama telefonu ara sıra buluyor, açılan telefon iki ıskada kapanıp yeniden açılmıyordu (X, beta-107: "bir kez
        // çevrildi, sonra kayboldu").
        var held = false;
        lastSimilarity = 0;
        if (Holds && candidate is null && shown is not null && shownPose is { } open && print is { } kept)
        {
            var hold = GamePhoneGeometry.Hold(frame, open, kept);
            lastSimilarity = hold.Similarity;
            if (hold.Pose is { } heldPose)
            {
                pose = heldPose;
                candidate = heldPose.Bounds;
                points = WeakPoints;
                strict = false;
                held = true;
            }
        }
        // Açık telefon aramada da izde de ıskalandı: karanlık sahnede ekranı son gerçek gözlemdeki kadar aydınlıksa ve çevresi
        // karanlıksa telefon yerinde sayılır, PhoneGlow.HoldMs dolana dek kapanmaz (#1443: kasa koyu ve düz, iz tutmuyor,
        // telefon ~1 sn'de bir kapanıp açılıyordu). Telefon indirilince son yerde ışık kalmaz, her zamanki sürede kapanır.
        bool glowHeld = false, glowExpired = false;
        lastGlow = null;
        if (glows && candidate is null && shown is not null && shownPose is { } lastPose && glow is { } recorded)
        {
            if (Elapsed(lastSeen, now) < PhoneGlow.HoldMs)
            {
                lastGlow = GamePhoneGeometry.Glow(frame, lastPose);
                glowHeld = lastGlow is { } current && PhoneGlow.Holds(recorded, current);
            }
            else glowExpired = true;
        }
        long unseenMs = 0;
        var unseenMisses = 0;
        CropRegion? movedFrom = null;
        if (shown is not null && candidate is not null && candidate.IsClose(shown, strict ? StrictMoveTolerance : SameTolerance))
        {
            // Açık telefonun yakınında tek gözlem: aynı telefon, yeri güncellenir. Sıkı aramanın bulduğu telefon daha çok
            // oynamış da olabilir (el hızlı oynadı): yine aynı telefon sayılır, önceden ıska sayılıp telefonu kapatıyordu.
            shown = candidate;
            shownPose = pose;
            misses = 0;
            lastSeen = now;
            if (!held)
            {
                KeepPrint(frame, pose, now);
                KeepGlow(frame, pose, now);
            }
        }
        else if (shown is not null && (glowHeld || !Closes(misses + 1, Elapsed(lastSeen, now))))
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
            if (pending is not null && candidate.IsClose(pending, SameTolerance) && (pendingMisses == 0 || PendingFresh(now)))
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
                print = null;
                glow = null;
                glowAt = null;
                KeepPrint(frame, pose, now);
                KeepGlow(frame, pose, now);
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
        else if (wasShown && shown is null)
        {
            Trace(PhoneTrace.ClosedAfter(unseenMs, unseenMisses));
            if (Holds && print is not null) Trace(PhoneTrace.PrintLost(lastSimilarity));
            if (glowExpired) Trace(PhoneTrace.GlowExpired);
            else if (glows && glow is not null && lastGlow is { } lost) Trace(PhoneTrace.GlowLost(lost.Screen, lost.Ring));
            print = null;
            glow = null;
            glowAt = null;
            lastGlow = null;
        }
        if (held && !holding) Trace(PhoneTrace.Held(lastSimilarity));
        holding = held && shown is not null;
        if (glowHeld && !glowing && lastGlow is { } litNow) Trace(PhoneTrace.GlowHeld(litNow.Screen, litNow.Ring));
        glowing = glowHeld && shown is not null;
        // Telefon art arda iki örnekte bulundu ama yeri çok oynadı: hiç açılmıyor, okuma da başlamıyor (önceden sessizdi).
        if (shown is null && candidate is not null && movedFrom is not null)
            Trace(PhoneTrace.Moving(PhoneTrace.Shift(candidate, movedFrom)));
        // İlk açılış ıskalanınca nedeni (en ileri geçilen ölçüt, en iyi aday) sınırlı aralıkla günlüğe (#1251).
        if (shown is not null) missLog.Reset();
        else if (probe is { } missed) missLog.Note(missed, now, Trace);
        // Arama durumu 30 sn'de bir (telefon hiç bulunamasa da): ıska ölçütü, parlaklık, kare (Mac/iPhone ve Android aynı).
        if (status.Note(probe, candidate is not null, now))
            Trace(status.Line(shown is not null, frame.Width, frame.Height, PhoneSearchStatus.Median(frame), frame.Source));
        visible = shown;
        return true;
    }

    /// <summary>Açık telefonun izi (son gerçek gözlemden; <see cref="PhonePrint"/>), alındığı an ve iz tutuyor mu.</summary>
    private int[]? print;
    private long printAt;
    private bool holding;
    private double lastSimilarity;
    /// <summary>İz gerçek gözlemde en çok bu aralıkla (ms) yenilenir.</summary>
    internal const long PrintRefreshMs = 1000;

    /// <summary>Açık telefonun izini gerçek gözlemden alır (en çok <see cref="PrintRefreshMs"/>'de bir; denemelerin sahte gözlemlerinde alınmaz).</summary>
    private void KeepPrint(Frame frame, GamePhoneGeometry.Pose? pose, long now)
    {
        if (!Holds || pose is not { } at) return;
        if (print is not null && now >= printAt && now - printAt < PrintRefreshMs) return;
        if (GamePhoneGeometry.Print(frame, at) is not { } fresh) return;
        print = fresh;
        printAt = now;
    }

    /// <summary>
    /// Açık telefonun ekran ışığını gerçek gözlemden alır (en çok <see cref="PrintRefreshMs"/>'de bir): karanlık sahnede ışıklı
    /// ekran (<see cref="PhoneGlow.Lit"/>) değilse null.
    /// </summary>
    private void KeepGlow(Frame frame, GamePhoneGeometry.Pose? pose, long now)
    {
        if (!glows || pose is not { } at) return;
        if (glowAt is { } taken && now >= taken && now - taken < PrintRefreshMs) return;
        glow = GamePhoneGeometry.Glow(frame, at) is { } fresh && PhoneGlow.Lit(fresh) ? fresh : null;
        glowAt = now;
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
    /// telefonun sınır kutusu dikey telefondan geniştir), yüksekliği karenin en çok %85'i, genişliği en çok yarısı, merkezi karenin sol kenarında (<see cref="GamePhoneGeometry.MinCenterX"/>'in solu; sol eldeki telefon geçer) ya da üst üçte birinde değil.
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
        return centerX >= GamePhoneGeometry.MinCenterX && centerY >= 1.0 / 3;
    }

    public void Reset()
    {
        lastTime = null;
        shown = null;
        misses = 0;
        lastSeen = 0;
        shownPose = null;
        ClearPending();
        print = null;
        holding = false;
        glow = null;
        glowAt = null;
        glowing = false;
        lastGlow = null;
        missLog.Reset();
        status.Reset();
    }
}

internal static class GamePhoneGeometry
{
    private const int Width = 400, Height = 225, Left = ScanLeft - 10;
    /// <summary>
    /// Yarıkların arandığı en sağ sütun (400×225 ızgarada; arama <see cref="ScanLeft"/>'ten başlar). Önceden 294'tü (karenin %73,5'i): GTA 6
    /// telefonu sağ elde ~%70'te durur, hoparlör yarığının sağ ucu sınıra değiyordu; telefon %1,5 sağa oynayınca yarık
    /// kesiliyor, sıkı arama da gevşek doğrulama da "hoparlör yarığı yok"ta kalıyordu (#1251, beta-104 günlüğü: telefon
    /// açılıp ~1,1 sn içinde kapanıyor, sonraki aramaların çoğu hoparlör yarığında kalıyor; Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal const int ScanRight = 324;
    /// <summary>
    /// Yarıkların arandığı en sol sütun: <see cref="ScanRight"/>'ın aynası (400 − 324). Telefon sol elde tutulunca (#1385,
    /// beta-105) görüntü aynalanır, hoparlör yarığı karenin ~%30'unda durur; arama önceden 105'ten (%26) başlıyordu, telefon
    /// biraz sola oynayınca yarık kesiliyordu (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal const int ScanLeft = Width - ScanRight;
    /// <summary>
    /// Telefon kutusunun merkezi bu sınırın solundaysa akla yatkın değil (karenin sol kenarındaki HUD, harita). Önceden
    /// 0,35'ti: sol eldeki telefonun merkezi ~0,30'da kaldığından izleyici onu hiç açmıyordu, telefon ne okunuyor ne de ekran
    /// yazısından dışlanıyordu (#1385; Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal const double MinCenterX = 0.2;
    private const int Right = ScanRight + 10;
    /// <summary>Parlaklığın ölçüldüğü sütunlar (üst şeritte, <see cref="DarkGains"/>).</summary>
    private const int LevelLeft = 95, LevelRight = 305;
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

    /// <summary>Simsiyah şerit: örneklerin hepsi bu tondan koyu (0–255). Önceden 24'tü: karanlık sahnede (gece, karartılmış oyun) görüntünün kenar sütunları ve alt satırları da şerit sayılıp kırpılıyor, 16:9 olmayan pencerede (Remote Play, şeritli ya da başlık çubuklu) oyun görüntüsü küçük ve kaymış bulunuyor, telefon aranamıyordu. Oyun penceresinin şeritleri simsiyahtır (0–3).</summary>
    internal const int DarkTone = 8;

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
        if (PictureArea(frame) is not { } area) return false;
        // Açık telefonun yeri görüntünün içine taşınır.
        Pose? local = near is { } last ? Inside(frame, area, last) : null;
        var located = TryLocate(frame, area, local, out var within, out probe);
        if (probe.Candidate is { } candidate) probe = probe with { Candidate = Outside(frame, area, candidate) };
        if (!located) return false;
        pose = Outside(frame, area, within);
        return true;
    }

    /// <summary>Karedeki 16:9 oyun görüntüsü (<see cref="Picture"/>); kare zaten 16:9 ise tamamı.</summary>
    private static (int X, int Y, int Width, int Height)? PictureArea(Frame frame)
    {
        if (frame.Width < Width || frame.Height < Height || !frame.IsConsistent) return null;
        if (Widescreen(frame.Width, frame.Height)) return (0, 0, frame.Width, frame.Height);
        int Tone(int x, int y)
        {
            var p = (y * frame.Stride) + (x * 4);
            return (frame.Pixels[p] * 29 + frame.Pixels[p + 1] * 150 + frame.Pixels[p + 2] * 77) >> 8;
        }
        return Picture(frame.Width, frame.Height, Tone);
    }

    /// <summary>Karedeki yer görüntünün içine.</summary>
    private static Pose Inside(Frame frame, (int X, int Y, int Width, int Height) area, Pose pose) =>
        new((pose.TopX * frame.Width - area.X) / area.Width, (pose.TopY * frame.Height - area.Y) / area.Height,
            (pose.BottomX * frame.Width - area.X) / area.Width, (pose.BottomY * frame.Height - area.Y) / area.Height);

    /// <summary>Görüntüdeki yer karenin içine.</summary>
    private static Pose Outside(Frame frame, (int X, int Y, int Width, int Height) area, Pose pose) =>
        new((area.X + pose.TopX * area.Width) / frame.Width, (area.Y + pose.TopY * area.Height) / frame.Height,
            (area.X + pose.BottomX * area.Width) / frame.Width, (area.Y + pose.BottomY * area.Height) / frame.Height);

    /// <summary>Görüntünün 400×225 ızgarasının kazançsız ham tonları (<see cref="PhonePrint"/>), satır satır.</summary>
    private static int[] RawGrid(Frame frame, (int X, int Y, int Width, int Height) area)
    {
        Span<int> columns = stackalloc int[Width * 2];
        var grid = new Samples(frame, columns, area, 256);
        return grid.RawGrid();
    }

    /// <summary>Telefonun izi (<see cref="PhonePrint"/>): <paramref name="pose"/>'taki telefonun kasasından üst ve alt şeritte örnekler.</summary>
    internal static int[]? Print(Frame frame, Pose pose)
    {
        if (PictureArea(frame) is not { } area) return null;
        return PhonePrint.Samples(Inside(frame, area, pose), 0, 0, RawGrid(frame, area));
    }

    /// <summary>Telefonun ekran ışığı (<see cref="PhoneGlow"/>); görüntü bulunamazsa null.</summary>
    internal static PhoneGlow.Glow? Glow(Frame frame, Pose pose)
    {
        if (PictureArea(frame) is not { } area) return null;
        return PhoneGlow.Measure(Inside(frame, area, pose), RawGrid(frame, area));
    }

    /// <summary>
    /// Açık telefonun son yerinde izi tutuyor mu (<see cref="PhonePrint.Match"/>): tutarsa izin bulunduğu yer (kayma kadar
    /// oynamış), tutmazsa null; en iyi benzerlik.
    /// </summary>
    internal static (Pose? Pose, double Similarity) Hold(Frame frame, Pose pose, int[] print)
    {
        if (PictureArea(frame) is not { } area) return (null, 0);
        var local = Inside(frame, area, pose);
        var match = PhonePrint.Match(print, local, RawGrid(frame, area));
        if (match.Similarity < PhonePrint.HoldSimilarity) return (null, match.Similarity);
        var moved = new Pose(local.TopX + match.Dx / 400.0, local.TopY + match.Dy / 225.0,
                             local.BottomX + match.Dx / 400.0, local.BottomY + match.Dy / 225.0);
        return (Outside(frame, area, moved), match.Similarity);
    }

    // Telefon karenin içindeki 16:9 görüntüde (area) aranır; yer görüntüye göre 0..1.
    private static bool TryLocate(Frame frame, (int X, int Y, int Width, int Height) area, Pose? near, out Pose pose, out Probe probe)
    {
        pose = default;
        probe = Probe.Missed(Step.NoPicture);
        if (area.Width < Width || area.Height < Height || !Widescreen(area.Width, area.Height)) return false;
        Span<int> columns = stackalloc int[Width * 2];
        var grid = new Samples(frame, columns, area, 256);
        int level = grid.Level();
        var located = Strict(grid, out pose, out probe);
        probe = probe with { Level = level };
        if (located) return true;
        var gains = DarkGains(level);
        foreach (var gain in gains)
        {
            var bright = grid.WithGain(gain);
            if (Strict(bright, out pose, out var dark))
            {
                probe = dark with { Level = level, Gain = gain };
                return true;
            }
            // Iskada en ileri geçilen ölçüt ve en iyi aday bütün aramalardan.
            if (dark.Step > probe.Step) probe = probe with { Step = dark.Step, Gain = gain };
            if (dark.Side > probe.Side) probe = probe with { Side = dark.Side, Candidate = dark.Candidate };
        }
        // Karanlık sahnede kazançlardan sonra ton eşitleme (Equalization); kare simsiyaha yakınsa denenmez (EqualizeFloor).
        var dim = level < DarkLevel && grid.Equalizable();
        if (dim)
        {
            var even = grid.Equalized();
            if (Strict(even, out pose, out var equal))
            {
                probe = equal with { Level = level, Gain = Equalized };
                return true;
            }
            if (equal.Step > probe.Step) probe = probe with { Step = equal.Step, Gain = Equalized };
            if (equal.Side > probe.Side) probe = probe with { Side = equal.Side, Candidate = equal.Candidate };
        }
        if (near is not { } last) return false;
        if (Confirm(grid, last, out pose)) return true;
        foreach (var gain in gains)
            if (Confirm(grid.WithGain(gain), last, out pose)) return true;
        return dim && Confirm(grid.Equalized(), last, out pose);
    }

    /// <summary>Karanlık sahne: üst şeridin ortanca tonu bundan azsa (0–255) sıkı arama kazançla da yapılır (<see cref="DarkGains"/>).</summary>
    internal const int DarkLevel = 56;
    /// <summary>Kazançlı aramada üst şeridin ortanca tonunun en çok taşındığı ton; denenen kazançlar (256 = 1×).</summary>
    internal const int DarkTarget = 96;
    /// <summary>
    /// Denenen kazançlar (×1,5–×12). Önceden en çok ×4'tü (1024): gece sahnesinde (beta-107 günlüğü, üst şerit 2–9/255)
    /// kasa ile hoparlör yarığı arasındaki fark birkaç tonda kalıyor, ×4'te de yarık eşiğinin (14 ton) altında kalıp sıkı
    /// arama "hoparlör yarığı yok"ta, "ön kamera yok"ta ve "alt çentik yok"ta takılıyordu; ton eşitleme ise geniş koyu
    /// alanlardaki tek tonluk kıpırtıyı onlarca tona büyütüp kasayı düz göstermiyordu ("kasa kenarı düz değil"). ×7 yalnız
    /// üst şerit 13/255, ×12 yalnız 8/255 ya da daha koyuyken denenir (<see cref="DarkTarget"/>); telefonsuz kareler bu
    /// karanlıkta da telefon açmıyor (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static readonly int[] GainSteps = [384, 640, 1024, 1792, 3072];

    /// <summary>Kazanç yerine ton eşitleme (<see cref="Equalization"/>): <see cref="Probe.Gain"/>'de bu değer.</summary>
    internal const int Equalized = 0;

    /// <summary>
    /// Ton eşitleme: ızgaranın ham tonlarının (çeyrek ton adımıyla; <paramref name="counts"/>, toplam <paramref name="total"/>)
    /// sırası 0–255'e yayılır (her ton, kendinden koyu ve yarısı kendisiyle aynı noktaların oranı). Parlaklıktan, gamadan ve
    /// gece renk ayarından bağımsızdır: tonları aynı sırada kalan her karartma aynı ızgarayı verir. Kazanç
    /// (<see cref="DarkGains"/>) karanlık sahnede yalnız ×4'e kadar aydınlatıyor, çok karanlıkta (üst şerit 10/255'ten koyu)
    /// ve gamayla koyulaşmış görüntüde (açık kasa açık kalır, gölgeler kararır) sıkı arama hoparlör yarığında, kamerada ya da
    /// kasa kenarında kalıyordu (X, beta-107: telefon gündüz çevriliyor, gece ve kapalı yerde çevrilmiyor; günlükte parlaklık
    /// 7–60/255). Karanlık sahnede kazançlardan sonra denenir (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static int[] Equalization(int[] counts, int total)
    {
        var map = new int[counts.Length];
        var below = 0;
        for (var tone = 0; tone < counts.Length; tone++)
        {
            map[tone] = Math.Min(255, 255 * (2 * below + counts[tone]) / Math.Max(1, 2 * total));
            below += counts[tone];
        }
        return map;
    }

    /// <summary>
    /// Ton eşitlemenin denendiği en koyu "parlak uç": ızgaranın en parlak %1'i (<see cref="BrightShare"/>) en az bu tonda
    /// (0–255) olmalı. Karenin tamamı simsiyaha yakınsa (parlak uç 2–7/255; kararan geçiş, gece sahnesinin en koyusu) ton
    /// eşitleme bir iki tonluk sıkıştırma kıpırtısını 0–255'e yayıp telefonsuz karede telefon kuruyordu (Android'de
    /// gta6-n4-bildirim × 0,04: telefon açıldı). Ton eşitlemenin bulduğu gerçek telefonlarda (gamayla koyulaşmış, karanlık
    /// oda) ekran aydınlık kalır, parlak uç 22/255 ve üstü; bundan koyu karede telefonu ×7 ve ×12 kazanç bulur
    /// (<see cref="GainSteps"/>; Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal const int EqualizeFloor = 16;

    /// <summary>Parlak ucun ölçüldüğü pay: ızgara örneklerinin en parlak yüzde biri (<see cref="EqualizeFloor"/>).</summary>
    internal const int BrightShare = 100;

    /// <summary>
    /// Ton eşitleme denenir mi (<see cref="EqualizeFloor"/>): ham ton sayılarında (<paramref name="counts"/>, çeyrek ton
    /// adımıyla, toplam <paramref name="total"/>) en parlak 1/<see cref="BrightShare"/>'ün en koyu tonu taban tonun
    /// (çeyrek ton adımıyla 4 × <see cref="EqualizeFloor"/>) altında değilse true.
    /// </summary>
    internal static bool Equalizable(int[] counts, int total)
    {
        var brighter = 0;
        for (var tone = counts.Length - 1; tone >= 0; tone--)
        {
            brighter += counts[tone];
            if (brighter * BrightShare >= total) return tone >= 4 * EqualizeFloor;
        }
        return false;
    }

    /// <summary>
    /// Karanlık sahnede denenen kazançlar (256 = 1×; küçükten büyüğe); sahne karanlık değilse boş. Kullanıcı bildirimi (X,
    /// beta.104): "telefonda parlaklık varsa çeviri oluyor karanlıksa olmuyor". Gece ya da karanlık odada telefonun kasası
    /// koyu, hoparlör yarığıyla kasa arasındaki fark mutlak eşiğin (14–20 ton) altında kalıyordu; sıkı arama hoparlör
    /// yarığında kalıyor, telefon hiç açılmıyordu. Ölçütler aynı, yalnız ızgara aydınlatılır. Sahne karanlık ama telefon
    /// aydınlıksa büyük kazanç kasayı doyurur: kazançlar küçükten denenir, üst şeridi <see cref="DarkTarget"/>'tan çok
    /// aydınlatan kazanç denenmez (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static int[] DarkGains(int level)
    {
        if (level >= DarkLevel) return [];
        int most = 256 * DarkTarget / Math.Max(8, level);
        var steps = GainSteps.Where(gain => gain <= most).ToArray();
        return steps.Length == 0 ? [GainSteps[0]] : steps;
    }

    /// <summary>
    /// Gevşek doğrulamada yarıklar açık telefonun son yerinden yatayda ve dikeyde en çok bu kadar (400×225 ızgarada) uzak
    /// olabilir: izleyicinin aynı telefon saydığı oynama kadar (<see cref="GamePhoneTracker.SameTolerance"/>, karenin %3,5'i).
    /// Önceden her yönde 4'tü (yatayda %1, dikeyde %1,8): el titreyince ya da telefon kaldırılınca 330 ms'de %2 oynayan
    /// telefon, sıkı arama da ıskalarsa ~1,1 sn sonra kapanıyordu (#1251, beta-104 günlüğü: "telefon kapandı (1141 ms
    /// görülmedi, 3 ıska)", telefon ekranda; Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal const double ConfirmReachX = 14.0, ConfirmReachY = 8.0;

    /// <summary>
    /// Açık telefonun son yerinde gevşek doğrulama: üstte kameralı hoparlör yarığı ve altta alt çentik, son yerin
    /// <see cref="ConfirmReachX"/>/<see cref="ConfirmReachY"/> kadar çevresinde, sıkı aramayla aynı boy ve oran kurallarıyla; yan kenarların ve çerçevenin
    /// gücüne bakılmaz (beyaz ekranda yanlar zemine karışır). Bulunmazsa false (Mac/iPhone ve Android ile aynı).
    /// </summary>
    private static bool Confirm(Samples grid, Pose near, out Pose pose)
    {
        pose = default;
        double topX = near.TopX * Width, topY = near.TopY * Height, bottomX = near.BottomX * Width, bottomY = near.BottomY * Height;
        if (!double.IsFinite(topX) || !double.IsFinite(bottomX) ||
            ConfirmRows(topY, 17, 75) is not var (upperFrom, upperTo) ||
            ConfirmRows(bottomY, 145, 217) is not var (lowerFrom, lowerTo)) return false;
        Span<Slot> upper = stackalloc Slot[12], lower = stackalloc Slot[16];
        int tops = FindSlots(grid, upperFrom, upperTo, 8, 19, upper);
        if (tops < 1) return false;
        int bottoms = FindSlots(grid, lowerFrom, lowerTo, 5, 14, lower);
        if (bottoms < 1) return false;
        double best = double.PositiveInfinity;
        var found = false;
        foreach (var top in upper[..tops])
        {
            if (Math.Abs(top.X - topX) > ConfirmReachX || !HasCamera(grid, top)) continue;
            foreach (var bottom in lower[..bottoms])
            {
                if (Math.Abs(bottom.X - bottomX) > ConfirmReachX) continue;
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
    /// Gevşek doğrulamanın tarandığı satırlar [from, to): <c>center ± ConfirmReachY</c>, [low, high) şeridinin içinde;
    /// şeritle kesişmiyorsa ya da yer sayı değilse null. #1369 (beta-104, Mac): son yer şeridin dışında kalınca (eksi ya da
    /// karenin altını aşan yer) Mac/iPhone'da aralık ters kuruluyor, uygulama çöküyordu; burada sayı olmayan ya da çok büyük
    /// yer <c>(int)</c> dönüşümünde taşıyordu. Önce kırpılır, boşsa atlanır (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static (int From, int To)? ConfirmRows(double center, int low, int high)
    {
        if (!double.IsFinite(center) || low >= high) return null;
        var reach = (int)ConfirmReachY;
        var c = (int)Math.Round(Math.Clamp(center, low - reach - 1, high + reach + 1), MidpointRounding.AwayFromZero);
        int from = Math.Max(low, c - reach), to = Math.Min(high, c + reach + 1);
        return from < to ? (from, to) : null;
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
    /// <para><see cref="Level"/>: üst şeridin ortanca tonu (0–255; -1: ölçülmedi); <see cref="Gain"/>: sonucu veren aramanın
    /// kazancı (256 = 1×; <see cref="DarkGains"/>).</para>
    internal readonly record struct Probe(Step Step, int Side, Pose? Candidate, int Level = -1, int Gain = 256)
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
        if (from >= to || from < 4 || to > Height - 4) return 0;
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
            for (int x = ScanLeft - Left; x <= ScanRight - Left; x++)
            {
                int surround = Math.Min(above[x], below[x]);
                if (x < ScanRight - Left && surround - row[x] >= Math.Clamp(surround / 3, 14, 25))
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
        /// <summary>Parlaklık kazancı (256 = 1×; <see cref="DarkGains"/>).</summary>
        private readonly int gain;
        /// <summary>Ton eşitleme (<see cref="Equalization"/>): ham tonun (dört noktanın toplamı / 256) eşlendiği ton; null: kazanç.</summary>
        private readonly int[]? map;
        internal Samples(Frame frame, Span<int> columns, (int X, int Y, int Width, int Height) area, int gain)
        {
            this.frame = frame;
            this.gain = gain;
            map = null;
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

        private Samples(Samples source, int gain, int[]? map = null)
        {
            frame = source.frame;
            x1 = source.x1;
            x2 = source.x2;
            top = source.top;
            height = source.height;
            this.gain = gain;
            this.map = map;
        }

        internal Samples WithGain(int gain) => new(this, gain);

        /// <summary>Ton eşitlemeli kopya (<see cref="Equalization"/>).</summary>
        internal Samples Equalized()
        {
            var counts = ToneCounts(out var total);
            return new(this, 256, Equalization(counts, total));
        }

        /// <summary>Ton eşitleme denenir mi (<see cref="GamePhoneGeometry.Equalizable(int[], int)"/>).</summary>
        internal bool Equalizable()
        {
            var counts = ToneCounts(out var total);
            return GamePhoneGeometry.Equalizable(counts, total);
        }

        /// <summary>Izgaranın her iki noktasında bir ham ton (çeyrek ton adımıyla, 0–1020) sayıları.</summary>
        private int[] ToneCounts(out int total)
        {
            var counts = new int[1021];
            total = 0;
            for (int y = 0; y < Height; y += 2)
            {
                (int a, int b) = Rows(y);
                for (int x = 0; x < Width; x += 2)
                {
                    counts[Math.Min(1020, Raw(x, a, b) >> 8)]++;
                    total++;
                }
            }
            return counts;
        }

        /// <summary>Üst şeridin (satır 0–89, sütun 95–305) ortanca tonu, kazançsız; her üç noktada bir örnek.</summary>
        internal int Level()
        {
            Span<int> counts = stackalloc int[256];
            int total = 0;
            for (int y = 0; y < 90; y += 3)
            {
                (int a, int b) = Rows(y);
                for (int x = LevelLeft; x <= LevelRight; x += 3)
                {
                    counts[Raw(x, a, b) >> 10]++;
                    total++;
                }
            }
            int sum = 0;
            for (int tone = 0; tone < 256; tone++)
            {
                sum += counts[tone];
                if (2 * sum >= total) return tone;
            }
            return 255;
        }

        /// <summary>Izgaranın kazançsız ham toplamları: dört noktanın tonu × 256 (0–261120; bir ton 1024), satır satır.</summary>
        internal int[] RawGrid()
        {
            var raw = new int[Width * Height];
            for (int y = 0; y < Height; y++)
            {
                (int a, int b) = Rows(y);
                for (int x = 0; x < Width; x++) raw[y * Width + x] = Raw(x, a, b);
            }
            return raw;
        }

                internal void Row(int y, scoped Span<byte> dest)
        {
            (int a, int b) = Rows(Math.Clamp(y, 0, Height - 1));
            for (int i = 0; i < dest.Length; i++)
                dest[i] = (byte)Sample(Left + i, a, b);
        }

        internal int At(int x, int y)
        {
            // Izgaranın dışındaki örnek kenardan okunur: dizinin dışına okumak hata atar (#1369).
            (int a, int b) = Rows(Math.Clamp(y, 0, Height - 1));
            return Sample(Math.Clamp(x, 0, Width - 1), a, b);
        }

        private (int, int) Rows(int y) => (
            (top + (4 * y + 1) * height / (4 * Height)) * frame.Stride,
            (top + (4 * y + 3) * height / (4 * Height)) * frame.Stride);

        private int Sample(int x, int row1, int row2)
        {
            int sum = Raw(x, row1, row2);
            if (map is not null) return map[Math.Min(map.Length - 1, sum >> 8)];
            return gain == 256 ? sum >> 10 : (int)Math.Min(255, ((long)sum * gain) >> 18);
        }

        private int Raw(int x, int row1, int row2)
        {
            int a = x1[x], b = x2[x];
            return Tone(row1 + a) + Tone(row1 + b) + Tone(row2 + a) + Tone(row2 + b);
        }

        private int Tone(int p) => frame.Pixels[p] * 29 + frame.Pixels[p + 1] * 150 + frame.Pixels[p + 2] * 77;
    }
}
