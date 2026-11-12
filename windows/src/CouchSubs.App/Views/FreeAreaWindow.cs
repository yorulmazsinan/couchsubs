// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using CouchSubs.Core;
using CouchSubs.Shell;
using Frame = CouchSubs.Core.Frame;

namespace CouchSubs.App.Views;

/// <summary>
/// Serbest alan çevirisi (Num 5): oyunun o anki görüntüsü bilgisayarın ekranında donar, kullanıcı fareyle bir alan seçer,
/// o alan bir kez okunup çevrilir. Sonuç ayara göre TV'de, bilgisayarda ya da ikisinde de görünür.
/// Esc ya da sağ tık pencereyi kapatır; kapatmadan başka alanlar da seçilebilir.
/// </summary>
public sealed class FreeAreaWindow : Window
{
    private static FreeAreaWindow? current;

    private readonly AppController controller;
    private readonly Frame frame;
    private readonly Canvas canvas;
    private readonly Rectangle selection;
    private readonly Border resultPanel;
    private readonly TextBlock resultText;
    private Point start;
    private bool dragging;
    /// <summary>Her seçim yeni numara alır; eski seçimin geç gelen sonucu yenisini ezmez.</summary>
    private int version;

    /// <summary>Pencereyi açar; zaten açıksa öne getirir. Çeviri sürmüyorsa (kare yoksa) hiçbir şey yapmaz.</summary>
    public static void Open(AppController controller)
    {
        if (current is not null)
        {
            current.Activate();
            return;
        }
        if (controller.LastFrame is not { } frame) return;
        current = new FreeAreaWindow(controller, frame);
        current.Show();
        current.Activate();
    }

    private FreeAreaWindow(AppController controller, Frame frame)
    {
        this.controller = controller;
        this.frame = frame;
        Title = "CouchSubs";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        WindowState = WindowState.Maximized;
        Topmost = true;
        ShowInTaskbar = false;
        Background = Brushes.Black;
        Cursor = Cursors.Cross;

        var bitmap = BitmapSource.Create(frame.Width, frame.Height, 96, 96, PixelFormats.Bgra32, null, frame.Pixels, frame.Stride);
        canvas = new Canvas { Width = frame.Width, Height = frame.Height, Background = Brushes.Transparent };
        canvas.Children.Add(new Image { Source = bitmap, Width = frame.Width, Height = frame.Height, Stretch = Stretch.Fill, IsHitTestVisible = false });

        var accent = Application.Current.TryFindResource("accentBrush") as Brush ?? Brushes.Orange;
        selection = new Rectangle
        {
            Stroke = accent,
            StrokeThickness = Math.Max(2, frame.Height / 360.0),
            Fill = new SolidColorBrush(Color.FromArgb(40, 245, 184, 61)),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        canvas.Children.Add(selection);

        resultText = new TextBlock
        {
            Foreground = Brushes.White,
            FontSize = Math.Max(16, frame.Height * 0.032),
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = frame.Width * 0.5,
        };
        resultPanel = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xE6, 0, 0, 0)),
            CornerRadius = new CornerRadius(frame.Height * 0.012),
            Padding = new Thickness(frame.Height * 0.018),
            Child = resultText,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        canvas.Children.Add(resultPanel);

        var hint = new TextBlock
        {
            Text = Localizer.Current["Drag over the text you want to translate. Esc or right-click closes."],
            Foreground = Brushes.White,
            Background = new SolidColorBrush(Color.FromArgb(0xB3, 0, 0, 0)),
            Padding = new Thickness(16, 8, 16, 8),
            FontSize = 15,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 12, 0, 0),
            IsHitTestVisible = false,
        };
        var root = new Grid();
        root.Children.Add(new Viewbox { Stretch = Stretch.Uniform, Child = canvas });
        root.Children.Add(hint);
        Content = root;

        canvas.MouseLeftButtonDown += OnDown;
        canvas.MouseMove += OnMove;
        canvas.MouseLeftButtonUp += OnUp;
        MouseRightButtonDown += (_, _) => Close();
        // Esc'in basılma olayı burada yutulur, pencere tuş bırakılınca kapanır: tuş basılı kalıp tekrarlansa bile
        // olay arkadaki ayar penceresine ulaşıp onu da kapatmaz.
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) e.Handled = true;
        };
        KeyUp += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            Close();
        };
        Closed += (_, _) => current = null;
    }

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        start = ClampToFrame(e.GetPosition(canvas));
        dragging = true;
        resultPanel.Visibility = Visibility.Collapsed;
        Place(selection, new Rect(start, start));
        selection.Visibility = Visibility.Visible;
        canvas.CaptureMouse();
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        if (dragging) Place(selection, new Rect(start, ClampToFrame(e.GetPosition(canvas))));
    }

    private async void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (!dragging) return;
        dragging = false;
        canvas.ReleaseMouseCapture();
        var rect = new Rect(start, ClampToFrame(e.GetPosition(canvas)));
        // Tıklamak ya da çok küçük çizmek alan seçmez.
        if (rect.Width < frame.Width * 0.01 || rect.Height < frame.Height * 0.01)
        {
            selection.Visibility = Visibility.Collapsed;
            return;
        }

        var text = Localizer.Current;
        var token = ++version;
        ShowResult(text["Translating…"], rect);
        var region = new CropRegion(rect.Top / frame.Height, rect.Bottom / frame.Height, rect.Left / frame.Width, rect.Right / frame.Width);
        var (outcome, result) = await controller.TranslateAreaAsync(frame, region);
        if (token != version || !IsLoaded) return;

        switch (outcome)
        {
            case ExtraRegionOutcome.Shown when result is not null:
                ShowResult(result.Translation, rect);
                break;
            case ExtraRegionOutcome.NoText:
                ShowResult(text["No text found in this area."], rect);
                break;
            case ExtraRegionOutcome.Busy:
                ShowResult(text["Translating…"], rect);
                break;
            default:
                ShowResult(text["Could not translate this area."], rect);
                break;
        }

        // Yalnız TV'de gösteriliyorsa bilgisayar ekranının işi bitmiştir; pencere kendiliğinden kapanır.
        if (outcome == ExtraRegionOutcome.Shown && controller.Settings.FreeAreaTarget == ResultTarget.Tv)
        {
            await Task.Delay(700);
            if (token == version && IsLoaded) Close();
        }
    }

    /// <summary>Metni seçilen alanın altına (sığmıyorsa üstüne) koyar.</summary>
    private void ShowResult(string text, Rect area)
    {
        resultText.Text = text;
        resultPanel.Visibility = Visibility.Visible;
        resultPanel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = resultPanel.DesiredSize;
        var gap = frame.Height * 0.012;
        var y = area.Bottom + gap;
        if (y + size.Height > frame.Height) y = area.Top - gap - size.Height;
        y = Math.Clamp(y, 0, Math.Max(0, frame.Height - size.Height));
        var x = Math.Clamp(area.Left, 0, Math.Max(0, frame.Width - size.Width));
        Canvas.SetLeft(resultPanel, x);
        Canvas.SetTop(resultPanel, y);
    }

    private Point ClampToFrame(Point point) => new(Math.Clamp(point.X, 0, frame.Width), Math.Clamp(point.Y, 0, frame.Height));

    private static void Place(Rectangle rectangle, Rect area)
    {
        Canvas.SetLeft(rectangle, area.X);
        Canvas.SetTop(rectangle, area.Y);
        rectangle.Width = area.Width;
        rectangle.Height = area.Height;
    }
}
