// SPDX-License-Identifier: AGPL-3.0-only

using System.IO;
using System.Media;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using CouchSubs.App.Services;
using CouchSubs.App.Theme;
using CouchSubs.Core;

namespace CouchSubs.App.Views;

/// <summary>
/// Açılış (tuval 00): yalnız ilk kurulumun karşılama adımında. Koyu zeminde kanepe parçaları sırayla yükselir (arkalık
/// 80 ms, oturak 300 ms), parıltı 650 ms, altyazı çubukları 780 / 920 ms'de soldan açılır, "CouchSubs" 1150 ms,
/// "by Enmera" 1500 ms, "Hadi Başlayalım" 2300 ms. Açılış sesi (Ayarlar › Temel › Açılış Sesi açıksa) 2–3 sn çalar.
/// Atlanabilir; sesli ya da sessiz yeniden oynatılabilir. Hareket azaltılmışsa yalnız solma.
/// </summary>
public sealed class IntroView : UserControl
{
    private readonly Action done;
    private readonly Canvas logo = new() { Width = 640, Height = 494 };
    private readonly Rectangle back = Part(90, 40, 460, 320, 52, Color.FromRgb(0x43, 0x46, 0x4F));
    private readonly Rectangle bar1 = Part(175, 112, 290, 50, 25, Color.FromRgb(0xF5, 0xB8, 0x3D));
    private readonly Rectangle bar2 = Part(222, 186, 196, 50, 25, Color.FromRgb(0xF5, 0xB8, 0x3D));
    private readonly Canvas seat = new() { Width = 640, Height = 494 };
    private readonly Ellipse glow = new() { Width = 520, Height = 300 };
    private readonly TextBlock word = new() { Text = "CouchSubs", FontSize = 34, FontWeight = FontWeights.Bold, Foreground = Light, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel by = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel cta = new() { HorizontalAlignment = HorizontalAlignment.Center, Margin = Sp.T("0", "m", "0", "0") };

    private static readonly Brush Light = Frozen(Color.FromRgb(0xF3, 0xEE, 0xE4));
    private static readonly Brush Faint = Frozen(Color.FromRgb(0x8D, 0x88, 0x7F));

    public IntroView(Action done, bool startupSound = true)
    {
        this.done = done;
        Background = Frozen(Color.FromRgb(0x12, 0x13, 0x16));
        glow.Fill = new RadialGradientBrush(Color.FromArgb(0x66, 0xF5, 0xB8, 0x3D), Color.FromArgb(0, 0xF5, 0xB8, 0x3D));
        Canvas.SetLeft(glow, 60);
        Canvas.SetTop(glow, 60);
        logo.Children.Add(glow);
        logo.Children.Add(back);
        logo.Children.Add(bar1);
        logo.Children.Add(bar2);
        foreach (var (x, y, w, h, r) in new[] { (70.0, 440.0, 40.0, 44.0, 12.0), (530, 440, 40, 44, 12), (10, 196, 112, 254, 56), (518, 196, 112, 254, 56), (10, 324, 620, 126, 56) })
            seat.Children.Add(Part(x, y, w, h, r, Color.FromRgb(0xF3, 0xEE, 0xE4)));
        logo.Children.Add(seat);

        by.Children.Add(new TextBlock { Text = Localizer.Current["by"], FontFamily = (FontFamily)Application.Current.FindResource("MonoFont"), FontSize = 11, Foreground = Faint, VerticalAlignment = VerticalAlignment.Center });
        by.Children.Add(new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Assets/enmera-white.png")), Height = 11, Opacity = 0.75, Margin = Sp.T("xs", "0", "0", "0") });

        var start = new Button { Content = Localizer.Current["Let's Get Started"], HorizontalAlignment = HorizontalAlignment.Center };
        start.SetResourceReference(StyleProperty, "WidePrimaryButton");
        start.Click += (_, _) => done();
        cta.Children.Add(start);
        cta.Children.Add(new TextBlock { Text = Localizer.Current["Setup takes about 3 minutes."], FontSize = 13, Foreground = Faint, HorizontalAlignment = HorizontalAlignment.Center, Margin = Sp.T("0", "s", "0", "0") });

        var center = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        center.Children.Add(new Viewbox { Width = 240, Height = 185, Child = logo });
        word.Margin = Sp.T("0", "l", "0", "0");
        center.Children.Add(word);
        by.Margin = Sp.T("0", "l", "0", "0");
        center.Children.Add(by);
        center.Children.Add(cta);

        var replay = Ghost(Localizer.Current["Replay with Sound"], () => Play(sound: true));
        var silent = Ghost(Localizer.Current["Replay Silently"], () => Play(sound: false));
        silent.Margin = Sp.T("xs", "0", "0", "0");
        var left = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Margin = Sp.T("l") };
        left.Children.Add(replay);
        left.Children.Add(silent);
        var skip = Ghost(Localizer.Current["Skip Intro"], done);
        skip.HorizontalAlignment = HorizontalAlignment.Right;
        skip.VerticalAlignment = VerticalAlignment.Bottom;
        skip.Margin = Sp.T("l");

        var root = new Grid();
        root.Children.Add(center);
        root.Children.Add(left);
        root.Children.Add(skip);
        Content = root;
        Loaded += (_, _) => Play(sound: startupSound);
        Unloaded += (_, _) => player?.Stop();
    }

    private static Rectangle Part(double x, double y, double w, double h, double r, Color color)
    {
        var rect = new Rectangle { Width = w, Height = h, RadiusX = r, RadiusY = r, Fill = Frozen(color) };
        Canvas.SetLeft(rect, x);
        Canvas.SetTop(rect, y);
        return rect;
    }

    private static SolidColorBrush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private static Button Ghost(string text, Action click)
    {
        var button = new Button { Content = text, Height = 40, MinHeight = 40, Padding = Sp.T("m", "0", "m", "0"), FontSize = 13, Foreground = Frozen(Color.FromRgb(0xBD, 0xB8, 0xAE)),
            Background = Frozen(Color.FromRgb(0x1C, 0x1D, 0x21)), BorderBrush = Frozen(Color.FromRgb(0x33, 0x35, 0x3C)), BorderThickness = new Thickness(1) };
        button.SetResourceReference(StyleProperty, "ButtonBase");
        button.Click += (_, _) => click();
        return button;
    }

    private SoundPlayer? player;

    /// <summary>Animasyonu baştan oynatır; <paramref name="sound"/> ise açılış sesi de çalar.</summary>
    private void Play(bool sound)
    {
        player?.Stop();
        if (sound)
        {
            try
            {
                player = new SoundPlayer(new MemoryStream(Chime()));
                player.Play();
            }
            catch (Exception error) when (error is InvalidOperationException or IOException) { }
        }
        Rise(back, 80, 520, 18, 0.96);
        Rise(seat, 300, 560, 26, 1);
        Fade(glow, 650, 900, 0.35);
        Grow(bar1, 780, 0);
        Grow(bar2, 920, 0.2);
        Rise(word, 1150, 500, 10, 1);
        Fade(by, 1500, 500, 1);
        Rise(cta, 2300, 400, 10, 1);
    }

    private static void Fade(UIElement element, int delayMs, int durationMs, double to)
    {
        var reduced = Motion.Reduced;
        element.BeginAnimation(OpacityProperty, new DoubleAnimation(0, to, TimeSpan.FromMilliseconds(reduced ? 100 : durationMs))
        {
            BeginTime = TimeSpan.FromMilliseconds(reduced ? 0 : delayMs), FillBehavior = FillBehavior.HoldEnd,
        });
    }

    private static void Rise(FrameworkElement element, int delayMs, int durationMs, double offset, double scale)
    {
        element.Opacity = 0;
        Fade(element, delayMs, durationMs, 1);
        if (Motion.Reduced) return;
        var move = new TranslateTransform(0, offset);
        var size = new ScaleTransform(scale, scale);
        element.RenderTransformOrigin = new Point(0.5, 0.5);
        element.RenderTransform = new TransformGroup { Children = { size, move } };
        var begin = TimeSpan.FromMilliseconds(delayMs);
        var duration = TimeSpan.FromMilliseconds(durationMs);
        move.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(offset, 0, duration) { BeginTime = begin, EasingFunction = Motion.Enter });
        if (scale != 1)
        {
            size.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(scale, 1, duration) { BeginTime = begin, EasingFunction = Motion.Enter });
            size.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(scale, 1, duration) { BeginTime = begin, EasingFunction = Motion.Enter });
        }
    }

    /// <summary>Altyazı çubuğu soldan açılır (380 ms), sonra nefes alır.</summary>
    private static void Grow(FrameworkElement bar, int delayMs, double breatheDelay)
    {
        var scale = new ScaleTransform(Motion.Reduced ? 1 : 0, 1);
        bar.RenderTransformOrigin = new Point(0, 0.5);
        bar.RenderTransform = scale;
        if (Motion.Reduced) return;
        var open = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(380)) { BeginTime = TimeSpan.FromMilliseconds(delayMs), EasingFunction = Motion.Enter };
        open.Completed += (_, _) =>
        {
            bar.RenderTransformOrigin = new Point(0.5, 0.5);
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, 0.62, TimeSpan.FromSeconds(0.8))
            {
                AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = Motion.InOut, BeginTime = TimeSpan.FromSeconds(breatheDelay),
            });
        };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, open);
    }

    /// <summary>
    /// Açılış sesi (2,4 sn): uygulamanın içinde üretilen yumuşak üç notalı akor (dosya ve lisans gerekmez). 22 kHz, 16 bit tek kanal WAV.
    /// </summary>
    private static byte[] Chime()
    {
        const int rate = 22050;
        const double seconds = 2.4;
        var samples = (int)(rate * seconds);
        var notes = new[] { (Hz: 523.25, At: 0.0), (Hz: 659.25, At: 0.18), (Hz: 783.99, At: 0.36), (Hz: 1046.5, At: 0.78) };
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8);
        writer.Write(36 + samples * 2);
        writer.Write("WAVEfmt "u8);
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(rate);
        writer.Write(rate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write("data"u8);
        writer.Write(samples * 2);
        for (var i = 0; i < samples; i++)
        {
            var t = (double)i / rate;
            var value = 0.0;
            foreach (var (hz, at) in notes)
            {
                if (t < at) continue;
                var local = t - at;
                var envelope = Math.Min(1, local / 0.02) * Math.Exp(-local * 2.2);
                value += envelope * (Math.Sin(2 * Math.PI * hz * local) + 0.3 * Math.Sin(4 * Math.PI * hz * local));
            }
            var fadeOut = Math.Min(1, (seconds - t) / 0.3);
            writer.Write((short)Math.Clamp(value * fadeOut * 5200, short.MinValue, short.MaxValue));
        }
        writer.Flush();
        return stream.ToArray();
    }
}
