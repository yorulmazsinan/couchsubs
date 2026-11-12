// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>
/// Bilgisayar ekranındaki altyazı penceresi (Mac: SubtitleOverlay.swift): kenarsız, her pencerenin üstünde, saydam
/// zeminli; görev çubuğunda görünmez, odağı almaz. "Tıklamalar geçsin" açıkken fare alttaki pencereye (oyun, PS Remote
/// Play) gider. Satırlar TV'ye gidenlerin aynısıdır ve TV uygulamasıyla aynı yığınla (<see cref="SubtitleStack"/>)
/// gösterilir. Yeri ve genişliği ayarlara kaydedilir; altyazı yokken gizlenir.
/// </summary>
public sealed partial class SubtitleOverlayWindow : Window
{
    private const int GwlExStyle = -20;
    private const long WsExTransparent = 0x20;
    private const long WsExToolWindow = 0x80;
    private const long WsExNoActivate = 0x08000000;

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static partial IntPtr GetWindowLongPtr(IntPtr window, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static partial IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);

    private readonly AppController controller;
    private readonly SubtitleStack stack = new();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly DispatcherTimer timer = new();
    private readonly StackPanel linesPanel = new() { VerticalAlignment = VerticalAlignment.Bottom };
    /// <summary>Görünen satırların kutuları; solan satırın animasyonu yeniden çizimde baştan başlamasın.</summary>
    private readonly Dictionary<int, Border> boxes = [];
    private readonly Grid adjustLayer = new() { Visibility = Visibility.Collapsed };
    private IntPtr handle;
    /// <summary>Pencere bir kez açılamadı ya da çizilemedi: bu oturumda bir daha denenmez, çeviri pencere olmadan sürer.</summary>
    private bool broken;

    private double Now => clock.Elapsed.TotalSeconds;

    /// <summary>Yazı boyu TV'deki gibi 1080 satırlık ekrana göredir.</summary>
    private static double Scale => OverlayPlacement.Scale(SystemParameters.PrimaryScreenHeight);

    public static SubtitleOverlayWindow Attach(AppController controller) => new(controller);

    private SubtitleOverlayWindow(AppController controller)
    {
        this.controller = controller;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        Title = "CouchSubs";

        var root = new Grid();
        root.Children.Add(adjustLayer);
        root.Children.Add(new Border { Padding = new Thickness(24 * Scale, 0, 24 * Scale, 8 * Scale), Child = linesPanel });
        BuildAdjustLayer();
        Content = root;
        PlaceFromSettings();

        timer.Tick += (_, _) => Guard("zamanlayıcı", () =>
        {
            timer.Stop();
            Refresh();
        });
        SourceInitialized += (_, _) => Guard("pencere tutamağı", () =>
        {
            handle = new WindowInteropHelper(this).Handle;
            if (handle == IntPtr.Zero) return;
            var style = (long)GetWindowLongPtr(handle, GwlExStyle);
            // Odağı almaz ve Alt+Tab listesinde görünmez.
            SetWindowLongPtr(handle, GwlExStyle, (IntPtr)(style | WsExNoActivate | WsExToolWindow));
            ApplyClickThrough();
        });
        // Tıklamalar geçmiyorsa pencere her yerinden sürüklenir.
        MouseLeftButtonDown += (_, e) => Guard("sürükleme", () =>
        {
            if (e.OriginalSource is Thumb or ButtonBase || e.ButtonState != MouseButtonState.Pressed) return;
            try { DragMove(); }
            catch (InvalidOperationException) { return; /* düğme bu arada bırakıldı */ }
            SaveBounds();
        });
        controller.OverlayEvent += OnEvent;
        controller.OverlayHidden += OnHidden;
        controller.PropertyChanged += OnChanged;
    }

