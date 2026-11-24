// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell.Tests;

/// <summary>Bilgisayar ekranındaki altyazı penceresinin yeri: bozuk ya da eski kayıt pencereyi ekran dışına ya da sıfır boya koymaz.</summary>
public class OverlayPlacementTests
{
    /// <summary>1920×1080 tek ekran, altta 48 birimlik görev çubuğu.</summary>
    private static readonly ScreenArea Screen = new(0, 0, 1920, 1080);
    private static readonly ScreenArea Work = new(0, 0, 1920, 1032);
    private const double Height = 500;

    private static void AssertDefault(OverlayBounds placed)
    {
        Assert.Equal(1344, placed.Width);
        Assert.Equal((1920 - 1344) / 2.0, placed.Left);
        Assert.Equal(1032 - 1032 * 0.04 - Height, placed.Top, 6);
    }

    /// <summary>"Yazı kadar" kutu oyundaki altyazının ekrandaki boyu kadar, her yana 8 piksel (1080p'ye göre) pay.</summary>
    [Fact]
    public void CoverSizeIsTheSubtitleOnScreenPlusMargin()
    {
        var box = new CouchSubs.Core.TextBox(0.25, 0.75, 0.75, 0.875);
        var full = OverlayPlacement.CoverSize(box, 1920, 1080, 1);
        Assert.NotNull(full);
        Assert.Equal(976.0, full.Value.Width);
        Assert.Equal(151.0, full.Value.Height);
        // 4K'da (ölçek 2) pay da iki katı.
        var large = OverlayPlacement.CoverSize(box, 3840, 2160, 2);
        Assert.NotNull(large);
        Assert.Equal(1952.0, large.Value.Width);
        Assert.Equal(302.0, large.Value.Height);
    }

    /// <summary>Kutu yoksa, boşsa ya da altyazı olamayacak kadar yüksekse kutu eskisi gibi yazı kadar kalır.</summary>
    [Theory]
    [InlineData(0.4, 0.8, 0.4, 0.9)]
    [InlineData(0.2, 0.1, 0.8, 0.9)]
    public void CoverSizeIgnoresBoxesThatAreNotASubtitle(double left, double top, double right, double bottom)
    {
        Assert.Null(OverlayPlacement.CoverSize(new CouchSubs.Core.TextBox(left, top, right, bottom), 1920, 1080, 1));
        Assert.Null(OverlayPlacement.CoverSize(null, 1920, 1080, 1));
    }

    [Fact]
    public void CoverFollowsTheEnglishLineInsideAWindow()
    {
        var source = new ScreenArea(100, 50, 1280, 720);
        var box = new CouchSubs.Core.TextBox(0.25, 0.8, 0.75, 0.9);
        var placed = OverlayPlacement.FollowEnglish(box, source, 800, 300, 1);
        Assert.NotNull(placed);
        Assert.Equal(800, placed.Width);
        Assert.Equal(340, placed.Left);
        Assert.Equal(406, placed.Top);
    }

    [Fact]
    public void CoverWidensForTheOriginalAndStaysInsideTheWindow()
    {
        var source = new ScreenArea(2000, 0, 960, 540);
        var box = new CouchSubs.Core.TextBox(0.65, 0.8, 0.95, 0.9);
        var placed = OverlayPlacement.FollowEnglish(box, source, 320, 250, 1);
        Assert.NotNull(placed);
        Assert.True(placed.Width > 320);
        Assert.True(placed.Left >= source.Left);
        Assert.True(placed.Left + placed.Width <= source.Right);
        Assert.Null(OverlayPlacement.FollowEnglish(null, source, 320, 250, 1));
    }

    [Fact]
    public void NothingSavedOpensAtBottomCenter() => AssertDefault(OverlayPlacement.Place(null, Screen, Work, Height));

    [Fact]
    public void SavedPlaceOnScreenIsKept()
    {
        var placed = OverlayPlacement.Place(new OverlayBounds(100, 400, 1000), Screen, Work, Height);
        Assert.Equal(new OverlayBounds(100, 400, 1000), placed);
    }

    [Theory]
    [InlineData(double.NaN, 400, 1000)]
    [InlineData(100, double.PositiveInfinity, 1000)]
    [InlineData(100, 400, 0)]
    [InlineData(100, 400, -50)]
    [InlineData(100, 400, double.NaN)]
    public void BrokenSaveFallsBackToDefault(double left, double top, double width) =>
        AssertDefault(OverlayPlacement.Place(new OverlayBounds(left, top, width), Screen, Work, Height));

