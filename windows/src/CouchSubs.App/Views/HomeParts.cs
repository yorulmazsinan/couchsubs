// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using CouchSubs.App.Controls;
using CouchSubs.App.Theme;
using CouchSubs.Core;
using CouchSubs.Shell;
using Frame = CouchSubs.Core.Frame;

namespace CouchSubs.App.Views;

// Ana ekranın parçaları (tuval 09): durum çipi, oyun görüntüsü önizlemesi ve durum karolarının küçük grafikleri.

/// <summary>Durum çipi: solda durum simgesi (yeşil tik, kırmızı ünlem ya da gri nokta), ad, değer ve mono ek bilgi.</summary>
public sealed class StatusChip : Border
{
    private readonly Border badge = new() { Width = 24, Height = 24, CornerRadius = new CornerRadius(12), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock label = new() { FontSize = 12, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock value = new() { FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly System.Windows.Documents.Run extra = new();

    public StatusChip()
    {
        Height = 56;
        Padding = Sp.T("m", "0", "m", "0");
        CornerRadius = new CornerRadius(16);
        label.SetResourceReference(TextBlock.ForegroundProperty, "textSecondaryBrush");
        extra.FontFamily = (FontFamily)Application.Current.FindResource("MonoFont");
        extra.FontSize = 12;
        extra.FontWeight = FontWeights.Medium;
        extra.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "textSecondaryBrush");
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = Sp.T("s", "0", "0", "0") };
        texts.Children.Add(label);
        texts.Children.Add(value);
        var row = new DockPanel();
        DockPanel.SetDock(badge, Dock.Left);
        row.Children.Add(badge);
        row.Children.Add(texts);
        Child = row;
        Show("", "", null, StatusTone.Idle);
    }

    /// <summary>Çipi doldurur; <paramref name="more"/> mono ek bilgidir ("EN→TR", "Paket"), yoksa gösterilmez.</summary>
    public void Show(string name, string text, string? more, StatusTone tone)
    {
        label.Text = name;
        value.Inlines.Clear();
        value.Inlines.Add(new System.Windows.Documents.Run(text));
        if (!string.IsNullOrEmpty(more))
        {
            extra.Text = " " + more;
            value.Inlines.Add(extra);
        }
        value.ToolTip = string.IsNullOrEmpty(more) ? text : $"{text} · {more}";
        badge.SetResourceReference(Border.BackgroundProperty, tone switch
        {
            StatusTone.Good => "successSoftBrush",
            StatusTone.Warning => "liveSoftBrush",
            _ => "surface2Brush",
        });
        badge.Child = tone switch
        {
            StatusTone.Good => Mark("M6,12.5 L10,16.5 L18,8", "successBrush"),
            StatusTone.Warning => Mark("M12,6 L12,13 M12,17.5 L12,18", "liveBrush"),
            _ => Dot(),
        };
    }

    private static Path Mark(string data, string brush)
    {
        var path = new Path
        {
            Data = Geometry.Parse(data), StrokeThickness = 2.8, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round, Width = 14, Height = 14, Stretch = Stretch.Uniform,
        };
        path.SetResourceReference(Shape.StrokeProperty, brush);
        return path;
    }

    private static Ellipse Dot()
    {
        var dot = new Ellipse { Width = 8, Height = 8 };
        dot.SetResourceReference(Shape.FillProperty, "textTertiaryBrush");
        return dot;
    }
}

/// <summary>İçeriği sığan en büyük 16:9 dikdörtgene yerleştirir (oyun görüntüsü hep 16:9).</summary>
public sealed class AspectBox : Decorator
{
    public double Ratio { get; set; } = 16.0 / 9.0;

    private Size Fit(Size available)
    {
        var width = double.IsInfinity(available.Width) ? available.Height * Ratio : available.Width;
        var height = width / Ratio;
        if (!double.IsInfinity(available.Height) && height > available.Height)
        {
            height = available.Height;
            width = height * Ratio;
        }
        return double.IsNaN(width) || double.IsInfinity(width) ? new Size(0, 0) : new Size(width, height);
    }

    protected override Size MeasureOverride(Size constraint)
    {
        var size = Fit(constraint);
        Child?.Measure(size);
        return size;
    }