    public void Detach()
    {
        controller.OverlayEvent -= OnEvent;
        controller.OverlayHidden -= OnHidden;
        controller.PropertyChanged -= OnChanged;
        timer.Stop();
        try { Close(); }
        catch (InvalidOperationException error) { StartupGuard.Log("Altyazı penceresi kapatılamadı", error); }
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not (nameof(AppController.Settings) or nameof(AppController.OverlayAdjusting))) return;
        Guard("ayar değişikliği", () =>
        {
            // Yazı boyu, rengi ya da zemini değişmiş olabilir; kutular yeniden kurulur.
            if (e.PropertyName == nameof(AppController.Settings)) boxes.Clear();
            ApplyClickThrough();
            FitHeight();
            Refresh();
        });
    }

    private void OnEvent(SubtitleEvent e) => Guard("altyazı", () =>
    {
        if (e.Kind == SubtitleEventKind.Subtitle) stack.Show(e.Text, e.DurationMs, e.Paragraphs, Now, e.Replaces);
        else stack.Clear(Now);
        Refresh();
    });

    private void OnHidden() => Guard("gizleme", () =>
    {
        stack.Hide();
        Refresh();
    });

    /// <summary>
    /// Penceredeki her iş bundan geçer. Pencere açılamaz ya da çizilemezse hata hata.log'a yazılır, kullanıcıya bir kez
    /// söylenir ve pencere kapatılır; uygulama kapanmaz, çeviri (TV'ye, OBS'ye, dublaja) sürer.
    /// </summary>
    private void Guard(string where, Action action)
    {
        if (broken) return;
        try
        {
            action();
        }
        catch (Exception error)
        {
            broken = true;
            StartupGuard.Log($"Altyazı penceresi ({where})", error);
            try
            {
                timer.Stop();
                if (IsVisible) Hide();
            }
            catch (Exception hideError)
            {
                StartupGuard.Log("Altyazı penceresi gizlenemedi", hideError);
            }
            StartupGuard.Show(Application.Current, StartupGuard.OverlayFailedMessage(error));
        }
    }

    /// <summary>Görünen satırları çizer, pencereyi gösterir ya da gizler, bir sonraki değişime zamanlayıcı kurar.</summary>
    private void Refresh()
    {
        var now = Now;
        var lines = stack.Lines(now).ToList();
        var adjusting = controller.OverlayAdjusting;
        if (lines.Count == 0 && adjusting)
            lines.Add(new SubtitleStack.Line(0, Localizer.Current["Subtitles appear here."], SubtitleStack.Role.Current, false, false));
        adjustLayer.Visibility = adjusting ? Visibility.Visible : Visibility.Collapsed;

        linesPanel.Children.Clear();
        foreach (var id in boxes.Keys.Except(lines.Select(l => l.Id)).ToList()) boxes.Remove(id);
        foreach (var line in lines)
        {
            if (!boxes.TryGetValue(line.Id, out var box))
            {
                box = MakeBox(line);
                boxes[line.Id] = box;
            }
            if (line.Fading && box.Tag is not "fading")
            {
                box.Tag = "fading";
                box.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(SubtitleStack.PreviousFade)));
            }
            linesPanel.Children.Add(box);
        }

        var visible = controller.ShowsOnComputer && lines.Count > 0;
        if (visible && !IsVisible) Show();
        else if (!visible && IsVisible) Hide();

        timer.Stop();
        if (stack.NextChange(now) is { } next)
        {
            timer.Interval = TimeSpan.FromSeconds(Math.Max(0.01, next - now));
            timer.Start();
        }
    }

    /// <summary>TV'deki altyazı kutusunun aynısı: siyah yarı saydam zemin, beyaz ya da sarı yarı kalın yazı, üst satırlar soluk.</summary>
    private Border MakeBox(SubtitleStack.Line line)
    {
        var style = controller.Settings.Style;
        var scale = Scale;
        var current = line.Role == SubtitleStack.Role.Current;
        // Satır yüksekliği sıfır olursa WPF hata verir; boy en az 1.
        var size = Math.Max(1, OverlayPlacement.FontSize(style.FontSize) * scale * (current ? 1 : 0.8));
        var alpha = Math.Clamp(style.Background, 0, 100) / 100.0 * (current ? 1 : 0.83);
        var text = new TextBlock
        {
            Text = line.Text,
            FontSize = size,
            FontWeight = style.Bold ? FontWeights.Bold : FontWeights.SemiBold,
            Foreground = style.TextColor == SubtitleTextColor.Yellow ? new SolidColorBrush(Color.FromRgb(0xFF, 0xE1, 0x35)) : Brushes.White,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = line.Paragraphs ? TextAlignment.Left : TextAlignment.Center,
            LineHeight = size * 1.3,
            Effect = new DropShadowEffect { Color = Colors.Black, ShadowDepth = 2 * scale, BlurRadius = 4 * scale, Opacity = 1, Direction = 270 },
        };
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round(alpha * 255), 0, 0, 0)),
            CornerRadius = new CornerRadius(10 * scale),
            Padding = current ? new Thickness(26 * scale, 10 * scale, 26 * scale, 10 * scale) : new Thickness(20 * scale, 6 * scale, 20 * scale, 6 * scale),
            Margin = new Thickness(0, 14 * scale, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            Opacity = line.Role switch { SubtitleStack.Role.Current => 1, SubtitleStack.Role.Previous => 0.6, _ => 0.45 },
            Child = text,
        };
    }

    /// <summary>Yeri ayarlanırken: kesik çizgili çerçeve, açıklama, "Bitti" ve iki yandan genişletme tutamakları.</summary>
    private void BuildAdjustLayer()
    {
        var accent = Application.Current?.TryFindResource("accentBrush") as Brush ?? new SolidColorBrush(Color.FromRgb(0xFF, 0xC8, 0x3D));
        adjustLayer.Children.Add(new Rectangle
        {
            Fill = new SolidColorBrush(Color.FromArgb(0x59, 0, 0, 0)),
            Stroke = accent,
            StrokeThickness = 2,
            StrokeDashArray = [4, 3],
            RadiusX = 14,
            RadiusY = 14,
        });
        var done = new Button { Content = Localizer.Current["Done"], Margin = new Thickness(12, 0, 0, 0) };
        if (Application.Current?.TryFindResource("PrimaryButton") is Style primary) done.Style = primary;
        done.Click += (_, _) => Guard("Bitti", () => controller.OverlayAdjusting = false);
        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(12) };
        bar.Children.Add(new TextBlock
        {
            Text = Localizer.Current["Drag to move, drag the edges to resize."],
            Foreground = Brushes.White,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        bar.Children.Add(done);
        adjustLayer.Children.Add(bar);
        adjustLayer.Children.Add(MakeHandle(HorizontalAlignment.Left, accent));
        adjustLayer.Children.Add(MakeHandle(HorizontalAlignment.Right, accent));
    }

    /// <summary>Kenardan genişletme: ortası yerinde kalır, iki yana eşit büyür.</summary>
    private Thumb MakeHandle(HorizontalAlignment side, Brush accent)
    {
        var face = new FrameworkElementFactory(typeof(Border));
        face.SetValue(Border.BackgroundProperty, accent);
        face.SetValue(Border.CornerRadiusProperty, new CornerRadius(3));
        var thumb = new Thumb
        {
            Width = 6,
            Height = 48,
            Margin = new Thickness(6, 0, 6, 0),
            HorizontalAlignment = side,
            VerticalAlignment = VerticalAlignment.Center,
            Cursor = Cursors.SizeWE,
            Template = new ControlTemplate(typeof(Thumb)) { VisualTree = face },
        };
        thumb.DragDelta += (_, e) => Guard("genişletme", () =>
        {
            var grow = side == HorizontalAlignment.Right ? e.HorizontalChange : -e.HorizontalChange;
            var center = Left + Width / 2;
            if (!double.IsFinite(center)) return;
            // Math.Clamp en büyük değer en küçükten küçükse hata verir; sınırlar OverlayPlacement'ta güvenle hesaplanır.
            var width = OverlayPlacement.ClampWidth(Width + 2 * grow, SystemParameters.VirtualScreenWidth);
            Width = width;
            Left = center - width / 2;
        });
        thumb.DragCompleted += (_, _) => Guard("genişletme", SaveBounds);
        return thumb;
    }

    /// <summary>"Tıklamalar geçsin" açıksa (ve yeri ayarlanmıyorsa) fare pencereden geçer.</summary>
    private void ApplyClickThrough()
    {
        if (handle == IntPtr.Zero) return;
        var through = controller.Settings.OverlayClickThrough && !controller.OverlayAdjusting;
        var style = (long)GetWindowLongPtr(handle, GwlExStyle);
        var wanted = through ? style | WsExTransparent : style & ~WsExTransparent;
        if (wanted != style) SetWindowLongPtr(handle, GwlExStyle, (IntPtr)wanted);
    }

    /// <summary>Pencere en çok üç satıra (ve satırların kaymasına) yetecek kadar yüksektir; alt kenarı sabit kalır.</summary>
    private void FitHeight()
    {
        var height = OverlayPlacement.Height(controller.Settings.Style.FontSize, Scale);
        if (Math.Abs(Height - height) < 0.5) return;
        var bottom = double.IsNaN(Top) ? double.NaN : Top + Height;
        Height = height;
        if (!double.IsNaN(bottom)) Top = bottom - height;
    }

    /// <summary>
    /// Kayıtlı yer (ekranlardan birinde yeterince görünüyorsa) ya da ana ekranın altında ortada, %70 genişlikte. Kayıt
    /// bozuksa ya da o ekran artık bağlı değilse pencere ekran dışında ya da sıfır genişlikte açılmaz.
    /// </summary>
    private void PlaceFromSettings()
    {
        var height = OverlayPlacement.Height(controller.Settings.Style.FontSize, Scale);
        var work = SystemParameters.WorkArea;
        var place = OverlayPlacement.Place(controller.Settings.Overlay,
            new ScreenArea(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop,
                SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight),
            new ScreenArea(work.Left, work.Top, work.Width, work.Height), height);
        Height = height;
        Width = place.Width;
        Left = place.Left;
        Top = place.Top;
    }

    /// <summary>NaN ya da sonsuz değer JSON'a yazılamaz (ayar kaydı hata verirdi); öyleyse kaydedilmez.</summary>
    private void SaveBounds()
    {
        if (OverlayPlacement.ToSave(Left, Top, Width) is { } bounds) controller.SaveOverlayBounds(bounds);
    }
}