    /// <summary>Sağdaki ikinci ekran çıkarıldı: kayıtlı yer artık hiçbir ekranda değil.</summary>
    [Theory]
    [InlineData(2100, 400)]
    [InlineData(-3000, 400)]
    [InlineData(100, 1060)]
    [InlineData(100, -480)]
    public void OffScreenSaveFallsBackToDefault(double left, double top) =>
        AssertDefault(OverlayPlacement.Place(new OverlayBounds(left, top, 1000), Screen, Work, Height));

    [Fact]
    public void SecondScreenOnTheLeftIsKept()
    {
        var both = new ScreenArea(-1920, 0, 3840, 1080);
        var placed = OverlayPlacement.Place(new OverlayBounds(-1600, 500, 1200), both, Work, Height);
        Assert.Equal(new OverlayBounds(-1600, 500, 1200), placed);
    }

    [Fact]
    public void WidthIsClampedToScreens()
    {
        Assert.Equal(1920, OverlayPlacement.Place(new OverlayBounds(0, 400, 99999), Screen, Work, Height).Width);
        Assert.Equal(OverlayPlacement.SmallestWidth, OverlayPlacement.Place(new OverlayBounds(0, 400, 10), Screen, Work, Height).Width);
    }

    /// <summary>Ekran bilgisi okunamadıysa (sıfır ya da NaN) pencere yine geçerli bir yerde ve boyda açılır.</summary>
    [Fact]
    public void UnreadableScreensStillGiveAValidPlace()
    {
        var empty = new ScreenArea(0, 0, 0, 0);
        var broken = new ScreenArea(double.NaN, 0, double.NaN, 1080);
        foreach (var placed in new[]
                 {
                     OverlayPlacement.Place(null, empty, empty, Height),
                     OverlayPlacement.Place(new OverlayBounds(100, 100, 800), broken, broken, double.NaN),
                     OverlayPlacement.Place(null, Screen, empty, 0),
                 })
        {
            Assert.True(double.IsFinite(placed.Left) && double.IsFinite(placed.Top) && double.IsFinite(placed.Width));
            Assert.True(placed.Width >= OverlayPlacement.SmallestWidth);
        }
    }

    [Fact]
    public void ClampWidthNeverThrows()
    {
        // Math.Clamp(x, 320, 200) hata verirdi (ekranlar dar okunduysa).
        Assert.Equal(OverlayPlacement.SmallestWidth, OverlayPlacement.ClampWidth(1000, 200));
        Assert.Equal(OverlayPlacement.SmallestWidth, OverlayPlacement.ClampWidth(double.NaN, 1920));
        Assert.Equal(1920, OverlayPlacement.ClampWidth(5000, 1920));
        Assert.Equal(900, OverlayPlacement.ClampWidth(900, double.NaN));
    }

    [Fact]
    public void NonFiniteBoundsAreNotSaved()
    {
        Assert.Null(OverlayPlacement.ToSave(double.NaN, 10, 800));
        Assert.Null(OverlayPlacement.ToSave(10, double.NegativeInfinity, 800));
        Assert.Null(OverlayPlacement.ToSave(10, 10, 0));
        Assert.Equal(new OverlayBounds(10, 21, 800), OverlayPlacement.ToSave(10.2, 20.6, 799.7));
    }

    /// <summary>İki ekran: solda ana (1920×1080), sağda ikinci (2560×1440) ekran.</summary>
    private static readonly DisplayArea Main = new(@"\\.\DISPLAY1", new ScreenArea(0, 0, 1920, 1080));
    private static readonly DisplayArea Second = new(@"\\.\DISPLAY2", new ScreenArea(1920, 0, 2560, 1440));
    private static readonly ScreenArea Both = new(0, 0, 4480, 1440);

    /// <summary>"Altyazıyı konumlandır" ikinci ekranda kaydedilir: ekranın adı, o ekrana göre yer ve yükseklik oranı.</summary>
    [Fact]
    public void SaveRemembersTheScreenAndHeight()
    {
        var saved = OverlayPlacement.ToSave(2120.4, 900.2, 1400, 750, 500, [Main, Second])!;
        Assert.Equal(@"\\.\DISPLAY2", saved.Screen);
        Assert.Equal(200, saved.ScreenLeft);
        Assert.Equal(900, saved.ScreenTop);
        Assert.Equal(1.5, saved.HeightScale);
        Assert.Equal(2120, saved.Left);
    }