    protected override Size ArrangeOverride(Size arrangeSize)
    {
        var size = Fit(arrangeSize);
        Child?.Arrange(new Rect((arrangeSize.Width - size.Width) / 2, (arrangeSize.Height - size.Height) / 2, size.Width, size.Height));
        return arrangeSize;
    }
}

/// <summary>
/// Oyun görüntüsü önizlemesi: 6 px gri çerçeve, 16 köşe; solda üstte CANLI / DURDU hapı, sağ üstte kare hızı, okunan alan
/// amber kesikli çerçeve ("Okunan Alan"), görüntünün üstünde son çeviri (konuşanın adı amber). Kare yoksa sahne renkleri.
/// Kare saniyede en çok 4 kez çizilir (WriteableBitmap yeniden kullanılır).
/// </summary>
public sealed class GamePreview : ContentControl
{
    private readonly Image image = new() { Stretch = Stretch.Fill };
    private readonly Grid stage = new() { ClipToBounds = true };
    private readonly TextBlock liveText = new() { FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
    private readonly Ellipse liveDot = new() { Width = 7, Height = 7, Fill = new SolidColorBrush(Color.FromRgb(0xFF, 0x5A, 0x5A)), Margin = Sp.T("0", "0", "xs", "0") };
    private readonly Border rateChip;
    private readonly TextBlock rateText = new() { FontSize = 11, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border area = new() { BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(10) };
    private readonly Rectangle areaDash = new() { StrokeThickness = 2, StrokeDashArray = [4, 3], RadiusX = 10, RadiusY = 10 };
    private readonly Border lineBox = new()
    {
        Background = new SolidColorBrush(Color.FromArgb(0xD9, 0x10, 0x10, 0x14)), CornerRadius = new CornerRadius(12), Padding = Sp.T("m", "s", "m", "s"),
        VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed,
    };
    private readonly TextBlock lineText = new() { FontSize = 17, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, TextAlignment = TextAlignment.Center };
    private WriteableBitmap? bitmap;
    private long lastDraw;
    private CropRegion region = new();

    public GamePreview()
    {
        var frame = new Border();
        frame.SetResourceReference(StyleProperty, "DeviceFrame");
        frame.Background = Scene();
        stage.Children.Add(image);
        // Alt kısım hafif kararır (tasarım: degrade).
        stage.Children.Add(new Border
        {
            Background = new LinearGradientBrush(new GradientStopCollection { new(Color.FromArgb(0, 0, 0, 0), 0.4), new(Color.FromArgb(0x59, 0, 0, 0), 1) }, 90),
            IsHitTestVisible = false,
        });
        areaDash.SetResourceReference(Shape.StrokeProperty, "accentBrush");
        var areaLabel = new Border { Height = 22, Padding = Sp.T("xs", "0", "xs", "0"), CornerRadius = new CornerRadius(11), HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top, Margin = Sp.T("s", "-s", "0", "0") };
        areaLabel.SetResourceReference(Border.BackgroundProperty, "accentBrush");
        var areaLabelText = new TextBlock { Text = Localizer.Current["Area Read"], FontSize = 11, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        areaLabelText.SetResourceReference(TextBlock.ForegroundProperty, "onAccentBrush");
        areaLabel.Child = areaLabelText;
        var areaGrid = new Grid();
        areaGrid.Children.Add(areaDash);
        areaGrid.Children.Add(areaLabel);
        area.Child = areaGrid;
        area.HorizontalAlignment = HorizontalAlignment.Left;
        area.VerticalAlignment = VerticalAlignment.Top;
        area.Loaded += (_, _) => Motion.SetPulse(areaDash, true);
        stage.Children.Add(area);
        lineBox.Child = lineText;
        stage.Children.Add(lineBox);
        // CANLI hapı ve kare hızı sağ üstte yan yana (Mac: örnek karenin sol üstündeki görev yazısıyla çakışmasın).
        var live = Chip(new StackPanel { Orientation = Orientation.Horizontal, Children = { liveDot, liveText } });
        rateText.FontFamily = (FontFamily)Application.Current.FindResource("MonoFont");
        rateChip = Chip(rateText);
        rateChip.Margin = Sp.T("xs", "0", "0", "0");
        stage.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = Sp.T("s"), Children = { live, rateChip },
        });
        stage.SizeChanged += (_, _) => Layout();
        frame.Child = stage;
        Content = new AspectBox { Child = frame };
        SetLive(false);
    }

    private static Border Chip(UIElement content)
    {
        var chip = new Border { Child = content, VerticalAlignment = VerticalAlignment.Top };
        chip.SetResourceReference(StyleProperty, "SceneChip");
        return chip;
    }

    /// <summary>Kare yokken tasarımdaki sahne renkleri.</summary>
    private static Brush Scene()
    {
        var group = new DrawingBrush { Stretch = Stretch.Fill };
        var drawing = new DrawingGroup();
        drawing.Children.Add(new GeometryDrawing(new SolidColorBrush(Color.FromRgb(0x6D, 0x6A, 0x5D)), null, new RectangleGeometry(new Rect(0, 0, 160, 90))));
        drawing.Children.Add(new GeometryDrawing(Glow(Color.FromRgb(0x7A, 0x8A, 0x6A)), null, new EllipseGeometry(new Point(48, 32), 56, 32)));
        drawing.Children.Add(new GeometryDrawing(Glow(Color.FromRgb(0xC7, 0x9A, 0x62)), null, new EllipseGeometry(new Point(120, 27), 48, 27)));
        // Parıltılar 16:9 alanın dışına taşmasın (taşarsa fırça büyür, kenarlarda boşluk kalır).
        drawing.ClipGeometry = new RectangleGeometry(new Rect(0, 0, 160, 90));
        group.Drawing = drawing;
        group.Freeze();
        return group;
    }

    private static RadialGradientBrush Glow(Color color) =>
        new(new GradientStopCollection { new(color, 0), new(Color.FromArgb(0, color.R, color.G, color.B), 1) });

    /// <summary>Çeviri sürüyorsa CANLI (atan nokta), yoksa DURDU.</summary>
    public void SetLive(bool live)
    {
        liveText.Text = Localizer.Current[live ? "LIVE" : "STOPPED"];
        liveDot.Visibility = live ? Visibility.Visible : Visibility.Collapsed;
        if (live) Motion.SetPulse(liveDot, true);
    }

    /// <summary>Sağ üstteki mono bilgi ("PS5 · 10 Kare/sn"); boşsa gizli.</summary>
    public void SetRate(string? text)
    {
        rateText.Text = text ?? "";
        rateChip.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>Son çeviri (konuşanın adı amber); boşsa kutu gizli.</summary>
    public void SetLine(string? line)
    {
        lineText.Inlines.Clear();
        if (string.IsNullOrWhiteSpace(line))
        {
            lineBox.Visibility = Visibility.Collapsed;
            return;
        }
        if (SpeakerPrefix.Parse(line) is { } prefix)
        {
            var name = new System.Windows.Documents.Run(prefix.Name + ":");
            name.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "accentBrush");
            lineText.Inlines.Add(name);
            lineText.Inlines.Add(new System.Windows.Documents.Run(" " + prefix.Body));
        }
        else lineText.Inlines.Add(new System.Windows.Documents.Run(line));
        lineBox.Visibility = Visibility.Visible;
        Motion.EnterFrom(lineBox, -8);
    }

    public void SetRegion(CropRegion value)
    {
        region = value;
        Layout();
    }

    /// <summary>Kareyi çizer (saniyede en çok 4 kez); null ise sahne renkleri görünür.</summary>
    public void SetFrame(Frame? frame)
    {
        if (frame is null)
        {
            image.Source = null;
            bitmap = null;
            return;
        }
        var now = Environment.TickCount64;
        if (now - lastDraw < 250 && image.Source is not null) return;
        lastDraw = now;
        if (bitmap is null || bitmap.PixelWidth != frame.Width || bitmap.PixelHeight != frame.Height)
            bitmap = new WriteableBitmap(frame.Width, frame.Height, 96, 96, PixelFormats.Bgr32, null);
        bitmap.WritePixels(new Int32Rect(0, 0, frame.Width, frame.Height), frame.Pixels, frame.Stride, 0);
        image.Source = bitmap;
    }

    private void Layout()
    {
        var width = stage.ActualWidth;
        var height = stage.ActualHeight;
        if (width <= 0 || height <= 0) return;
        area.Margin = new Thickness(width * region.Left, height * region.Top, 0, 0);
        area.Width = Math.Max(0, width * (region.Right - region.Left));
        area.Height = Math.Max(0, height * (region.Bottom - region.Top));
        lineBox.Margin = new Thickness(width * 0.15, height * 0.34, width * 0.15, 0);
    }
}

/// <summary>Satır kıvılcım çizgisi: amber çizgi, altında solan dolgu, sonda nokta (tasarım: Durum › Satır).</summary>
public sealed class Sparkline : FrameworkElement
{
    private IReadOnlyList<double> values = [];

