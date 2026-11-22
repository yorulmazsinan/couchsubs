// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using CouchSubs.App.Theme;

namespace CouchSubs.App.Controls;

/// <summary>
/// Ayarlar menü kartının arkasındaki yavaş renk geçişi (Mac SettingsNavGlow): üç yumuşak radyal amber / şeftali / zeytin
/// leke 24 sn'lik döngüde dolaşır. Düşük maliyet: bulanıklık süzgeci yok, dondurulmuş üç radyal fırça yalnız konumla
/// çizilir; en çok 15 kare/sn (DispatcherTimer). Pencere önde değilken, çeviri sürerken (<see cref="Paused"/>), hareket
/// azaltılmışken ya da Ayarlar › Geçiş Animasyonları kapalıyken (Motion.Reduced) durur ve durağan kare kalır.
/// Kartın köşe yarıçapına (radius.card) kırpılır.
/// </summary>
public sealed class NavGlow : FrameworkElement
{
    public const double Period = 24;
    public const double Fps = 15;

    /// <summary>Dışarıdan durdurma (çeviri sürerken).</summary>
    public static readonly DependencyProperty PausedProperty = DependencyProperty.Register(nameof(Paused), typeof(bool), typeof(NavGlow),
        new FrameworkPropertyMetadata(false, (d, _) => ((NavGlow)d).Update()));

    private readonly DispatcherTimer timer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(1 / Fps) };
    private readonly DateTime start = DateTime.UtcNow;
    private Brush[] brushes = [];
    private Window? window;
    private double time;

    public NavGlow()
    {
        IsHitTestVisible = false;
        Focusable = false;
        timer.Tick += (_, _) =>
        {
            time = (DateTime.UtcNow - start).TotalSeconds;
            InvalidateVisual();
        };
        Loaded += (_, _) =>
        {
            window = Window.GetWindow(this);
            if (window is not null)
            {
                window.Activated += OnWindowChanged;
                window.Deactivated += OnWindowChanged;
            }
            ThemeManager.Changed += OnTheme;
            Motion.ReducedChanged += Update;
            MakeBrushes();
            Update();
        };
        Unloaded += (_, _) =>
        {
            timer.Stop();
            if (window is not null)
            {
                window.Activated -= OnWindowChanged;
                window.Deactivated -= OnWindowChanged;
            }
            ThemeManager.Changed -= OnTheme;
            Motion.ReducedChanged -= Update;
        };
    }

    public bool Paused { get => (bool)GetValue(PausedProperty); set => SetValue(PausedProperty, value); }

    /// <summary>Şu an oynuyor mu (testler ve tanı için).</summary>
    public bool Running => timer.IsEnabled;

    private void OnWindowChanged(object? sender, EventArgs e) => Update();

    private void OnTheme()
    {
        MakeBrushes();
        InvalidateVisual();
    }

    private void Update()
    {
        var run = IsLoaded && !Paused && !Motion.Reduced && window is { IsActive: true };
        if (run && !timer.IsEnabled) timer.Start();
        else if (!run && timer.IsEnabled) timer.Stop();
    }

    private void MakeBrushes()
    {
        Brush Make(string name)
        {
            var color = TryFindResource(name + "Color") is Color found ? found : Colors.Transparent;
            var brush = new RadialGradientBrush(Color.FromArgb(41, color.R, color.G, color.B), Color.FromArgb(0, color.R, color.G, color.B));
            brush.Freeze();
            return brush;
        }
        brushes = [Make("amber"), Make("peach"), Make("olive")];
    }

    private static readonly (double X, double Y, double Scale, double Offset)[] Blobs =
    [
        (0.25, 0.18, 0.9, 0), (0.8, 0.55, 0.8, 2.1), (0.3, 0.88, 0.75, 4.2),
    ];

    protected override void OnRender(DrawingContext context)
    {
        var size = RenderSize;
        if (size.Width <= 0 || size.Height <= 0 || brushes.Length < Blobs.Length) return;
        var radius = TryFindResource("radius.card") is CornerRadius corner ? corner.TopLeft : 24;
        context.PushClip(new RectangleGeometry(new Rect(size), radius, radius));
        var phase = time % Period / Period * 2 * Math.PI;
        for (var i = 0; i < Blobs.Length; i++)
        {
            var (x, y, scale, offset) = Blobs[i];
            var r = Math.Max(size.Width, 220) * scale;
            var center = new Point(size.Width * (x + 0.18 * Math.Sin(phase + offset)), size.Height * (y + 0.08 * Math.Cos(phase + offset * 0.7)));
            context.DrawEllipse(brushes[i], null, center, r, r);
        }
        context.Pop();
    }
}
