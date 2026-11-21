// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell;

/// <summary>Bir ekran alanı (WPF birimiyle).</summary>
public readonly record struct ScreenArea(double Left, double Top, double Width, double Height)
{
    public double Right => Left + Width;
    public double Bottom => Top + Height;

    /// <summary>Sonlu ve boş olmayan alan (ekran bilgisi okunamayınca sıfır ya da NaN gelebilir).</summary>
    public bool IsUsable => double.IsFinite(Left) && double.IsFinite(Top) && double.IsFinite(Width) && double.IsFinite(Height)
                            && Width > 0 && Height > 0;
}

/// <summary>
/// Bilgisayar ekranındaki altyazı penceresinin yeri ve boyu. Kayıtlı yer bozuksa (NaN, sıfır genişlik) ya da artık
/// bağlı olmayan bir ekrandaysa pencere ana ekranın altında ortada açılır; WPF'e hiçbir zaman geçersiz değer verilmez.
/// </summary>
public static class OverlayPlacement
{
    public const double SmallestWidth = 320;
    /// <summary>Kayıtlı yerin ekranda en az bu kadarı görünmüyorsa pencere varsayılan yere döner.</summary>
    public const double VisiblePart = 80;
    /// <summary>Ekran bilgisi hiç okunamazsa kullanılan alan.</summary>
    private static readonly ScreenArea Fallback = new(0, 0, 1280, 720);

    /// <summary>Yazı boyu TV'deki gibi 1080 satırlık ekrana göredir.</summary>
    public static double Scale(double primaryScreenHeight) =>
        double.IsFinite(primaryScreenHeight) && primaryScreenHeight > 0 ? Math.Clamp(primaryScreenHeight / 1080, 0.5, 4) : 1;

    /// <summary>Ayarlardaki yazı boyu; bozuk kayıtta varsayılan, uç değerlerde sınırda.</summary>
    public static double FontSize(int fontSize) => fontSize > 0 ? Math.Clamp(fontSize, 12, 200) : 46;

    /// <summary>Pencere en çok üç satıra (ve satırların kaymasına) yetecek kadar yüksektir.</summary>
    public static double Height(int fontSize, double scale) => Math.Round(FontSize(fontSize) * scale * 8.1 + 140 * scale);

    /// <summary>Yükseklik oranının sınırları: pencere en az bir satıra, en çok yazı boyunun üç katı yüksekliğe kadar.</summary>
    public const double SmallestHeightScale = 0.5;
    public const double LargestHeightScale = 3;

    /// <summary>Kayıtlı yükseklik oranı; bozuk kayıtta 1, uç değerlerde sınırda.</summary>
    public static double ClampHeightScale(double scale) =>
        double.IsFinite(scale) && scale > 0 ? Math.Clamp(scale, SmallestHeightScale, LargestHeightScale) : 1;

    /// <summary>Kenardan büyütülen ya da küçültülen pencerenin yüksekliği, yazı boyundan hesaplanana oranla.</summary>
    public static double HeightScaleFor(double height, double baseHeight) =>
        double.IsFinite(height) && double.IsFinite(baseHeight) && baseHeight > 0 ? ClampHeightScale(height / baseHeight) : 1;

    /// <summary>Okunan satır yüksekliğinden yazı boyuna geçiş (TV uygulamasının ekran yazısında kullandığı oran).</summary>
    public const double GameTextRatio = 0.95;

    /// <summary>
    /// "Yazı boyu oyundaki altyazı kadar": son altyazı kutularının yüksekliklerinin (kareye oranla) ortancası; altyazıların
    /// çoğu tek satır olduğundan ortanca bir satırın yüksekliğidir. Ekran yüksekliğiyle çarpılıp <see cref="GameTextRatio"/>
    /// ile yazı boyuna çevrilir ve seçilen boyun (<paramref name="manual"/>) %70–150'si arasında tutulur. Ölçüm yoksa seçilen boy.
    /// </summary>
    public static double GameTextSize(IReadOnlyCollection<double> boxHeights, double screenHeight, double manual)
    {
        if (boxHeights.Count == 0 || !double.IsFinite(screenHeight) || screenHeight <= 0 || !(manual > 0)) return manual;
        var sorted = boxHeights.Order().ToArray();
        var middle = sorted.Length / 2;
        var median = sorted.Length % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
        return Math.Clamp(GameTextRatio * median * screenHeight, manual * 0.7, manual * 1.5);
    }

    /// <summary>Pencere yüksekliğinin hesaplandığı yazı boyu: oyundaki kadar açıkken yazı seçilenin %150'sine kadar büyüyebilir.</summary>
    public static int WindowFontSize(CouchSubs.Core.SubtitleStyle style) =>
        style.AutoTextSize ? (int)Math.Ceiling(FontSize(style.FontSize) * 1.5) : style.FontSize;

    /// <summary>"Yazı kadar" kutunun oyundaki altyazıyı örterken her yana bıraktığı pay (1080 satırlık ekranda piksel).</summary>
    public const double CoverMargin = 8;

    /// <summary>
    /// "Yazı kadar" zeminde kutunun oyundaki altyazıyı örtmesi için en küçük dış boyu: altyazının karedeki kutusu ekran
    /// boyuyla çarpılır (oyun görüntüsü ekranı kaplıyor sayılır), her yana <see cref="CoverMargin"/> eklenir. Kutu yoksa,
    /// boşsa ya da altyazı olamayacak kadar yüksekse (karenin yarısından fazla) null; kutu eskisi gibi yazı kadar kalır.
    /// </summary>
    public static (double Width, double Height)? CoverSize(CouchSubs.Core.TextBox? box, double screenWidth, double screenHeight, double scale)
    {
        if (box is not { } b || !double.IsFinite(scale) || scale <= 0) return null;
        var width = (b.Right - b.Left) * screenWidth;
        var height = (b.Bottom - b.Top) * screenHeight;
        if (!double.IsFinite(width) || !double.IsFinite(height) || width <= 0 || height <= 0 || b.Bottom - b.Top > 0.5) return null;
        var margin = 2 * CoverMargin * scale;
        return (width + margin, height + margin);
    }

