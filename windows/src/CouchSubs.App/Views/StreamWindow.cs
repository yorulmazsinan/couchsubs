// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>
/// "Yayın penceresi" (Mac: StreamWindow.swift): şeffaflık tanımayan yayın programları (TikTok LIVE Studio, Streamlabs,
/// OBS dışındakiler) için düz renkli zeminde altyazı çizen sıradan bir pencere. Programda "Pencere yakalama" ile eklenir,
/// zemin chroma key ile silinir. Başlığı sabittir ki yakalama listesinde bulunsun. Saydam altyazı penceresinden
/// (<see cref="SubtitleOverlayWindow"/>) ayrıdır; altyazı yalnız TV'de gösterilse de satırlar gelir.
/// </summary>
public sealed class StreamWindow : Window
{
    private static StreamWindow? open;

    private readonly AppController controller;
    private readonly SubtitleStack stack = new();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly DispatcherTimer timer = new();
    private readonly StackPanel linesPanel = new() { VerticalAlignment = VerticalAlignment.Bottom };
    /// <summary>Ek alanların (görev, telefon mesajı, bildirim) çevirileri; saydam penceredeki gibi üstte, alanın yanına yaslı.</summary>
    private readonly DesktopRegionsPanel regionsPanel;
    private readonly Dictionary<string, (string Text, CouchSubs.Core.TextBox? Box, IReadOnlyList<ScreenTranslation.Item>? Blocks)> regions = [];
    private readonly Border linesHost;
    private readonly Dictionary<int, Border> boxes = [];
    private double screenUntil;
    /// <summary>Stilli "Ekranı çevir" kutularının kalkacağı an; yoksa 0 (yeni altyazı onları kaldırmaz, TV'deki gibi).</summary>
    private double screenRegionUntil;

    private double Now => clock.Elapsed.TotalSeconds;

    /// <summary>Yazı boyu TV'deki gibi 1080 satırlık ekrana göredir; pencerenin içerik yüksekliğine ölçeklenir.</summary>
    private double Scale => Math.Max(0.2, (linesHost.ActualHeight > 0 ? linesHost.ActualHeight : 720) / 1080);

    /// <summary>Pencereyi açar; zaten açıksa öne getirir.</summary>
    public static void Open(AppController controller)
    {
        if (open is { } window)
        {
            if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
            window.Activate();
            return;
        }
        open = new StreamWindow(controller);
        open.Show();
    }

    public static bool IsOpen => open is not null;

    /// <summary>Açık pencereyi kapatır (Ayarlar'daki "Akış penceresini kapat"; Mac ile aynı).</summary>
    public static void CloseIfOpen() => open?.Close();

    /// <summary>Yayın programının pencere listesinde görünen ad; altyazıya göre değişmez (Türkçede "CouchSubs Yayın").</summary>
    public static string WindowTitle => Localizer.Current["CouchSubs Stream"];

    private StreamWindow(AppController controller)
    {
        this.controller = controller;
        Title = WindowTitle;
        // 1280x720 içerik: 16:9, yayın programında kaynak oranı bozulmaz.
        SizeToContent = SizeToContent.Manual;
        Width = 1296;
        Height = 759;
        MinWidth = 400;
        MinHeight = 260;
        ResizeMode = ResizeMode.CanResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
        // Video kaynağında renkli alt piksel yumuşatma kenarda renk saçağı bırakır; gri tonlu yumuşatma keskin kalır.
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.Grayscale);
        var layers = new Grid();
        regionsPanel = new DesktopRegionsPanel(linesPanel);
        layers.Children.Add(regionsPanel);
        layers.Children.Add(linesPanel);
        linesHost = new Border { Child = layers };
        Content = linesHost;
        ApplyBackground();
        linesHost.SizeChanged += (_, _) =>
        {
            linesHost.Padding = new Thickness(24 * Scale, 0, 24 * Scale, linesHost.ActualHeight * 0.07);
            regionsPanel.Margin = new Thickness(0, 16 * Scale, 0, 0);
            boxes.Clear();
            Refresh();
        };

