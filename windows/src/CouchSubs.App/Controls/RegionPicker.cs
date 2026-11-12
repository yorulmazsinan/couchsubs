// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using CouchSubs.Core;
using Frame = CouchSubs.Core.Frame;

namespace CouchSubs.App.Controls;

/// <summary>
/// Son karenin üstünde bir bölgeyi gösteren ve fareyle çizilen çerçeve: boş yerde sürükleyince yeni bölge çizilir,
/// kenar ve köşelerden tutunca boyutu, içinden tutunca yeri değişir.
/// </summary>
public sealed class RegionPicker : UserControl
{
    /// <summary>Kenara bu kadar piksel yaklaşınca kenar tutulur.</summary>
    private const double Grab = 10;
    /// <summary>Bölge her kenarda en az bu orana (0–1) sahip olur.</summary>
    private const double MinSize = 0.03;

    [Flags]
    private enum Edges { None = 0, Left = 1, Top = 2, Right = 4, Bottom = 8 }

    private enum Drag { None, Draw, Move, Resize }

    private readonly Grid preview = new() { Height = 281, ClipToBounds = true, Background = Brushes.Transparent };
    private readonly Rectangle frameBox = new() { StrokeThickness = 2, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false };
    private readonly Rectangle[] handles = [Handle(), Handle(), Handle(), Handle()];
    private CropRegion region = new();
    /// <summary>Görüntünün en/boy oranı; önizleme genişliğe göre bu oranla boy alır (pencere büyüdükçe büyür).</summary>
    private double aspect = 16.0 / 9;
    private Drag drag = Drag.None;
    private Edges dragEdges;
    private Point anchor;
    private CropRegion dragStart = new();

    public event EventHandler<CropRegion>? RegionChanged;

    /// <summary>Çerçeve şu an fareyle çiziliyor ya da taşınıyor (önizleme bu sırada yenilenmez).</summary>
    public bool IsDragging => drag != Drag.None;

    /// <summary>"Alanı sıfırla" düğmesinin döneceği bölge (ek bölgelerin varsayılanı altyazınınkinden farklıdır).</summary>
    public CropRegion DefaultRegion { get; set; } = new();

    public RegionPicker()
    {
        frameBox.SetResourceReference(Shape.StrokeProperty, "accentBrush");
        frameBox.Fill = new SolidColorBrush(Color.FromArgb(36, 245, 184, 61));
        foreach (var handle in handles) handle.SetResourceReference(Shape.FillProperty, "accentBrush");
        preview.SizeChanged += (_, _) => Layout();
        SizeChanged += (_, _) => FitHeight();
        preview.MouseLeftButtonDown += OnDown;
        preview.MouseMove += OnMove;
        preview.MouseLeftButtonUp += OnUp;
        preview.LostMouseCapture += (_, _) => drag = Drag.None;

        var panel = new StackPanel();
        var border = new Border { Child = preview, ClipToBounds = true };
        border.SetResourceReference(Border.CornerRadiusProperty, "radius.inner");
        border.SetResourceReference(Border.BackgroundProperty, "backgroundBrush");
        panel.Children.Add(border);

        var reset = new Button { Content = Localizer.Current["Reset area"], Margin = new Thickness(0, 12, 0, 0) };
        reset.Click += (_, _) => Region = DefaultRegion;
        panel.Children.Add(reset);
        Content = panel;
        Frame = null;
    }

    private static Rectangle Handle() => new()
    {
        Width = 10,
        Height = 10,
        HorizontalAlignment = HorizontalAlignment.Left,
        VerticalAlignment = VerticalAlignment.Top,
        IsHitTestVisible = false,
    };

    public CropRegion Region
    {
        get => region;
        set
        {
            region = value;
            Layout();
            RegionChanged?.Invoke(this, value);
        }
    }

    /// <summary>Bölgeyi olay göndermeden değiştirir (sekme değişirken ayar kaydedilmesin diye).</summary>
    public void ShowRegion(CropRegion value)
    {
        region = value;
        Layout();
    }

    /// <summary>Çeviri başlayınca oyun görüntüsü burada görünür.</summary>
    public Frame? Frame
    {
        set
        {
            preview.Children.Clear();
            aspect = value is { Height: > 0 } ? (double)value.Width / value.Height : 16.0 / 9;
            FitHeight();
            if (value is null)
            {
                preview.Children.Add(new TextBlock
                {
                    Text = Localizer.Current["The game picture appears here once translating starts."],
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    TextAlignment = TextAlignment.Center,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(24),
                    IsHitTestVisible = false,
                    Style = (Style)Application.Current.FindResource("CaptionText"),
                });
            }
            else
            {
                var bitmap = BitmapSource.Create(value.Width, value.Height, 96, 96, PixelFormats.Bgra32, null, value.Pixels, value.Stride);
                preview.Children.Add(new Image { Source = bitmap, Stretch = Stretch.Fill, IsHitTestVisible = false });
            }
            preview.Children.Add(frameBox);
            foreach (var handle in handles) preview.Children.Add(handle);
            Layout();
        }
    }

