// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;
using CouchSubs.App.Theme;
using CouchSubs.Core;

namespace CouchSubs.App.Controls;

// Mac'teki yeni arayüz bileşenlerinin (UI/Yeni/DSComponents.swift) Windows karşılıkları. Görünümleri Theme/Styles.xaml'da;
// boşluklar tasarim.json › space belirteçlerinden (Sp). Adlar Mac'tekiyle eşleşir: DSUnitStack → SpacedStack,
// DSUnit → Unit, DSSectionTitle → SectionTitle, DSCallout → Callout, DSCopyField → CopyField, DSButtonStack → SpacedStack Gap="related".

/// <summary>
/// Dikey (ya da yatay) yığın; öğeler arasına tek belirteçlik boşluk koyar (Mac VStack(spacing:)). Görünmeyen öğeler
/// boşluk almaz. Varsayılan <c>unitGap</c> (24): ayar birimleri arası. Düğme yığını için <c>Gap="related"</c> (12).
/// </summary>
public class SpacedStack : Panel
{
    public static readonly DependencyProperty GapProperty = DependencyProperty.Register(nameof(Gap), typeof(string), typeof(SpacedStack),
        new FrameworkPropertyMetadata("unitGap", FrameworkPropertyMetadataOptions.AffectsMeasure));
    public static readonly DependencyProperty OrientationProperty = DependencyProperty.Register(nameof(Orientation), typeof(Orientation), typeof(SpacedStack),
        new FrameworkPropertyMetadata(Orientation.Vertical, FrameworkPropertyMetadataOptions.AffectsMeasure));

    /// <summary>tasarim.json › space adı (unitGap, related, s, m …).</summary>
    public string Gap { get => (string)GetValue(GapProperty); set => SetValue(GapProperty, value); }
    public Orientation Orientation { get => (Orientation)GetValue(OrientationProperty); set => SetValue(OrientationProperty, value); }

    private bool Vertical => Orientation == Orientation.Vertical;

    protected override Size MeasureOverride(Size available)
    {
        var gap = Sp.V(Gap);
        double main = 0, cross = 0;
        var count = 0;
        var child = Vertical ? new Size(available.Width, double.PositiveInfinity) : new Size(double.PositiveInfinity, available.Height);
        foreach (UIElement element in InternalChildren)
        {
            element.Measure(child);
            if (element.Visibility == Visibility.Collapsed) continue;
            if (count++ > 0) main += gap;
            main += Vertical ? element.DesiredSize.Height : element.DesiredSize.Width;
            cross = Math.Max(cross, Vertical ? element.DesiredSize.Width : element.DesiredSize.Height);
        }
        return Vertical ? new Size(cross, main) : new Size(main, cross);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var gap = Sp.V(Gap);
        double offset = 0;
        var count = 0;
        foreach (UIElement element in InternalChildren)
        {
            if (element.Visibility == Visibility.Collapsed)
            {
                element.Arrange(new Rect());
                continue;
            }
            if (count++ > 0) offset += gap;
            if (Vertical)
            {
                element.Arrange(new Rect(0, offset, final.Width, element.DesiredSize.Height));
                offset += element.DesiredSize.Height;
            }
            else
            {
                element.Arrange(new Rect(offset, 0, element.DesiredSize.Width, final.Height));
                offset += element.DesiredSize.Width;
            }
        }
        return final;
    }
}

/// <summary>
/// Ayar birimi (Mac DSUnit): başlık ÜSTTE, denetim ALTTA tam genişlik, açıklama denetimin altında. Başlık → denetim
/// <c>unitTitle</c> (8), denetim → açıklama <c>unitHint</c> (6). Birimler arası SpacedStack'in <c>unitGap</c>'i (24).
/// </summary>
public class Unit : ContentControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(Unit));
    public static readonly DependencyProperty HintProperty = DependencyProperty.Register(nameof(Hint), typeof(string), typeof(Unit));
    /// <summary>Başlığın sağındaki değer (kaydırıcı: "28 px"; Mac DSSliderRow).</summary>
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(nameof(Value), typeof(string), typeof(Unit));

    static Unit() => DefaultStyleKeyProperty.OverrideMetadata(typeof(Unit), new FrameworkPropertyMetadata(typeof(Unit)));

    public string? Title { get => (string?)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string? Hint { get => (string?)GetValue(HintProperty); set => SetValue(HintProperty, value); }
    public string? Value { get => (string?)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
}

/// <summary>Bölüm başlığı ve altında açıklama (Mac DSSectionTitle): başlık → gövde <c>titleBody</c> (6).</summary>
public class SectionTitle : Control
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(SectionTitle));
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(SectionTitle));

    static SectionTitle() => DefaultStyleKeyProperty.OverrideMetadata(typeof(SectionTitle), new FrameworkPropertyMetadata(typeof(SectionTitle)));

    public string? Title { get => (string?)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string? Text { get => (string?)GetValue(TextProperty); set => SetValue(TextProperty, value); }
}

