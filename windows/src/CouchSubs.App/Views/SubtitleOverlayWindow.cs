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
using CouchSubs.App.Services;
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
    private readonly DesktopRegionsPanel regionsPanel;
    /// <summary>Görünen satırların kutuları; solan satırın animasyonu yeniden çizimde baştan başlamasın.</summary>
    private readonly Dictionary<int, Border> boxes = [];
    /// <summary>Son altyazının metni ve oyundaki yeri: "Yazı kadar" zeminde o satırın kutusu oyunun altyazısını örter.</summary>
    private (string Text, CouchSubs.Core.TextBox Box)? subtitleBox;
    private readonly Grid adjustLayer = new() { Visibility = Visibility.Collapsed };
    /// <summary>Başka bir tam ekran ya da üstte duran pencere öne gelince altyazıyı yeniden en üste koyar.</summary>
    private readonly TopmostKeeper topmost;
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
        topmost = new TopmostKeeper(this);

        var root = new Grid();
        regionsPanel = new DesktopRegionsPanel(linesPanel, 8 * Scale);
        root.Children.Add(adjustLayer);
        root.Children.Add(new Border { Padding = new Thickness(24 * Scale, 0, 24 * Scale, 8 * Scale), Child = linesPanel });
        root.Children.Add(new Border { Padding = new Thickness(24 * Scale, 8 * Scale, 24 * Scale, 0), Child = regionsPanel });
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
        // Tıklamalar geçmiyorsa pencere her yerinden sürüklenir. Konumlandırılırken çift tık yeni yeri kaydeder.
        MouseLeftButtonDown += (_, e) => Guard("sürükleme", () =>
        {
            if (e.OriginalSource is Thumb or ButtonBase || e.ButtonState != MouseButtonState.Pressed) return;
            if (controller.OverlayAdjusting && e.ClickCount == 2)
            {
                Commit();
                return;
            }
            try { DragMove(); }
            catch (InvalidOperationException) { return; /* düğme bu arada bırakıldı */ }
            SaveBounds();
        });
        // Konumlandırılırken Enter kaydeder, Esc vazgeçer (pencere o sırada odağı alabilir).
        KeyDown += (_, e) => Guard("tuş", () =>
        {
            if (!controller.OverlayAdjusting) return;
            if (e.Key is Key.Enter or Key.Return) { Commit(); e.Handled = true; }
            else if (e.Key == Key.Escape) { controller.CancelOverlayEdit(); e.Handled = true; }
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
        topmost.Dispose();
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
            if (e.PropertyName == nameof(AppController.OverlayAdjusting)) AdjustingChanged();
            ApplyClickThrough();
            FitHeight();
            Refresh();
        });
    }

    private void OnEvent(SubtitleEvent e) => Guard("altyazı", () =>
    {
        stack.StackPrevious = controller.Settings.Style.StackPrevious;
        switch (e.Kind)
        {
            case SubtitleEventKind.Subtitle:
                screenUntil = 0;
                subtitleBox = e.Box is { } subtitleArea ? (e.Text, subtitleArea) : null;
                stack.Show(e.Text, e.DurationMs, e.Paragraphs, Now, e.Replaces);
                break;
            // "Ekranı çevir": çeviriler satır satır gösterilir. Hemen ardından gelen "temizle" ("Ekran çevriliyor…"
            // yazısı için) onları kaldırmaz; yeniden basmak (ScreenClear) ya da yeni altyazı kaldırır.
            case SubtitleEventKind.Screen:
                // Özgün stiliyle gelen çeviriler ekran yazısı gibi stilli kutularda (telefon kartı balonlarıyla);
                // "Ekran yazılarını altyazıdan ayır" kapalıysa eskisi gibi satır satır.
                if (ScreenRegions.Styled(e, controller.Settings.SetTextApart) is { } styled)
                {
                    regions[ScreenRegions.Id] = styled;
                    screenRegionUntil = Now + e.DurationMs / 1000.0;
                    break;
                }
                stack.Show(e.Text, e.DurationMs, paragraphs: true, Now);
                screenUntil = Now + e.DurationMs / 1000.0;
                break;
            case SubtitleEventKind.ScreenClear:
                if (screenUntil > Now) stack.Hide();
                screenUntil = 0;
                regions.Remove(ScreenRegions.Id);
                screenRegionUntil = 0;
                break;
            // Ek alanların çevirisi altyazının üstünde, alanın bulunduğu yana yaslı küçük kutularda durur.
            case SubtitleEventKind.Region:
                if (e.Id is null) break;
                // Kendiliğinden bulunan ekran yazıları (auto-…) bu pencerede gösterilmez: saydam pencere kullanıcının
                // seçtiği altyazı yeridir; oyunun her yerindeki yazılar burada altyazının üstüne yığılıp altyazı
                // "istenmeyen yerden çıkıyor" gibi görünüyordu (beta.63). Onlar TV'de ve yayın penceresinde kendi yerinde.
                if (ScreenTextAreas.IsAuto(e.Id)) break;
                regions.Remove(e.Id);
                if (e.Text.Length > 0) regions[e.Id] = (e.Text, e.Box, e.Blocks);
                break;
            case SubtitleEventKind.RegionClear:
                regions.Clear();
                break;
            default:
                if (screenUntil <= Now) stack.Clear(Now);
                break;
        }
        Refresh();
    });

    /// <summary>"Ekranı çevir" çevirilerinin pencerede kalacağı an (<see cref="Now"/> saatiyle); yoksa 0.</summary>
    private double screenUntil;
    /// <summary>Stilli "Ekranı çevir" kutularının kalkacağı an; yoksa 0 (yeni altyazı onları kaldırmaz, TV'deki gibi).</summary>
    private double screenRegionUntil;

    /// <summary>Ek alanların penceredeki çevirileri (kimlik → metin ve oyundaki yeri).</summary>
    private readonly Dictionary<string, (string Text, CouchSubs.Core.TextBox? Box, IReadOnlyList<ScreenTranslation.Item>? Blocks)> regions = [];

    private void OnHidden() => Guard("gizleme", () =>
    {
        stack.Hide();
        regions.Clear();
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
        if (screenRegionUntil > 0 && screenRegionUntil <= now)
        {
            regions.Remove(ScreenRegions.Id);
            screenRegionUntil = 0;
        }
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

        regionsPanel.ShowRegions(regions, MakeRegionBox);

        var visible = controller.ShowsOnComputer && (lines.Count > 0 || regions.Count > 0);
        if (visible && !IsVisible) Show();
        else if (!visible && IsVisible) Hide();
        // Arada öne gelen tam ekran/üstte duran pencere altyazıyı örtmüş olabilir; odak alınmadan yeniden üste konur.
        if (visible) topmost.RaiseThrottled();

        timer.Stop();
        if (ScreenRegions.NextChange(stack.NextChange(now), screenRegionUntil) is { } next)
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
        // Uzun çeviri en çok 3 satıra dengeli bölünür; 3 satıra sığmazsa yazı biraz küçülür (bkz. SubtitleWrap).
        var wrapped = line.Wrapped;
        var size = Math.Max(1, OverlayPlacement.FontSize(style.FontSize) * scale * (current ? 1 : 0.8) * wrapped.Scale);
        var alpha = Math.Clamp(style.Background, 0, 100) / 100.0 * (current ? 1 : 0.83);
        // Bant: kutu pencerenin tüm genişliğini kaplar, oyundaki İngilizce yazıyı yan yana da gizler.
        var band = style.BackgroundShape == SubtitleBackgroundShape.Band;
        var text = new TextBlock
        {
            FontSize = size,
            FontWeight = style.Bold ? FontWeights.Bold : FontWeights.SemiBold,
            Foreground = style.TextColor == SubtitleTextColor.Yellow ? new SolidColorBrush(Color.FromRgb(0xFF, 0xE1, 0x35)) : Brushes.White,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = line.Paragraphs ? TextAlignment.Left : TextAlignment.Center,
            LineHeight = size * 1.3,
            Effect = new DropShadowEffect { Color = Colors.Black, ShadowDepth = 2 * scale, BlurRadius = 4 * scale, Opacity = 1, Direction = 270 },
        };
        // Konuşana göre renk: "Ad: …" satırı o konuşanın renginde (ayar kapalıysa düz metin).
        SpeakerText.Fill(text, wrapped.Text, line.Text, controller.Settings.SpeakerColors, controller.SpeakerBook);
        var padding = current ? new Thickness(26 * scale, 10 * scale, 26 * scale, 10 * scale) : new Thickness(20 * scale, 6 * scale, 20 * scale, 6 * scale);
        // "Yazı kadar" ve örtü: güncel satırın kutusu en az oyundaki altyazının ekrandaki kutusu kadar (her yana pay). Çeviri kısa
        // kalınca oyunun altyazısı kutunun yanlarından taşıyordu; çeviri daha uzunsa kutu yine yazı kadar büyür (TV'deki örtü gibi).
        UIElement content = text;
        if (!band && current && !line.Paragraphs && style.Placement == SubtitlePlacement.Cover
            && subtitleBox is { } cover && cover.Text == line.Text
            && OverlayPlacement.CoverSize(cover.Box, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight, scale) is { } area)
        {
            // Kutu pencereye sığar (yanlarda 24 birim boşluk ve kutunun dolgusu); taşan kutuyu WPF sola yaslayıp keserdi.
            var room = double.IsFinite(Width) ? Math.Max(0, Width - 2 * 24 * scale - padding.Left - padding.Right) : double.PositiveInfinity;
            text.HorizontalAlignment = HorizontalAlignment.Center;
            text.VerticalAlignment = VerticalAlignment.Center;
            content = new Grid
            {
                MinWidth = Math.Min(Math.Max(0, area.Width - padding.Left - padding.Right), room),
                MinHeight = Math.Max(0, area.Height - padding.Top - padding.Bottom),
                Children = { text },
            };
        }
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round(alpha * 255), 0, 0, 0)),
            CornerRadius = new CornerRadius(band ? 0 : 10 * scale),
            Padding = padding,
            Margin = new Thickness(band ? -24 * scale : 0, 14 * scale, band ? -24 * scale : 0, 0),
            HorizontalAlignment = band ? HorizontalAlignment.Stretch : HorizontalAlignment.Center,
            Opacity = line.Role switch { SubtitleStack.Role.Current => 1, SubtitleStack.Role.Previous => 0.6, _ => 0.45 },
            Child = content,
        };
    }

    /// <summary>Ek alanın çevirisi: altyazıdan küçük, koyu zeminli kutu; oyundaki yazının bulunduğu yana yaslı.</summary>
    private Border MakeRegionBox(string text, CouchSubs.Core.TextBox? area, IReadOnlyList<ScreenTranslation.Item>? blocks)
    {
        var style = controller.Settings.Style;
        var scale = Scale;
        var size = Math.Max(12, OverlayPlacement.FontSize(style.FontSize) * scale * 0.55);
        // Otomatik bulunan ekran yazısı: çeviri özgün yazının stilinde.
        var apart = controller.Settings.SetTextApart;
        if (apart && StyledRegionBox.Make(blocks, size, scale, translucent: true) is { } styled) return styled;
        // Ayrık gösterim: stili bilinmeyen ek alan kutusu altyazı kutusuna benzemesin, zeminsiz ve koyu gölgeli.
        if (apart && StyledRegionBox.Plain(text, size, scale, area) is { } plain) return plain;
        var middle = area is { } box ? (box.Left + box.Right) / 2 : 0.5;
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xD9, 0, 0, 0)),
            CornerRadius = new CornerRadius(8 * scale),
            Padding = new Thickness(14 * scale, 6 * scale, 14 * scale, 6 * scale),
            Margin = new Thickness(0, 0, 0, 10 * scale),
            HorizontalAlignment = middle < 0.4 ? HorizontalAlignment.Left : middle > 0.6 ? HorizontalAlignment.Right : HorizontalAlignment.Center,
            Child = new TextBlock
            {
                Text = text,
                FontSize = size,
                FontWeight = FontWeights.SemiBold,
                Foreground = style.TextColor == SubtitleTextColor.Yellow ? new SolidColorBrush(Color.FromRgb(0xFF, 0xE1, 0x35)) : Brushes.White,
                TextWrapping = TextWrapping.Wrap,
                LineHeight = size * 1.25,
            },
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
        done.Click += (_, _) => Guard("Bitti", Commit);
        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(12) };
        var hints = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        hints.Children.Add(new TextBlock
        {
            Text = Localizer.Current["Drag to move, drag the edges to resize."],
            Foreground = Brushes.White,
            FontWeight = FontWeights.SemiBold,
        });
        hints.Children.Add(new TextBlock
        {
            Text = Localizer.Current["Double-click or press Enter to save, Esc to cancel."],
            Foreground = Brushes.White,
            Opacity = 0.8,
        });
        bar.Children.Add(hints);
        bar.Children.Add(done);
        adjustLayer.Children.Add(bar);
        adjustLayer.Children.Add(MakeHandle(HorizontalAlignment.Left, accent));
        adjustLayer.Children.Add(MakeHandle(HorizontalAlignment.Right, accent));
        adjustLayer.Children.Add(MakeHeightHandle(VerticalAlignment.Top, accent));
        adjustLayer.Children.Add(MakeHeightHandle(VerticalAlignment.Bottom, accent));
    }

    private static Thumb Handle(Brush accent, double width, double height, Cursor cursor)
    {
        var face = new FrameworkElementFactory(typeof(Border));
        face.SetValue(Border.BackgroundProperty, accent);
        face.SetValue(Border.CornerRadiusProperty, new CornerRadius(3));
        return new Thumb
        {
            Width = width,
            Height = height,
            Cursor = cursor,
            Template = new ControlTemplate(typeof(Thumb)) { VisualTree = face },
        };
    }

    /// <summary>Kenardan genişletme: ortası yerinde kalır, iki yana eşit büyür.</summary>
    private Thumb MakeHandle(HorizontalAlignment side, Brush accent)
    {
        var thumb = Handle(accent, 6, 48, Cursors.SizeWE);
        thumb.Margin = new Thickness(6, 0, 6, 0);
        thumb.HorizontalAlignment = side;
        thumb.VerticalAlignment = VerticalAlignment.Center;
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

    /// <summary>Üst ya da alt kenardan boy: karşı kenar yerinde kalır; oran kaydedilir, yazı boyu değişince korunur.</summary>
    private Thumb MakeHeightHandle(VerticalAlignment side, Brush accent)
    {
        var thumb = Handle(accent, 48, 6, Cursors.SizeNS);
        thumb.Margin = new Thickness(0, 6, 0, 6);
        thumb.HorizontalAlignment = HorizontalAlignment.Center;
        thumb.VerticalAlignment = side;
        thumb.DragDelta += (_, e) => Guard("boy", () =>
        {
            var bottom = Top + Height;
            if (!double.IsFinite(bottom)) return;
            var baseHeight = BaseHeight;
            var grow = side == VerticalAlignment.Top ? -e.VerticalChange : e.VerticalChange;
            heightScale = OverlayPlacement.HeightScaleFor(Height + grow, baseHeight);
            var height = Math.Round(baseHeight * heightScale);
            if (side == VerticalAlignment.Top) Top = bottom - height;
            Height = height;
        });
        thumb.DragCompleted += (_, _) => Guard("boy", SaveBounds);
        return thumb;
    }

    /// <summary>Yazı boyundan hesaplanan yükseklik (oran 1).</summary>
    private double BaseHeight => OverlayPlacement.Height(controller.Settings.Style.FontSize, Scale);

    /// <summary>Kullanıcının üst ya da alt kenardan verdiği yükseklik oranı.</summary>
    private double heightScale = 1;

    /// <summary>Düzenleme açıldı ya da kapandı. Kapanınca pencere kayıtlı yere döner: Esc ile vazgeçildiyse eski yere,
    /// kaydedildiyse yeni yere. Düzenlenirken pencere odağı alabilir (Enter ve Esc için).</summary>
    private void AdjustingChanged()
    {
        if (handle != IntPtr.Zero)
        {
            var style = (long)GetWindowLongPtr(handle, GwlExStyle);
            var wanted = controller.OverlayAdjusting ? style & ~WsExNoActivate : style | WsExNoActivate;
            if (wanted != style) SetWindowLongPtr(handle, GwlExStyle, (IntPtr)wanted);
        }
        Focusable = controller.OverlayAdjusting;
        if (controller.OverlayAdjusting)
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (!controller.OverlayAdjusting || !IsVisible) return;
                Activate();
                Focus();
            }, DispatcherPriority.Background);
        }
        else PlaceFromSettings();
    }

    /// <summary>Düzenlemeyi bitirir ve yeni yeri kaydeder.</summary>
    private void Commit()
    {
        SaveBounds();
        controller.CommitOverlayEdit();
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
        var height = Math.Round(BaseHeight * heightScale);
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
        var height = BaseHeight;
        var work = SystemParameters.WorkArea;
        var place = OverlayPlacement.Place(controller.Settings.Overlay,
            new ScreenArea(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop,
                SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight),
            new ScreenArea(work.Left, work.Top, work.Width, work.Height), height, Displays.All(this));
        heightScale = place.HeightScale;
        Height = Math.Round(height * heightScale);
        Width = place.Width;
        Left = place.Left;
        Top = place.Top;
    }

    /// <summary>
    /// Yeri, boyu ve bulunduğu ekranı kaydeder. "Altyazıyı konumlandır" açıkken yalnız taslak tutulur; Enter, çift tık ya da
    /// Bitti kaydeder, Esc vazgeçer. NaN ya da sonsuz değer JSON'a yazılamaz (ayar kaydı hata verirdi); öyleyse kaydedilmez.
    /// </summary>
    private void SaveBounds()
    {
        if (OverlayPlacement.ToSave(Left, Top, Width, Height, BaseHeight, Displays.All(this)) is not { } bounds) return;
        if (controller.OverlayAdjusting) controller.OverlayDraft = bounds;
        else controller.SaveOverlayBounds(bounds);
    }
}