    /// <summary>Ekranların dizilişi değişti (ikinci ekran artık solda): pencere yine ikinci ekranda, aynı yerinde açılır.</summary>
    [Fact]
    public void SavedScreenIsFollowedWhenScreensAreRearranged()
    {
        var saved = OverlayPlacement.ToSave(2120, 900, 1400, 500, 500, [Main, Second])!;
        var moved = new DisplayArea(@"\\.\DISPLAY2", new ScreenArea(-2560, 0, 2560, 1440));
        var placed = OverlayPlacement.Place(saved, new ScreenArea(-2560, 0, 4480, 1440), Work, Height, [Main, moved]);
        Assert.Equal(-2560 + 200, placed.Left);
        Assert.Equal(900, placed.Top);
        Assert.Equal(1400, placed.Width);
    }

    /// <summary>Kayıtlı ekran çıkarıldı: tüm ekranlardaki yeri de görünmüyorsa ana ekranda varsayılan yer.</summary>
    [Fact]
    public void MissingSavedScreenFallsBack()
    {
        var saved = OverlayPlacement.ToSave(2120, 900, 1400, 500, 500, [Main, Second])!;
        AssertDefault(OverlayPlacement.Place(saved, Screen, Work, Height, [Main]));
        // Ekran listesi okunamadıysa (eski davranış) tüm ekranlardaki yer kullanılır.
        Assert.Equal(2120, OverlayPlacement.Place(saved, Both, Work, Height, []).Left);
    }

    [Fact]
    public void HeightScaleIsClampedAndKept()
    {
        Assert.Equal(OverlayPlacement.SmallestHeightScale, OverlayPlacement.HeightScaleFor(10, 500));
        Assert.Equal(OverlayPlacement.LargestHeightScale, OverlayPlacement.HeightScaleFor(99999, 500));
        Assert.Equal(1, OverlayPlacement.HeightScaleFor(double.NaN, 500));
        Assert.Equal(1, OverlayPlacement.HeightScaleFor(400, 0));
        Assert.Equal(1, OverlayPlacement.ClampHeightScale(double.NaN));
        var placed = OverlayPlacement.Place(new OverlayBounds(100, 300, 1000) { HeightScale = 9 }, Screen, Work, Height);
        Assert.Equal(OverlayPlacement.LargestHeightScale, placed.HeightScale);
        // Eski kayıtta oran yok: 1.
        var old = System.Text.Json.JsonSerializer.Deserialize<OverlayBounds>("""{"Left":100,"Top":300,"Width":1000}""")!;
        Assert.Equal(1, old.HeightScale);
        Assert.Null(old.Screen);
    }

    /// <summary>Konumlandırma kaydedilmeden kapanırsa (Esc) ayar değişmez; Bitti, Enter ya da çift tık son yeri kaydeder.</summary>
    [Fact]
    public void EditIsSavedOnlyOnCommit()
    {
        var controller = AppControllerTests.Make();
        var before = controller.Settings.Overlay;
        controller.OverlayAdjusting = true;
        controller.OverlayDraft = new OverlayBounds(10, 20, 900);
        controller.CancelOverlayEdit();
        Assert.False(controller.OverlayAdjusting);
        Assert.Equal(before, controller.Settings.Overlay);

        controller.OverlayAdjusting = true;
        Assert.Null(controller.OverlayDraft);
        controller.OverlayDraft = new OverlayBounds(10, 20, 900) { Screen = @"\\.\DISPLAY1", ScreenLeft = 10, ScreenTop = 20 };
        controller.CommitOverlayEdit();
        Assert.False(controller.OverlayAdjusting);
        Assert.Equal(@"\\.\DISPLAY1", controller.Settings.Overlay?.Screen);
        Assert.Equal(900, controller.Settings.Overlay?.Width);
    }

    [Fact]
    public void HeightAndScaleStayPositive()
    {
        Assert.Equal(1, OverlayPlacement.Scale(0));
        Assert.Equal(1, OverlayPlacement.Scale(double.NaN));
        Assert.Equal(2, OverlayPlacement.Scale(2160));
        Assert.Equal(OverlayPlacement.Height(46, 1), OverlayPlacement.Height(0, 1));
        Assert.Equal(OverlayPlacement.Height(46, 1), OverlayPlacement.Height(-5, 1));
        Assert.True(OverlayPlacement.Height(36, 0.5) > 0);
    }
}