    /// <summary>
    /// Kayıtlı yer ya da çalışma alanının altında ortada, %70 genişlikte. Kayıt bir ekranın adını taşıyorsa ve o ekran
    /// bağlıysa yer o ekrana göre hesaplanır (ekranların dizilişi değişse de pencere aynı ekranda kalır); ekran artık
    /// yoksa ya da eski kayıtsa tüm ekranlardaki yeri, o da görünmüyorsa varsayılan yer. <paramref name="height"/> yazı
    /// boyundan hesaplanan yüksekliktir; kayıttaki oran buna uygulanır.
    /// </summary>
    public static OverlayBounds Place(OverlayBounds? saved, ScreenArea virtualScreen, ScreenArea workArea, double height,
        IReadOnlyList<DisplayArea>? displays = null)
    {
        var work = workArea.IsUsable ? workArea : virtualScreen.IsUsable ? virtualScreen : Fallback;
        var screen = virtualScreen.IsUsable ? virtualScreen : work;
        if (!double.IsFinite(height) || height <= 0) height = Height(0, 1);
        if (saved is { } s && double.IsFinite(s.Width) && s.Width > 0)
        {
            var heightScale = ClampHeightScale(s.HeightScale);
            var tall = height * heightScale;
            var width = Math.Clamp(s.Width, SmallestWidth, Math.Max(SmallestWidth, screen.Width));
            if (s.Screen is { } name && s.ScreenLeft is { } dx && s.ScreenTop is { } dy && double.IsFinite(dx) && double.IsFinite(dy)
                && displays?.FirstOrDefault(d => d.Name == name && d.Area.IsUsable) is { Name: not null } display)
            {
                var left = display.Area.Left + dx;
                var top = display.Area.Top + dy;
                if (Visible(left, top, width, tall, display.Area))
                    return s with { Left = left, Top = top, Width = width, HeightScale = heightScale };
            }
            if (double.IsFinite(s.Left) && double.IsFinite(s.Top) && Visible(s.Left, s.Top, width, tall, screen))
                return s with { Width = width, HeightScale = heightScale };
        }
        var placed = Math.Max(SmallestWidth, Math.Round(work.Width * 0.7));
        return new OverlayBounds(work.Left + (work.Width - placed) / 2, work.Bottom - work.Height * 0.04 - height, placed);
    }

    /// <summary>Pencerenin üstünde en çok kaldığı ekran (yoksa null).</summary>
    public static DisplayArea? DisplayOf(double left, double top, double width, double height, IReadOnlyList<DisplayArea> displays)
    {
        DisplayArea? best = null;
        var most = 0.0;
        foreach (var display in displays)
        {
            if (!display.Area.IsUsable) continue;
            var across = Math.Min(left + width, display.Area.Right) - Math.Max(left, display.Area.Left);
            var down = Math.Min(top + height, display.Area.Bottom) - Math.Max(top, display.Area.Top);
            var area = Math.Max(0, across) * Math.Max(0, down);
            if (area > most) { most = area; best = display; }
        }
        return best;
    }

    /// <summary>Kaydedilecek yer, yükseklik oranı ve ekran; değerlerden biri sonlu değilse (JSON'a yazılamaz) kaydedilmez.</summary>
    public static OverlayBounds? ToSave(double left, double top, double width, double height, double baseHeight,
        IReadOnlyList<DisplayArea> displays)
    {
        if (ToSave(left, top, width) is not { } bounds || !double.IsFinite(height)) return null;
        bounds = bounds with { HeightScale = Math.Round(HeightScaleFor(height, baseHeight), 3) };
        return DisplayOf(left, top, width, height, displays) is { } display
            ? bounds with { Screen = display.Name, ScreenLeft = Math.Round(left - display.Area.Left), ScreenTop = Math.Round(top - display.Area.Top) }
            : bounds;
    }

    /// <summary>Kenardan genişletilen pencerenin yeni genişliği: en az <see cref="SmallestWidth"/>, en çok tüm ekranlar.</summary>
    public static double ClampWidth(double width, double virtualScreenWidth)
    {
        // Ekranların genişliği okunamadıysa üst sınır yok.
        var widest = double.IsFinite(virtualScreenWidth) ? Math.Max(SmallestWidth, virtualScreenWidth) : double.MaxValue;
        return double.IsFinite(width) ? Math.Clamp(width, SmallestWidth, widest) : SmallestWidth;
    }

    /// <summary>Kaydedilecek yer; değerlerden biri sonlu değilse (JSON'a yazılamaz) kaydedilmez.</summary>
    public static OverlayBounds? ToSave(double left, double top, double width) =>
        double.IsFinite(left) && double.IsFinite(top) && double.IsFinite(width) && width > 0
            ? new OverlayBounds(Math.Round(left), Math.Round(top), Math.Round(width))
            : null;

    private static bool Visible(double left, double top, double width, double height, ScreenArea screen)
    {
        var across = Math.Min(left + width, screen.Right) - Math.Max(left, screen.Left);
        var down = Math.Min(top + height, screen.Bottom) - Math.Max(top, screen.Top);
        return across >= Math.Min(VisiblePart, width) && down >= Math.Min(VisiblePart, height);
    }
}
