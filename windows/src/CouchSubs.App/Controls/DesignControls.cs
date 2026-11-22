// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using CouchSubs.App.Services;
using CouchSubs.App.Theme;
using CouchSubs.Core;

namespace CouchSubs.App.Controls;

// Yeni arayüzün ortak bileşenleri (tasarım tuvali; Mac'teki yeni arayüzle aynı adlar). Görünümleri Theme/Styles.xaml'da.

/// <summary>CouchSubs logosu: kanepe ve iki amber altyazı çubuğu (arka plansız). Çubuklar "nefes alır" (hareket azaltılmışsa durur).</summary>
public class CouchLogo : Control
{
    public static readonly DependencyProperty AnimatedProperty = DependencyProperty.Register(nameof(Animated), typeof(bool), typeof(CouchLogo),
        new FrameworkPropertyMetadata(true));

    static CouchLogo() => DefaultStyleKeyProperty.OverrideMetadata(typeof(CouchLogo), new FrameworkPropertyMetadata(typeof(CouchLogo)));

    public bool Animated { get => (bool)GetValue(AnimatedProperty); set => SetValue(AnimatedProperty, value); }
}

/// <summary>Başlık çubuğunun sağındaki durum hapı: renkli nokta ve kısa durum ("Çeviri Açık", "Hazır").</summary>
public class StatusPill : Control
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(StatusPill));
    public static readonly DependencyProperty ToneProperty = DependencyProperty.Register(nameof(Tone), typeof(PillTone), typeof(StatusPill),
        new FrameworkPropertyMetadata(PillTone.Idle));

    static StatusPill() => DefaultStyleKeyProperty.OverrideMetadata(typeof(StatusPill), new FrameworkPropertyMetadata(typeof(StatusPill)));

    public string? Text { get => (string?)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public PillTone Tone { get => (PillTone)GetValue(ToneProperty); set => SetValue(ToneProperty, value); }
}

/// <summary>Durum hapının ve rozetin tonu: boşta (gri), başarı (yeşil), canlı/uyarı (kırmızı), dikkat (amber).</summary>
public enum PillTone { Idle, Success, Live, Attention }

/// <summary>Küçük rozet (24 yüksek, tam yuvarlak): Açık / Kapalı / Bilinmiyor gibi denetim sonuçları.</summary>
public class Badge : ContentControl
{
    public static readonly DependencyProperty ToneProperty = DependencyProperty.Register(nameof(Tone), typeof(PillTone), typeof(Badge),
        new FrameworkPropertyMetadata(PillTone.Idle));

    static Badge() => DefaultStyleKeyProperty.OverrideMetadata(typeof(Badge), new FrameworkPropertyMetadata(typeof(Badge)));

    public PillTone Tone { get => (PillTone)GetValue(ToneProperty); set => SetValue(ToneProperty, value); }
}

/// <summary>
/// Anahtar satırı: anahtar satırın başında, sağında başlık ve noktalı açıklama; altta ince çizgi (son satırda
/// <see cref="Divider"/> kapatılır). Anahtar açıkken amber.
/// </summary>
public class SwitchRow : CheckBox
{
    public static readonly DependencyProperty DescriptionProperty = DependencyProperty.Register(nameof(Description), typeof(string), typeof(SwitchRow));
    public static readonly DependencyProperty DividerProperty = DependencyProperty.Register(nameof(Divider), typeof(bool), typeof(SwitchRow),
        new FrameworkPropertyMetadata(true));

    static SwitchRow() => DefaultStyleKeyProperty.OverrideMetadata(typeof(SwitchRow), new FrameworkPropertyMetadata(typeof(SwitchRow)));

    public string? Description { get => (string?)GetValue(DescriptionProperty); set => SetValue(DescriptionProperty, value); }
    public bool Divider { get => (bool)GetValue(DividerProperty); set => SetValue(DividerProperty, value); }
}

/// <summary>Seçenek kartı (çeviri motoru gibi): solda halka, başlık ve açıklama; seçiliyken 2 px amber çerçeve.</summary>
public class OptionCard : RadioButton
{
    public static readonly DependencyProperty DescriptionProperty = DependencyProperty.Register(nameof(Description), typeof(string), typeof(OptionCard));

    static OptionCard() => DefaultStyleKeyProperty.OverrideMetadata(typeof(OptionCard), new FrameworkPropertyMetadata(typeof(OptionCard)));

    public string? Description { get => (string?)GetValue(DescriptionProperty); set => SetValue(DescriptionProperty, value); }
}

/// <summary>Ayarlar kenar çubuğu satırı: başlık ve altında küçük ipucu ("Çeviri, Ses"); seçiliyken ikinci yüzey.</summary>
public class NavItem : RadioButton
{
    public static readonly DependencyProperty HintProperty = DependencyProperty.Register(nameof(Hint), typeof(string), typeof(NavItem));
    /// <summary>Segoe Fluent Icons simgesi (Mac'teki SF Symbol karşılığı).</summary>
    public static readonly DependencyProperty IconProperty = DependencyProperty.Register(nameof(Icon), typeof(string), typeof(NavItem));
    /// <summary>Simge karesinin tonu (tasarim.json: amber, peach, olive, teal, plum, sky, live).</summary>
    public static readonly DependencyProperty TintProperty = DependencyProperty.Register(nameof(Tint), typeof(Brush), typeof(NavItem));

    static NavItem() => DefaultStyleKeyProperty.OverrideMetadata(typeof(NavItem), new FrameworkPropertyMetadata(typeof(NavItem)));

