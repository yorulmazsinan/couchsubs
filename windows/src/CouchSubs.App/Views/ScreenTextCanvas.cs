// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using CouchSubs.Core;

namespace CouchSubs.App.Views;

/// <summary>
/// Ekran yazısı blokları oyun karesindeki kendi yerlerinde (yayın penceresi 16:9 karenin kendisidir), TV ve Mac ile aynı
/// yerleşimle (<see cref="ScreenFit.Layout"/>; Mac StreamWindow ScreenTextBlocks): yazı boyu satır yüksekliğinin 0,95'i; kutu
/// özgün yazının genişliğinde kalır, yana hiç genişlemez. Türkçe uzunsa önce yatayda biraz sıkışır, sonra küçülür, sonra satır
/// kırılıp kutu aşağı uzar; kenar payı yalnız bilgisayarın verdiği alanda (<c>Room</c>), yandaki tuş simgesine binmez. Altyazıyla çakışan kutu yalnız gerektiği
/// kadar yukarı ya da aşağı kayar. Önceden Windows'ta bu çeviriler pencerenin üstünde alt alta, hizalı bir liste olarak
/// çiziliyordu.
/// <para>
/// Kareden ölçülmüş öğe (<see cref="ScreenTranslation.Item.Paint"/>) yerinde birebir çizilir (<see cref="ScreenFit.Exact"/>;
/// TV fitExact ve Mac ScreenTextBlocks ile aynı yerleşim): opak, köşesiz, gölgesiz kutu tam örtü sınırında, ölçülen zeminle
/// (düz ya da yatay/dikey degrade), yazı özgün renk, kalınlık ve hizayla; her satır özgün satır aralığında. Ölçüsü olmayan
/// öğe eski yoldan çizilir.
/// </para>
/// <para>
/// Çizim kipi (<see cref="TextPaint.Mode"/>; TV placeExact ve Mac ExactScreenText ile aynı): örtmede kutu; yanına yazmada
/// kutu yok, Türkçe özgün yazının yanında özgün stille, okunurluk için yumuşak gölgeyle; ikizde özgün kutunun aynı boydaki
/// kopyası (aynı zemin, kenar çizgisi, köşe, kuyruk ve kişi resmi; Türkçe uzunsa sağa ve aşağı uzar) bilgisayarın verdiği
/// yerde (yan, alt ya da üst), yazı kutusuz.
/// </para>
/// <para>
/// Dar aile (özgün yazı dar; konuşma satırı hiç dar çizilmez, <see cref="ScreenFit.IsDialogue(string, int)"/>) yerinde
/// birebir çizimde gömülü Barlow Condensed'tir (Fonts/, SIL OFL 1.1): ölçü ve çizim aynı yazı tipiyle, Mac ve TV ile aynı
/// genişlikte.
/// </para>
/// </summary>
internal sealed class ScreenTextCanvas : Canvas
{
    private static readonly FontFamily Condensed = new("Arial Narrow, Segoe UI");
    private static readonly FontFamily Normal = new("Segoe UI");
    /// <summary>Yerinde birebir çizimin gömülü dar ailesi (Fonts/BarlowCondensed-Medium.ttf, -Bold.ttf); yüklenemezse Arial Narrow.</summary>
    private static readonly FontFamily ExactCondensed =
        new(new Uri("pack://application:,,,/"), "./Fonts/#Barlow Condensed, ./Fonts/#Barlow Condensed Medium, Arial Narrow, Segoe UI");
    private static readonly CultureInfo Turkish = CultureInfo.GetCultureInfo("tr-TR");

    private IReadOnlyList<ScreenTranslation.Item> items = [];
    private Rect? avoiding;

    public ScreenTextCanvas()
    {
        IsHitTestVisible = false;
        ClipToBounds = true;
        SizeChanged += (_, _) => Layout();
    }

    /// <summary>Kendi yerinde çizilecek öğe: özgün stilli, telefon kartının/panelinin parçası değil.</summary>
    public static bool Draws(ScreenTranslation.Item item) =>
        item.Look is not null && item.Panel is null && !ScreenPhoneCard.IsBackdrop(item) && item.Translation.Length > 0;

    /// <param name="subtitles">Altyazı satırlarının yeri (bu katmanın koordinatında); kutu onunla çakışmaz.</param>
    public void Show(IReadOnlyList<ScreenTranslation.Item> blocks, Rect? subtitles)
    {
        items = blocks;
        avoiding = subtitles;
        Layout();
    }