/// <summary>Uyarı kutusunun tonu: amber (önemli bilgi), kırmızı (hata/uyarı), yeşil (başarı).</summary>
public enum CalloutTone { Attention, Live, Success }

/// <summary>
/// Önemli uyarı (Mac DSCallout): gri metin değil, ince renkli kenarlı açık renkli kutu + simge; vurgu büyük harf değil kalın.
/// </summary>
public class Callout : ContentControl
{
    public static readonly DependencyProperty ToneProperty = DependencyProperty.Register(nameof(Tone), typeof(CalloutTone), typeof(Callout),
        new FrameworkPropertyMetadata(CalloutTone.Attention));
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(Callout));
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(Callout));

    static Callout() => DefaultStyleKeyProperty.OverrideMetadata(typeof(Callout), new FrameworkPropertyMetadata(typeof(Callout)));

    public CalloutTone Tone { get => (CalloutTone)GetValue(ToneProperty); set => SetValue(ToneProperty, value); }
    public string? Title { get => (string?)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string? Text { get => (string?)GetValue(TextProperty); set => SetValue(TextProperty, value); }
}

/// <summary>
/// Kopyalanabilir değer (Mac DSCopyField): tam yuvarlak 48'lik kutu, değer tek satır (sığmazsa ortadan kısaltılır),
/// kopyala simgesi kutunun İÇİNDE sağda; tıklayınca tik + "Kopyalandı". Ayrı "Kopyala" düğmesi yok.
/// </summary>
public class CopyField : Control
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(CopyField),
        new FrameworkPropertyMetadata(null, (d, _) => ((CopyField)d).UpdateShown()));
    public static readonly DependencyProperty MonoProperty = DependencyProperty.Register(nameof(Mono), typeof(bool), typeof(CopyField),
        new FrameworkPropertyMetadata(true));
    private static readonly DependencyPropertyKey ShownKey = DependencyProperty.RegisterReadOnly(nameof(Shown), typeof(string), typeof(CopyField),
        new FrameworkPropertyMetadata(""));
    public static readonly DependencyProperty ShownProperty = ShownKey.DependencyProperty;
    private static readonly DependencyPropertyKey CopiedKey = DependencyProperty.RegisterReadOnly(nameof(Copied), typeof(bool), typeof(CopyField),
        new FrameworkPropertyMetadata(false));
    public static readonly DependencyProperty CopiedProperty = CopiedKey.DependencyProperty;

    private readonly DispatcherTimer reset = new() { Interval = TimeSpan.FromSeconds(2) };

    static CopyField() => DefaultStyleKeyProperty.OverrideMetadata(typeof(CopyField), new FrameworkPropertyMetadata(typeof(CopyField)));

    public CopyField()
    {
        reset.Tick += (_, _) =>
        {
            reset.Stop();
            SetValue(CopiedKey, false);
        };
        SizeChanged += (_, _) => UpdateShown();
    }

    public string? Text { get => (string?)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public bool Mono { get => (bool)GetValue(MonoProperty); set => SetValue(MonoProperty, value); }
    /// <summary>Görünen değer: genişliğe sığmazsa ortası "…" ile kısaltılmış.</summary>
    public string Shown => (string)GetValue(ShownProperty);
    public bool Copied => (bool)GetValue(CopiedProperty);

    public override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        if (GetTemplateChild("PART_Copy") is ButtonBase copy) copy.Click += (_, _) => Copy();
        UpdateShown();
    }

    private void Copy()
    {
        if (string.IsNullOrEmpty(Text)) return;
        try
        {
            Clipboard.SetText(Text);
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            return; // Pano başka bir uygulamada kilitli; bir sonraki tıklamada yeniden denenir.
        }
        SetValue(CopiedKey, true);
        reset.Stop();
        reset.Start();
    }

    /// <summary>Ortadan kısaltma: yaklaşık karakter genişliğiyle (mono 13 px ≈ 7.8 px) sığan uzunluk hesaplanır.</summary>
    private void UpdateShown()
    {
        var text = Text ?? "";
        var room = ActualWidth - Sp.V("m") * 2 - 96; // iç boşluklar ve sağdaki simge + "Kopyalandı" alanı
        var perChar = Mono ? 7.8 : 7.2;
        var fit = room > 0 ? (int)(room / perChar) : int.MaxValue;
        if (text.Length <= fit || fit < 8)
        {
            SetValue(ShownKey, text);
            return;
        }
        var head = (fit - 1) / 2;
        var tail = fit - 1 - head;
        SetValue(ShownKey, text[..head] + "…" + text[^tail..]);
    }
}

/// <summary>"Kopyalandı" yazısı (CopyField şablonu kullanır).</summary>
public static class CopyText
{
    public static string Copied => Localizer.Current["Copied"];
}