        timer.Tick += (_, _) =>
        {
            timer.Stop();
            Refresh();
        };
        controller.StreamEvent += OnEvent;
        controller.StreamHidden += OnHidden;
        controller.PropertyChanged += OnChanged;
        Closed += (_, _) =>
        {
            controller.StreamEvent -= OnEvent;
            controller.StreamHidden -= OnHidden;
            controller.PropertyChanged -= OnChanged;
            timer.Stop();
            open = null;
        };
    }

    private void ApplyBackground()
    {
        var (red, green, blue) = controller.StreamBackground.Rgb();
        linesHost.Background = new SolidColorBrush(Color.FromRgb(red, green, blue));
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppController.StreamBackground)) ApplyBackground();
        if (e.PropertyName != nameof(AppController.Settings)) return;
        // Yazı boyu, rengi ya da zemini değişmiş olabilir; kutular yeniden kurulur.
        boxes.Clear();
        Refresh();
    }

    /// <summary>Saydam penceredekiyle aynı kurallar (bkz. <see cref="SubtitleOverlayWindow"/>).</summary>
    private void OnEvent(SubtitleEvent e)
    {
        stack.StackPrevious = controller.Settings.Style.StackPrevious;
        switch (e.Kind)
        {
            case SubtitleEventKind.Subtitle:
                screenUntil = 0;
                stack.Show(e.Text, e.DurationMs, e.Paragraphs, Now, e.Replaces);
                break;
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
            // Ek alan olayı altyazıya dokunmaz: önceden "temizle" sayılıp yayındaki altyazıyı siliyordu ve çeviri hiç
            // görünmüyordu.
            case SubtitleEventKind.Region:
                if (e.Id is null) break;
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
    }

    private void OnHidden()
    {
        stack.Hide();
        regions.Clear();
        Refresh();
    }

    private void Refresh()
    {
        var now = Now;
        if (screenRegionUntil > 0 && screenRegionUntil <= now)
        {
            regions.Remove(ScreenRegions.Id);
            screenRegionUntil = 0;
        }
        var lines = stack.Lines(now).ToList();
        regionsPanel.ShowRegions(regions, MakeRegionBox);
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
        timer.Stop();
        if (ScreenRegions.NextChange(stack.NextChange(now), screenRegionUntil) is { } next)
        {
            timer.Interval = TimeSpan.FromSeconds(Math.Max(0.01, next - now));
            timer.Start();
        }
    }

    /// <summary>
    /// TV'deki altyazı kutusu; düz zeminde yarı saydamlık zeminle karışıp chroma key'i bozacağından kutu tam koyudur
    /// (ya da hiç yoktur) ve üst satırlar yazı renginden soldurulur.
    /// </summary>
    private Border MakeBox(SubtitleStack.Line line)
    {
        var style = controller.Settings.Style;
        var scale = Scale;
        var current = line.Role == SubtitleStack.Role.Current;
        var wrapped = line.FittedTo(SubtitleWrap.DesktopMaxChars);
        var size = Math.Max(1, OverlayPlacement.FontSize(style.FontSize) * scale * (current ? 1 : 0.8) * wrapped.Scale);
        var boxed = StreamBackgrounds.BoxOpacity(style.Background) > 0;
        var dim = line.Role switch { SubtitleStack.Role.Current => 1.0, SubtitleStack.Role.Previous => 0.6, _ => 0.45 };
        var color = style.TextColor == SubtitleTextColor.Yellow ? Color.FromRgb(0xFF, 0xE1, 0x35) : Colors.White;
        if (boxed) color.A = (byte)Math.Round(dim * 255);
        var text = new TextBlock
        {
            FontSize = size,
            FontWeight = style.Bold ? FontWeights.Bold : FontWeights.SemiBold,
            Foreground = new SolidColorBrush(color),
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = line.Paragraphs ? TextAlignment.Left : TextAlignment.Center,
            LineHeight = size * 1.3,
            Effect = boxed ? null : new DropShadowEffect { Color = Colors.Black, ShadowDepth = 2 * scale, BlurRadius = 4 * scale, Opacity = 1, Direction = 270 },
        };
        // Konuşana göre renk: "Ad: …" satırı o konuşanın renginde (ayar kapalıysa düz metin).
        SpeakerText.Fill(text, wrapped.Text, line.Text, controller.Settings.SpeakerColors, controller.SpeakerBook, color.A);
        return new Border
        {
            Background = boxed ? Brushes.Black : Brushes.Transparent,
            CornerRadius = new CornerRadius(10 * scale),
            Padding = current ? new Thickness(26 * scale, 10 * scale, 26 * scale, 10 * scale) : new Thickness(20 * scale, 6 * scale, 20 * scale, 6 * scale),
            Margin = new Thickness(0, 14 * scale, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = text,
        };
    }

    /// <summary>Ek alanın çevirisi: altyazıdan küçük, tam koyu kutu (düz zeminde chroma key bozulmasın); alanın yanına yaslı.</summary>
    private Border MakeRegionBox(string text, CouchSubs.Core.TextBox? area, IReadOnlyList<ScreenTranslation.Item>? blocks)
    {
        var style = controller.Settings.Style;
        var scale = Scale;
        var size = Math.Max(12, OverlayPlacement.FontSize(style.FontSize) * scale * 0.55);
        // Otomatik bulunan ekran yazısı: çeviri özgün yazının stilinde.
        var apart = controller.Settings.SetTextApart;
        if (apart && StyledRegionBox.Make(blocks, size, scale, translucent: false) is { } styled) return styled;
        // Ayrık gösterim: stili bilinmeyen ek alan kutusu altyazı kutusuna benzemesin, zeminsiz ve koyu gölgeli.
        if (apart && StyledRegionBox.Plain(text, size, scale, area) is { } plain) return plain;
        var middle = area is { } box ? (box.Left + box.Right) / 2 : 0.5;
        return new Border
        {
            Background = Brushes.Black,
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
}