    /// <summary>Kutunun üst kenarı (Mac ScreenTextBlocks.top ile aynı kural, en az %0,6 ekran yüksekliği boşluk).</summary>
    internal static double Top(Rect rect, Rect? avoiding, double height)
    {
        var gap = height * 0.006;
        if (avoiding is not { } other) return rect.Top;
        var grown = new Rect(other.X, other.Y - gap, other.Width, other.Height + (2 * gap));
        if (!rect.IntersectsWith(grown)) return rect.Top;
        var up = other.Top - gap - rect.Height;
        var down = other.Bottom + gap;
        bool upFits = up >= 0, downFits = down + rect.Height <= height;
        if (upFits && (!downFits || rect.Top - up <= down - rect.Top)) return up;
        if (downFits) return down;
        return Math.Max(0, up);
    }

    private void Layout()
    {
        Children.Clear();
        double width = ActualWidth, height = ActualHeight;
        if (width <= 0 || height <= 0) return;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var drawn = items.Where(Draws).ToList();
        LayoutExact([.. drawn.Where(item => item.Paint is not null)], width, height, dpi);
        foreach (var item in drawn.Where(item => item.Paint is null))
        {
            var look = item.Look!;
            var surface = item.Style ?? TextStyleSampler.Neutral;
            var line = Math.Max(1, item.LineHeight * height);
            var baseSize = line * 0.95;
            var pad = line * 0.15;
            var boxHeight = Math.Max(0, item.Box.Bottom - item.Box.Top) * height;
            var family = look.Condensed ? Condensed : Normal;
            var weight = look.Bold ? FontWeights.Bold : FontWeights.SemiBold;
            var typeface = new Typeface(family, FontStyles.Normal, weight, FontStretches.Normal);
            var translation = look.Upper ? item.Translation.ToUpper(Turkish) : item.Translation;
            double Measure(string text) =>
                new FormattedText(text, Turkish, FlowDirection.LeftToRight, typeface, baseSize, Brushes.White, dpi).WidthIncludingTrailingWhitespace;
            double left = item.Box.Left * width, boxWidth = Math.Max(1, item.Box.Right - item.Box.Left) * width;
            var fit = ScreenFit.Layout(translation, boxWidth, item.Rows, Measure, ScreenFit.Floor(baseSize, height));
            var fontSize = baseSize * fit.Scale;
            // Kenar payı yalnız bilgisayarın verdiği alanda: yandaki tuş simgesinin üstüne binmez (#1203).
            var side = ScreenFit.Pads(left, boxWidth, item.Room is { } room ? (room.Left * width, room.Right * width) : null, pad);
            var pitch = Math.Max(boxHeight / Math.Max(1, fit.Rows.Count), fontSize * 1.05);
            var alignment = look.Align switch { "center" => HorizontalAlignment.Center, "right" => HorizontalAlignment.Right, _ => HorizontalAlignment.Left };
            var origin = look.Align switch { "center" => 0.5, "right" => 1.0, _ => 0.0 };
            var stack = new StackPanel { Width = boxWidth, MinHeight = boxHeight, VerticalAlignment = VerticalAlignment.Center };
            foreach (var text in fit.Rows)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = text,
                    FontFamily = family,
                    FontWeight = weight,
                    FontSize = fontSize,
                    Foreground = new SolidColorBrush(Parse(surface.Foreground, Colors.White)),
                    TextWrapping = TextWrapping.NoWrap,
                    Height = pitch,
                    HorizontalAlignment = alignment,
                    RenderTransformOrigin = new Point(origin, 0.5),
                    RenderTransform = new ScaleTransform(fit.Squeeze, 1),
                });
            }
            var block = new Border
            {
                Background = new SolidColorBrush(Parse(surface.Background, Colors.Black)),
                CornerRadius = new CornerRadius(look.Flat ? 0 : pad),
                Padding = new Thickness(side.Left, pad, side.Right, pad),
                Child = stack,
            };
            var rect = new Rect(left - side.Left, (item.Box.Top * height) - pad, boxWidth + side.Left + side.Right, boxHeight + (2 * pad));
            SetLeft(block, left - side.Left);
            SetTop(block, Top(rect, avoiding, height));
            Children.Add(block);
        }
    }

    /// <summary>
    /// Yerinde birebir çizim: bütün ölçülü öğeler birlikte yerleşir (grup aynı yazı boyunda), ölçü bu katmanın kendi yazı
    /// tipiyle alınır.
    /// </summary>
    private void LayoutExact(IReadOnlyList<ScreenTranslation.Item> painted, double width, double height, double dpi)
    {
        if (painted.Count == 0) return;
        var typefaces = painted.Select(item =>
        {
            // Konuşma satırı dar aileyle çizilmez (ScreenStyleLock ile aynı kural, #1255).
            var condensed = item.Look!.Condensed
                && !ScreenFit.IsDialogue(item.Translation, item.Paragraphs ? Math.Max(2, item.Rows) : item.Rows);
            return new Typeface(condensed ? ExactCondensed : Normal, FontStyles.Normal,
                item.Look.Bold ? FontWeights.Bold : condensed ? FontWeights.Medium : FontWeights.Normal, FontStretches.Normal);
        }).ToList();
        var texts = painted.Select(item => item.Look!.Upper ? item.Translation.ToUpper(Turkish) : item.Translation).ToList();
        var inputs = painted.Select((item, i) => ScreenFit.ExactInput.From(item, width, height)! with { Text = texts[i] }).ToList();
        // Her öğe kendi yazı tipiyle ölçülür. Grup aynı boyda kalsın diye bütün öğeler birlikte yerleşir; her yazı tipi
        // (dar/normal, kalın/normal) için bir kez, o yazı tipindeki öğelerin sonucu alınır.
        var placements = new ScreenFit.ExactPlacement[painted.Count];
        foreach (var kind in Enumerable.Range(0, painted.Count).GroupBy(i => (typefaces[i].FontFamily, typefaces[i].Weight)))
        {
            var typeface = typefaces[kind.First()];
            double Measure(string text, double size) =>
                new FormattedText(text, Turkish, FlowDirection.LeftToRight, typeface, Math.Max(0.1, size), Brushes.White, dpi)
                    .WidthIncludingTrailingWhitespace;
            var laid = ScreenFit.Exact(inputs, Measure);
            foreach (var i in kind) placements[i] = laid[i];
        }
        // İkiz paneller önce (yazılar üstlerinde): aynı paneli paylaşan öğeler (başlık ve gövde) tek panel çizer.
        var twins = Enumerable.Range(0, painted.Count)
            .Where(i => painted[i].Paint is { Mode: PaintMode.Twin, Twin: not null })
            .GroupBy(i => painted[i].Paint!.Twin!.Value);
        foreach (var twin in twins) DrawTwin([.. twin], painted, placements, width, height);
        for (var i = 0; i < painted.Count; i++)
        {
            var item = painted[i];
            var paint = item.Paint!;
            var place = placements[i];
            // Menüde yanına yazılan Türkçenin etiketi (TextPaint.Label, MenuLayout; TV 0.9.124 ile aynı): koyu, yarı saydam,
            // yuvarlak köşeli; yazının çevresine taşar, yazı etikette açık renkle ve kontursuz.
            var label = paint.Mode == PaintMode.Beside && Parse(paint.Label, Colors.Transparent) is var chip && chip != Colors.Transparent
                ? chip : (Color?)null;
            var ink = Parse(item.Style?.Foreground, Colors.White);
            // Seçili (ters renkli: açık zemin, koyu ve zeminden belirgin biçimde ayrışan yazı) satırın etiketi de ters renkli
            // (TV labelSelected ile aynı).
            static double LabelLuma(Color c) => 0.299 * c.R + 0.587 * c.G + 0.114 * c.B;
            var ground = Parse(paint.Background, Colors.Black);
            var selected = label is not null && LabelLuma(ground) > 160 && LabelLuma(ink) <= 160 && LabelLuma(ground) - LabelLuma(ink) >= 80;
            if (selected) label = ground;
            var foreground = new SolidColorBrush(label is null || selected || 0.299 * ink.R + 0.587 * ink.G + 0.114 * ink.B > 150
                ? ink : Color.FromRgb(0xF2, 0xF2, 0xF2));
            if (label is { } fill)
            {
                // Etiket yazıyı sarar: genişliği en uzun satır kadar, özgüne yaslı kenarı yerinde.
                var pad = Math.Max(2, Math.Round(place.FontSize * 0.2, MidpointRounding.AwayFromZero));
                var padY = Math.Max(1, Math.Round(place.FontSize * 0.06, MidpointRounding.AwayFromZero));
                var tight = Math.Min(place.Width, place.Lines.Count == 0 ? place.Width : place.Lines.Max(line =>
                    new FormattedText(line, Turkish, FlowDirection.LeftToRight, typefaces[i], Math.Max(0.1, place.FontSize), Brushes.White, dpi)
                        .WidthIncludingTrailingWhitespace));
                var chipLeft = inputs[i].Align switch
                {
                    "right" => place.Left + place.Width - tight,
                    "center" => place.Left + (place.Width - tight) / 2,
                    _ => place.Left,
                };
                var chipBox = new Border
                {
                    Width = Math.Max(1, tight + 2 * pad),
                    Height = Math.Max(1, place.Height + 2 * padY),
                    Background = new SolidColorBrush(Color.FromArgb(219, fill.R, fill.G, fill.B)),
                    CornerRadius = new CornerRadius(Math.Max(2, Math.Round(pad * 0.8, MidpointRounding.AwayFromZero))),
                };
                SetLeft(chipBox, chipLeft - pad);
                SetTop(chipBox, place.Top - padY);
                Children.Add(chipBox);
            }
            if (paint.Mode == PaintMode.Cover)
            {
                var box = new Border
                {
                    Width = Math.Max(1, place.Width),
                    Height = Math.Max(1, place.Height),
                    Background = Ground(paint),
                    CornerRadius = new CornerRadius(0),
                };
                SetLeft(box, place.Left);
                SetTop(box, place.Top);
                Children.Add(box);
            }
            // Yanına yazma: oyun dünyasının üstünde kutusuz; yazı rengine zıt yumuşak gölge okunurluğu sağlar.
            var glow = paint.Mode == PaintMode.Beside && label is null
                ? new DropShadowEffect { ShadowDepth = 0, BlurRadius = Math.Max(3, place.FontSize * 0.25), Opacity = 0.9,
                                         Color = Light(Parse(item.Style?.Foreground, Colors.White)) ? Colors.Black : Colors.White }
                : null;
            var alignment = inputs[i].Align switch { "center" => HorizontalAlignment.Center, "right" => HorizontalAlignment.Right, _ => HorizontalAlignment.Left };
            for (var k = 0; k < place.Lines.Count; k++)
            {
                // Satır, özgün satırın yerinde: RowHeight yüksekliğin dikey ortasında, k. satır Top + k * LineHeight'ta.
                var row = new Border
                {
                    Width = Math.Max(1, place.Width),
                    Height = Math.Max(1, place.RowHeight),
                    Child = new TextBlock
                    {
                        Text = place.Lines[k],
                        FontFamily = typefaces[i].FontFamily,
                        FontWeight = typefaces[i].Weight,
                        FontSize = Math.Max(0.1, place.FontSize),
                        Foreground = foreground,
                        TextWrapping = TextWrapping.NoWrap,
                        HorizontalAlignment = alignment,
                        VerticalAlignment = VerticalAlignment.Center,
                        Effect = glow,
                    },
                };
                SetLeft(row, place.Left);
                SetTop(row, place.Top + (k * place.LineHeight));
                Children.Add(row);
            }
        }
    }

    /// <summary>
    /// İkiz panel: özgün kutunun aynı boydaki kopyası (zemin rengi, kenar çizgisi, köşe yarıçapı, konuşma balonunun kuyruğu,
    /// kişi resmi); sol kenarı ve üstü bilgisayarın verdiği yerde. Genişlik ve yükseklik en az özgün kadar, Türkçe uzunsa
    /// içeriğe göre uzar (sağ iç boşluk soldakine, alt iç boşluk özgündekine eşit). Kenar çizgisi kutunun dışında, her yanda
    /// kendi kalınlığında (TV exactEdge ile aynı).
    /// </summary>
    private void DrawTwin(IReadOnlyList<int> members, IReadOnlyList<ScreenTranslation.Item> painted,
                          IReadOnlyList<ScreenFit.ExactPlacement> placements, double width, double height)
    {
        var paint = painted[members[0]].Paint!;
        var twin = paint.Twin!.Value;
        double left = twin.Left * width, top = twin.Top * height, bottom = twin.Bottom * height;
        var pad = Math.Max(0, members.Min(i => placements[i].Left) - left);
        var face = members.Select(i => painted[i].Paint!).FirstOrDefault(p => p.PortraitTwin is not null && p.PortraitImage is not null);
        var right = members.Max(i => placements[i].Left + placements[i].Width);
        if (face?.PortraitTwin is { } at) right = Math.Max(right, at.Right * width);
        var spotBottom = members.Max(i => painted[i].Paint!.Spot is { } spot ? spot.Bottom * height : bottom);
        bottom = Math.Max(bottom, members.Max(i => placements[i].Top + placements[i].Height) + Math.Max(0, bottom - spotBottom));
        var radius = Math.Max(0, paint.Radius * height);
        var panelWidth = Math.Max(Math.Max(2 * radius, (twin.Right - twin.Left) * width), right + pad - left);
        var fill = new SolidColorBrush(Parse(paint.Background, Colors.LightGray));
        // Kenar çizgisi: kare yüksekliğine oranlı kalınlık, en az 1 piksel (TV exactEdge ile aynı yuvarlama); kutunun dışında.
        double Thick(double value) => value > 0 ? Math.Max(1, Math.Round(value * height, MidpointRounding.AwayFromZero)) : 0;
        var edge = new Thickness(0);
        Brush? edgeBrush = null;
        if (paint.Edge is { } line && Parse(line.Color, Colors.Transparent) is var color && color != Colors.Transparent)
        {
            edge = new Thickness(Thick(line.Left), Thick(line.Top), Thick(line.Right), Thick(line.Bottom));
            edgeBrush = new SolidColorBrush(color);
        }
        var panel = new Border
        {
            Width = panelWidth + edge.Left + edge.Right,
            Height = Math.Max(1, bottom - top) + edge.Top + edge.Bottom,
            Background = fill,
            BorderBrush = edgeBrush,
            BorderThickness = edge,
            CornerRadius = new CornerRadius(radius, radius, paint.Tail == "right" ? 0 : radius, paint.Tail == "left" ? 0 : radius),
        };
        SetLeft(panel, left - edge.Left);
        SetTop(panel, top - edge.Top);
        Children.Add(panel);
        bottom += edge.Bottom;
        if (paint.Tail is "left" or "right")
        {
            // Kuyruk: köşeli köşeden aşağı doğru küçük üçgen.
            var x = paint.Tail == "left" ? left : left + panelWidth;
            var dx = paint.Tail == "left" ? radius : -radius;
            Children.Add(new Polygon
            {
                Fill = fill,
                Points = [new Point(x, bottom - 1), new Point(x + dx, bottom - 1), new Point(x, bottom + (0.6 * radius))],
            });
        }
        if (face?.PortraitTwin is { } box && Picture(face.PortraitImage!) is { } image)
        {
            double w = (box.Right - box.Left) * width, h = (box.Bottom - box.Top) * height;
            var picture = new Image
            {
                Source = image, Width = w, Height = h, Stretch = Stretch.Fill,
                // Görev kartının resmi köşeli kare (TV ile aynı), telefon bildiriminin kişi resmi yuvarlak.
                Clip = face.PortraitSquare ? null : new EllipseGeometry(new Point(w / 2, h / 2), w / 2, h / 2),
            };
            SetLeft(picture, box.Left * width);
            SetTop(picture, box.Top * height);
            Children.Add(picture);
        }
    }

    /// <summary>Kişi resmi (PNG data: adresi); çözülemezse null.</summary>
    private static BitmapImage? Picture(string source)
    {
        const string prefix = "data:image/png;base64,";
        if (!source.StartsWith(prefix, StringComparison.Ordinal)) return null;
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = new System.IO.MemoryStream(Convert.FromBase64String(source[prefix.Length..]));
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static bool Light(Color color) => (0.299 * color.R) + (0.587 * color.G) + (0.114 * color.B) > 140;

    /// <summary>Ölçülen zemin: düz renk ya da iki uçlu doğrusal degrade (yatay: soldan sağa, dikey: üstten alta).</summary>
    private static Brush Ground(TextPaint paint)
    {
        var start = Parse(paint.Background, Colors.Black);
        if (paint.Background2 is not { } second || paint.Direction is not { } direction) return new SolidColorBrush(start);
        var end = Parse(second, start);
        return direction == TextPaint.Vertical
            ? new LinearGradientBrush(start, end, new Point(0.5, 0), new Point(0.5, 1))
            : new LinearGradientBrush(start, end, new Point(0, 0.5), new Point(1, 0.5));
    }

    private static Color Parse(string? hex, Color fallback) =>
        hex is { Length: 7 } && hex[0] == '#'
        && int.TryParse(hex.AsSpan(1), NumberStyles.HexNumber, null, out var rgb)
            ? Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb)
            : fallback;
}