    public Sparkline() => ThemeManager.Changed += InvalidateVisual;

    public IReadOnlyList<double> Values
    {
        get => values;
        set
        {
            values = value;
            InvalidateVisual();
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (values.Count < 2 || ActualWidth <= 0 || ActualHeight <= 0) return;
        var max = Math.Max(1, values.Max());
        var points = values.Select((v, i) => new Point(i * ActualWidth / (values.Count - 1), ActualHeight - 4 - v / max * (ActualHeight - 8))).ToList();
        var line = new StreamGeometry();
        using (var ctx = line.Open())
        {
            ctx.BeginFigure(points[0], false, false);
            ctx.PolyLineTo(points.Skip(1).ToList(), true, true);
        }
        var fill = new StreamGeometry();
        using (var ctx = fill.Open())
        {
            ctx.BeginFigure(new Point(0, ActualHeight), true, true);
            ctx.PolyLineTo(points.Append(new Point(ActualWidth, ActualHeight)).ToList(), false, true);
        }
        var accent = (Color)(TryFindResource("accentColor") ?? Colors.Orange);
        var deep = (Color)(TryFindResource("accentDeepColor") ?? Colors.DarkOrange);
        dc.DrawGeometry(new LinearGradientBrush(Color.FromArgb(0x59, accent.R, accent.G, accent.B), Color.FromArgb(0, accent.R, accent.G, accent.B), 90), null, fill);
        dc.DrawGeometry(null, new Pen(new SolidColorBrush(deep), 1.6) { LineJoin = PenLineJoin.Round, StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, line);
        dc.DrawEllipse(new SolidColorBrush(deep), null, points[^1], 2.4, 2.4);
    }
}

/// <summary>Halka gösterge (paketten gelen satırların oranı).</summary>
public sealed class Ring : FrameworkElement
{
    private double fraction;

    public Ring() => ThemeManager.Changed += InvalidateVisual;

    public double Fraction
    {
        get => fraction;
        set
        {
            fraction = Math.Clamp(value, 0, 1);
            InvalidateVisual();
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        var size = Math.Min(ActualWidth, ActualHeight);
        if (size <= 0) return;
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        var radius = size / 2 - 4;
        var track = new Pen((Brush)(TryFindResource("borderBrush") ?? Brushes.LightGray), 5);
        dc.DrawEllipse(null, track, center, radius, radius);
        if (fraction <= 0) return;
        var pen = new Pen((Brush)(TryFindResource("accentDeepBrush") ?? Brushes.Orange), 5) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        if (fraction >= 0.999)
        {
            dc.DrawEllipse(null, pen, center, radius, radius);
            return;
        }
        var angle = fraction * 2 * Math.PI;
        var start = new Point(center.X, center.Y - radius);
        var end = new Point(center.X + radius * Math.Sin(angle), center.Y - radius * Math.Cos(angle));
        var arc = new StreamGeometry();
        using (var ctx = arc.Open())
        {
            ctx.BeginFigure(start, false, false);
            ctx.ArcTo(end, new Size(radius, radius), 0, fraction > 0.5, SweepDirection.Clockwise, true, true);
        }
        dc.DrawGeometry(null, pen, arc);
    }
}

/// <summary>Son gecikmelerin çubukları (en yenisi koyu).</summary>
public sealed class Bars : FrameworkElement
{
    private IReadOnlyList<double> values = [];

    public Bars() => ThemeManager.Changed += InvalidateVisual;

    public IReadOnlyList<double> Values
    {
        get => values;
        set
        {
            values = value;
            InvalidateVisual();
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (values.Count == 0 || ActualWidth <= 0) return;
        const double gap = 3;
        var width = (ActualWidth - gap * (values.Count - 1)) / values.Count;
        var max = Math.Max(1, values.Max());
        var normal = (Brush)(TryFindResource("scrollThumbBrush") ?? Brushes.LightGray);
        var last = (Brush)(TryFindResource("charcoalBrush") ?? Brushes.Black);
        for (var i = 0; i < values.Count; i++)
        {
            var height = Math.Max(4, values[i] / max * ActualHeight);
            var rect = new Rect(i * (width + gap), ActualHeight - height, Math.Max(1, width), height);
            dc.DrawRoundedRectangle(i == values.Count - 1 ? last : normal, null, rect, 2, 2);
        }
    }
}