    public string? Hint { get => (string?)GetValue(HintProperty); set => SetValue(HintProperty, value); }
    public string? Icon { get => (string?)GetValue(IconProperty); set => SetValue(IconProperty, value); }
    public Brush? Tint { get => (Brush?)GetValue(TintProperty); set => SetValue(TintProperty, value); }
}

/// <summary>Renk seçimi noktası (32 ya da 24 px daire); seçiliyken amber halka.</summary>
public class ColorSwatch : RadioButton
{
    public static readonly DependencyProperty SwatchProperty = DependencyProperty.Register(nameof(Swatch), typeof(Brush), typeof(ColorSwatch));
    public static readonly DependencyProperty DiameterProperty = DependencyProperty.Register(nameof(Diameter), typeof(double), typeof(ColorSwatch),
        new FrameworkPropertyMetadata(32.0));

    static ColorSwatch() => DefaultStyleKeyProperty.OverrideMetadata(typeof(ColorSwatch), new FrameworkPropertyMetadata(typeof(ColorSwatch)));

    public Brush? Swatch { get => (Brush?)GetValue(SwatchProperty); set => SetValue(SwatchProperty, value); }
    public double Diameter { get => (double)GetValue(DiameterProperty); set => SetValue(DiameterProperty, value); }
}

/// <summary>Kart içi bölüm etiketi metni büyük harfe çevrilir (Türkçede i → İ).</summary>
public sealed class UpperCase : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is string text ? text.ToUpper(Localizer.Current.Language == "tr" ? new CultureInfo("tr-TR") : CultureInfo.InvariantCulture) : value;

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Reklam bandının bir reklamı (kendi uygulamalarımız; üçüncü taraf ağı ve izleme yok).</summary>
public sealed record BannerAd(string Id, string Title, string Text, ImageSource? Icon, string? AppStore, string? GooglePlay)
{
    /// <summary>Bağlantı yoksa mağaza düğmesi pasif ve "Yakında" yazar (Cebbin Google Play).</summary>
    public bool HasAppStore => AppStore is not null;
    public bool HasGooglePlay => GooglePlay is not null;
}

/// <summary>
/// Uygulama ve ayar sayfalarının altındaki 64 px reklam bandı: REKLAM etiketi, reklamlar 6 sn arayla sırayla döner,
/// sağda İncele düğmesi. Reklam yoksa bant görünmez. Kurulum, açılış ve oyun görüntüsü sayfalarında kullanılmaz.
/// </summary>
public class AdBand : Control
{
    public static readonly TimeSpan Interval = TimeSpan.FromMilliseconds(Palette.MotionMs("adRotate", 6000));

    public static readonly DependencyProperty CurrentProperty = DependencyProperty.Register(nameof(Current), typeof(BannerAd), typeof(AdBand));

    private readonly DispatcherTimer timer = new() { Interval = Interval };
    private IReadOnlyList<BannerAd> ads = [];
    private int index;

    static AdBand() => DefaultStyleKeyProperty.OverrideMetadata(typeof(AdBand), new FrameworkPropertyMetadata(typeof(AdBand)));

    public AdBand()
    {
        timer.Tick += (_, _) => Advance();
        Loaded += (_, _) => Refresh();
        Unloaded += (_, _) => timer.Stop();
        AdCatalog.Changed += () => Dispatcher.BeginInvoke(Refresh);
    }

    public BannerAd? Current { get => (BannerAd?)GetValue(CurrentProperty); private set => SetValue(CurrentProperty, value); }

    private void Refresh()
    {
        ads = AdCatalog.Banners;
        index = 0;
        Visibility = ads.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        Current = ads.Count == 0 ? null : ads[0];
        timer.Stop();
        if (ads.Count > 1 && IsLoaded) timer.Start();
    }

    private void Advance()
    {
        if (ads.Count < 2) return;
        index = (index + 1) % ads.Count;
        var next = ads[index];
        if (GetTemplateChild("PART_Slide") is not FrameworkElement slide || Motion.Reduced)
        {
            Current = next;
            return;
        }
        // Eski reklam yukarı kayarak söner, yenisi aşağıdan gelir (tasarım: adcyc).
        var move = new TranslateTransform();
        slide.RenderTransform = move;
        var fadeOut = Motion.To(0, Motion.Page, exit: true);
        fadeOut.Completed += (_, _) =>
        {
            Current = next;
            Motion.EnterFrom(slide, 8);
        };
        slide.BeginAnimation(OpacityProperty, fadeOut);
        move.BeginAnimation(TranslateTransform.YProperty, Motion.To(-8, Motion.Page, exit: true));
    }

    public override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        if (GetTemplateChild("PART_AppStore") is ButtonBase appStore) appStore.Click += (_, _) => Open(Current?.AppStore);
        if (GetTemplateChild("PART_GooglePlay") is ButtonBase googlePlay) googlePlay.Click += (_, _) => Open(Current?.GooglePlay);
    }

    private static void Open(string? link)
    {
        if (link is not null && Uri.TryCreate(link, UriKind.Absolute, out var url)) BrowserLauncher.Open(url);
    }
}

/// <summary>Görsel ağaçta yukarı doğru arama.</summary>
public static class VisualTree
{
    public static T? FindAncestor<T>(this DependencyObject element) where T : DependencyObject
    {
        for (var current = VisualTreeHelper.GetParent(element); current is not null; current = VisualTreeHelper.GetParent(current))
            if (current is T match) return match;
        return null;
    }
}