    // --- Fare ---

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        var point = e.GetPosition(preview);
        anchor = point;
        dragStart = region;
        dragEdges = EdgesAt(point);
        if (dragEdges != Edges.None) drag = Drag.Resize;
        else if (Bounds().Contains(point)) drag = Drag.Move;
        else drag = Drag.Draw;
        preview.CaptureMouse();
        e.Handled = true;
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        var point = e.GetPosition(preview);
        if (drag == Drag.None)
        {
            preview.Cursor = CursorFor(EdgesAt(point), Bounds().Contains(point));
            return;
        }
        if (preview.ActualWidth <= 0 || preview.ActualHeight <= 0) return;
        var (x, y) = (Clamp01(point.X / preview.ActualWidth), Clamp01(point.Y / preview.ActualHeight));
        var (startX, startY) = (Clamp01(anchor.X / preview.ActualWidth), Clamp01(anchor.Y / preview.ActualHeight));

        switch (drag)
        {
            case Drag.Draw:
                region = new CropRegion(Math.Min(startY, y), Math.Max(startY, y), Math.Min(startX, x), Math.Max(startX, x));
                break;
            case Drag.Move:
            {
                var width = dragStart.Right - dragStart.Left;
                var height = dragStart.Bottom - dragStart.Top;
                var left = Math.Clamp(dragStart.Left + (x - startX), 0, 1 - width);
                var top = Math.Clamp(dragStart.Top + (y - startY), 0, 1 - height);
                region = new CropRegion(top, top + height, left, left + width);
                break;
            }
            case Drag.Resize:
            {
                var (top, bottom, left, right) = (dragStart.Top, dragStart.Bottom, dragStart.Left, dragStart.Right);
                if (dragEdges.HasFlag(Edges.Left)) left = Math.Min(x, right - MinSize);
                if (dragEdges.HasFlag(Edges.Right)) right = Math.Max(x, left + MinSize);
                if (dragEdges.HasFlag(Edges.Top)) top = Math.Min(y, bottom - MinSize);
                if (dragEdges.HasFlag(Edges.Bottom)) bottom = Math.Max(y, top + MinSize);
                region = new CropRegion(top, bottom, left, right);
                break;
            }
        }
        Layout();
    }

    private void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (drag == Drag.None) return;
        var finished = drag;
        drag = Drag.None;
        preview.ReleaseMouseCapture();
        // Tıklamak ya da çok küçük çizmek bölgeyi bozmasın: önceki bölge kalır.
        if (finished == Drag.Draw && (region.Right - region.Left < MinSize || region.Bottom - region.Top < MinSize))
            region = dragStart;
        Layout();
        if (region != dragStart) RegionChanged?.Invoke(this, region);
    }

    private static double Clamp01(double value) => Math.Clamp(value, 0, 1);

    /// <summary>Çerçevenin görüntüdeki dikdörtgeni (piksel).</summary>
    private Rect Bounds()
    {
        var (width, height) = (preview.ActualWidth, preview.ActualHeight);
        return new Rect(width * region.Left, height * region.Top, width * (region.Right - region.Left), height * (region.Bottom - region.Top));
    }

    /// <summary>İmleç hangi kenarların yakınında (köşede iki kenar).</summary>
    private Edges EdgesAt(Point point)
    {
        var bounds = Bounds();
        // Çerçevenin dışında, kenardan fazla uzaktaysa hiçbir kenar tutulmaz.
        var near = new Rect(bounds.X - Grab, bounds.Y - Grab, bounds.Width + (2 * Grab), bounds.Height + (2 * Grab));
        if (!near.Contains(point)) return Edges.None;
        var edges = Edges.None;
        if (Math.Abs(point.X - bounds.Left) <= Grab) edges |= Edges.Left;
        else if (Math.Abs(point.X - bounds.Right) <= Grab) edges |= Edges.Right;
        if (Math.Abs(point.Y - bounds.Top) <= Grab) edges |= Edges.Top;
        else if (Math.Abs(point.Y - bounds.Bottom) <= Grab) edges |= Edges.Bottom;
        // Çok küçük bir çerçevede iki kenar üst üste gelebilir; yalnız köşe/kenar yatay ya da dikey olarak tutulur.
        return edges;
    }

    private static Cursor CursorFor(Edges edges, bool inside) => edges switch
    {
        Edges.Left or Edges.Right => Cursors.SizeWE,
        Edges.Top or Edges.Bottom => Cursors.SizeNS,
        Edges.Left | Edges.Top or Edges.Right | Edges.Bottom => Cursors.SizeNWSE,
        Edges.Right | Edges.Top or Edges.Left | Edges.Bottom => Cursors.SizeNESW,
        _ => inside ? Cursors.SizeAll : Cursors.Cross,
    };

    /// <summary>Önizlemenin boyu, genişliğe ve görüntünün oranına göre ayarlanır.</summary>
    private void FitHeight()
    {
        if (ActualWidth <= 0) return;
        var height = Math.Max(120, ActualWidth / aspect);
        if (Math.Abs(preview.Height - height) > 0.5) preview.Height = height;
    }

    private void Layout()
    {
        var bounds = Bounds();
        frameBox.Margin = new Thickness(bounds.X, bounds.Y, 0, 0);
        frameBox.Width = Math.Max(0, bounds.Width);
        frameBox.Height = Math.Max(0, bounds.Height);
        var corners = new[] { new Point(bounds.Left, bounds.Top), new Point(bounds.Right, bounds.Top), new Point(bounds.Left, bounds.Bottom), new Point(bounds.Right, bounds.Bottom) };
        for (var i = 0; i < handles.Length; i++)
            handles[i].Margin = new Thickness(corners[i].X - 5, corners[i].Y - 5, 0, 0);
    }
}
