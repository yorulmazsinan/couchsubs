// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using CouchSubs.App.Controls;
using CouchSubs.App.Theme;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>
/// Ayarlar › Altyazı Görünümü (tuval 19): solda TV'deki altyazının 16:9 önizlemesi ve düşük kontrast uyarısı; sağda
/// Yazı Boyutu (16–50), Zemin Rengi ve Koyuluk (Açık / Orta / Koyu = 45 / 75 / 95), Yazı Rengi, Karakter Adı (Yazıyla Aynı /
/// Tek Renk / Karaktere Göre). Hepsi altyazı biçimine kaydedilir ve TV'ye, telefona ve bilgisayar ekranına gider
/// (backgroundColor, textHex, nameColorMode, nameHex, characterColors; design/yeni-arayuz/METINLER.md, Mac ile aynı):
/// 16–50 kaydırıcısı TV yazı boyuna (16–90) doğrusal eşlenir; koyuluk 45 / 75 / 100; "Zeminsiz" koyuluk 0; "Yazıyla
/// Aynı" konuşan renklerini kapatır.
/// </summary>
public sealed class AppearanceEditor : Grid
{
    private static readonly (string Name, Color? Value)[] Backgrounds =
    [
        ("Black", Rgb(16, 16, 20)), ("Navy", Rgb(14, 26, 48)), ("Dark Gray", Rgb(43, 45, 51)), ("Brown", Rgb(42, 31, 20)),
        ("White", Rgb(255, 255, 255)), ("Cream", Rgb(243, 238, 228)), ("No Background", null),
    ];
    private static readonly (string Name, Color Value)[] TextColors =
    [
        ("White", Rgb(255, 255, 255)), ("Cream", Rgb(0xF3, 0xEE, 0xE4)), ("Yellow", Rgb(0xFF, 0xE0, 0x66)), ("Light Blue", Rgb(0xBF, 0xE3, 0xFF)),
        ("Black", Rgb(0x11, 0x11, 0x14)), ("Navy", Rgb(0x0E, 0x1A, 0x30)), ("Dark Gray", Rgb(0x2B, 0x2D, 0x33)),
    ];
    private static readonly (string Name, Color Value)[] NameColors =
    [
        ("Amber", Rgb(0xF5, 0xB8, 0x3D)), ("Turquoise", Rgb(0x4F, 0xD1, 0xC5)), ("Pink", Rgb(0xFF, 0x8F, 0xAB)), ("Purple", Rgb(0xB7, 0x94, 0xF6)),
        ("Green", Rgb(0x68, 0xD3, 0x91)), ("Orange", Rgb(0xF6, 0x87, 0x4F)), ("Red", Rgb(0xF5, 0x65, 0x65)), ("Blue", Rgb(0x63, 0xB3, 0xED)),
    ];
    private static readonly int[] Darkness = [45, 75, 100];
    private static readonly (string Name, string Line)[] Sample = [("Jason", "Tamam. Gidelim."), ("Lucia", "Yakınımda kal. Bunu birlikte yapacağız."), ("Cal", "Bir sürü silah sesi duyuyorum!")];

    private readonly AppController controller;
    private readonly StackPanel previewLines = new() { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = Sp.T("m") };
    private readonly TextBlock lowContrast = new();
    private readonly TextBlock sizeValue = new();
    private readonly Slider size = new() { Minimum = 16, Maximum = 50, SmallChange = 1, LargeChange = 4, IsSnapToTickEnabled = true, TickFrequency = 1 };
    private readonly TextBlock backgroundName = new();
    private readonly TextBlock textName = new();
    private readonly WrapPanel backgroundSwatches = new();
    private readonly WrapPanel textSwatches = new();
    private readonly StackPanel nameArea = new();
    private readonly RadioButton[] darknessButtons = new RadioButton[3];
    private readonly RadioButton[] nameModes = new RadioButton[3];
    private int background;
    private int text;
    private int nameMode = 1;
    private int singleName;
    private int[] perCharacter = [1, 2, 0];
    /// <summary>"Karaktere Göre"de listelenen kişiler: bu oturumda görülenler, yoksa örnek adlar.</summary>
    private string[] characters = [.. Sample.Select(item => item.Name)];
    private bool loading = true;

    public AppearanceEditor(AppController controller)
    {
        this.controller = controller;
        ColumnDefinitions.Add(new ColumnDefinition());
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Sp.V("l")) });
        ColumnDefinitions.Add(new ColumnDefinition());
        var l = Localizer.Current;

        // Sol: önizleme (Mac: "TV'deki altyazılar" kartı).
        var frame = new Border { Child = previewLines };
        frame.SetResourceReference(StyleProperty, "DeviceFrame");
        var preview = new SpacedStack();
        preview.Children.Add(new AspectBox { Child = frame });
        lowContrast.Text = l["The text color is too close to the background; it may be hard to read on the TV."];
        lowContrast.SetResourceReference(StyleProperty, "ErrorText");
        preview.Children.Add(lowContrast);
        preview.Children.Add(Hint("The settings apply the same on the TV, phone and computer screen.", new Thickness(0)));
        var left = new Card { Title = l["Subtitles on the TV"], Content = preview, VerticalAlignment = VerticalAlignment.Top };
        Children.Add(left);

        // Sağ: ayarlar; her biri bir birim (başlık üstte, denetim altta, açıklama altında), aralar 24, ayraç yok.
        var right = new SpacedStack();
        // Yazı boyutu (DSSliderRow): başlık solda, değer sağda (mono), çubuk altta, uçlarda 16 / 50.
        var sizeUnit = new StackPanel();
        var sizeHead = new DockPanel { Margin = Sp.T("0", "0", "0", "unitTitle") };
        sizeValue.SetResourceReference(StyleProperty, "MonoText");
        sizeValue.VerticalAlignment = VerticalAlignment.Bottom;
        DockPanel.SetDock(sizeValue, Dock.Right);
        sizeHead.Children.Add(sizeValue);
        sizeHead.Children.Add(UnitTitle("Text Size"));
        sizeUnit.Children.Add(sizeHead);
        sizeUnit.Children.Add(size);
        var range = new DockPanel();
        range.SetResourceReference(StyleProperty, "SliderRange");
        var low = new TextBlock { Text = "16" };
        low.SetResourceReference(StyleProperty, "SliderRangeText");
        var high = new TextBlock { Text = "50" };
        high.SetResourceReference(StyleProperty, "SliderRangeText");
        DockPanel.SetDock(high, Dock.Right);
        range.Children.Add(high);
        range.Children.Add(low);
        sizeUnit.Children.Add(range);
        right.Children.Add(sizeUnit);
        size.ValueChanged += (_, e) =>
        {
            sizeValue.Text = Localizer.Current.Format("%lld px", (int)e.NewValue);
            if (!loading) Save(style => style with { FontSize = TvSize((int)e.NewValue) });
            Preview();
        };

        for (var i = 0; i < Backgrounds.Length; i++)
        {
            var index = i;
            var brush = Backgrounds[i].Value is { } color ? (Brush)new SolidColorBrush(color) : Checker();
            backgroundSwatches.Children.Add(Swatch(brush, l[Backgrounds[i].Name], "bg", 32, () =>
            {
                background = index;
                SaveBackground();
                Preview();
            }));
        }
        backgroundName.SetResourceReference(StyleProperty, "HintText");
        right.Children.Add(Unit("Background Color", backgroundSwatches, backgroundName));
        right.Children.Add(Unit("Darkness", Segments(["Light", "Medium", "Dark"], darknessButtons, index =>
        {
            SaveBackground();
            Preview();
        })));

        for (var i = 0; i < TextColors.Length; i++)
        {
            var index = i;
            textSwatches.Children.Add(Swatch(new SolidColorBrush(TextColors[i].Value), l[TextColors[i].Name], "text", 32, () =>
            {
                text = index;
                // Seçilen renk textHex olarak gider; eski TV için en yakın beyaz / sarı da (Mac ile aynı).
                Save(style => style with
                {
                    TextHex = Hex(TextColors[index].Value),
                    TextColor = TextColors[index].Name == "Yellow" ? SubtitleTextColor.Yellow : SubtitleTextColor.White,
                });
                Preview();
            }));
        }
        textName.SetResourceReference(StyleProperty, "HintText");
        right.Children.Add(Unit("Text Color", textSwatches, textName));

        var modes = Segments(["Same as Text", "Single Color", "By Character"], nameModes, index =>
        {
            nameMode = index;
            SaveNames();
            ShowNameArea();
            Preview();
        });
        var nameUnit = new StackPanel();
        nameUnit.Children.Add(modes);
        nameArea.Margin = Sp.T("0", "m", "0", "0");
        nameUnit.Children.Add(nameArea);
        right.Children.Add(Unit("Character Name", nameUnit));
        var rightCard = new Card { Content = right, VerticalAlignment = VerticalAlignment.Top };
        SetColumn(rightCard, 2);
        Children.Add(rightCard);

        Load();
        loading = false;
        ShowNameArea();
        Preview();
    }

    /// <summary>Kayıttan: boyut eşlemesi, zemin rengi ve koyuluğu, yazı rengi, karakter adı.</summary>
    private void Load()
    {
        var settings = controller.Settings;
        var style = settings.Style;
        size.Value = Math.Clamp((int)Math.Round(16 + (style.FontSize - 16) * 34.0 / 74), 16, 50);
        sizeValue.Text = Localizer.Current.Format("%lld px", (int)size.Value);
        var backgroundIndex = Array.FindIndex(Backgrounds, item => item.Value is { } color && Hex(color) == style.BackgroundRgb);
        background = style.Background <= 0 ? Backgrounds.Length - 1 : Math.Max(0, backgroundIndex);
        ((ColorSwatch)backgroundSwatches.Children[background]).IsChecked = true;
        var dark = Array.IndexOf(Darkness, Darkness.MinBy(value => Math.Abs(value - Math.Max(style.Background, 1))));
        darknessButtons[dark].IsChecked = true;
        text = Math.Max(0, Array.FindIndex(TextColors, item => Hex(item.Value) == style.TextRgb));
        if (style.TextHex is null && style.TextColor == SubtitleTextColor.Yellow) text = 2;
        ((ColorSwatch)textSwatches.Children[text]).IsChecked = true;
        nameMode = !settings.SpeakerColors || style.NameColorMode == NameColorMode.Text ? 0 : style.NameColorMode == NameColorMode.Single ? 1 : 2;
        singleName = Math.Max(0, Array.FindIndex(NameColors, item => Hex(item.Value) == SubtitleStyle.Hex(style.NameHex)));
        var known = controller.SpeakerBook.Known;
        if (known.Count > 0) characters = [.. known.Take(8).Select(person => Title(person.Key))];
        perCharacter = [.. characters.Select((name, index) =>
        {
            var key = name.ToLowerInvariant();
            var chosen = style.CharacterColors is { } map && map.TryGetValue(key, out var hex) ? hex : null;
            var found = Array.FindIndex(NameColors, item => Hex(item.Value) == SubtitleStyle.Hex(chosen));
            return found >= 0 ? found : (index + 1) % NameColors.Length;
        })];
        nameModes[nameMode].IsChecked = true;
    }

    private static string Title(string key) => key.Length == 0 ? key : char.ToUpper(key[0]) + key[1..];

    private static string Hex(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";

    /// <summary>16–50 kaydırıcısı → TV yazı boyu 16–90 (doğrusal; Mac ile aynı).</summary>
    private static int TvSize(int shown) => (int)Math.Round(16 + (shown - 16) * 74.0 / 34);

    private void Save(Func<SubtitleStyle, SubtitleStyle> change, bool? speakerColors = null)
    {
        if (loading) return;
        var settings = controller.Settings;
        controller.Settings = settings with { Style = change(settings.Style), SpeakerColors = speakerColors ?? settings.SpeakerColors };
    }

    /// <summary>Zemin: "Zeminsiz" koyuluk 0; diğerleri rengi ve seçili koyuluğu (45 / 75 / 100).</summary>
    private void SaveBackground()
    {
        var darkness = Darkness[Math.Max(0, Array.FindIndex(darknessButtons, b => b.IsChecked == true))];
        Save(style => Backgrounds[background].Value is { } color
            ? style with { BackgroundColor = Hex(color), Background = darkness }
            : style with { Background = 0 });
    }

    /// <summary>Karakter adı: Yazıyla Aynı konuşan renklerini kapatır; Tek Renk ve Karaktere Göre açar.</summary>
    private void SaveNames()
    {
        var mode = nameMode switch { 0 => NameColorMode.Text, 1 => NameColorMode.Single, _ => NameColorMode.Speaker };
        var chosen = characters.Select((name, index) => (name.ToLowerInvariant(), Hex(NameColors[perCharacter[index]].Value)))
            .ToDictionary(item => item.Item1, item => item.Item2);
        Save(style => style with { NameColorMode = mode, NameHex = Hex(NameColors[singleName].Value), CharacterColors = chosen }, speakerColors: nameMode != 0);
    }

    private void ShowNameArea()
    {
        var l = Localizer.Current;
        nameArea.Children.Clear();
        if (nameMode == 0)
        {
            nameArea.Children.Add(Hint("The character name is shown in the same color as the text.", new Thickness(0)));
            return;
        }
        if (nameMode == 1)
        {
            var row = new WrapPanel();
            for (var i = 0; i < NameColors.Length; i++)
            {
                var index = i;
                var swatch = Swatch(new SolidColorBrush(NameColors[i].Value), l[NameColors[i].Name], "name", 32, () => { singleName = index; SaveNames(); Preview(); });
                swatch.IsChecked = i == singleName;
                row.Children.Add(swatch);
            }
            nameArea.Children.Add(row);
            return;
        }
        for (var c = 0; c < characters.Length; c++)
        {
            var character = c;
            var line = new DockPanel { Margin = Sp.T("0", "0", "0", "s") };
            var name = new TextBlock { Text = characters[c], Width = 72, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(NameColors[perCharacter[c]].Value),
                VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(name, Dock.Left);
            line.Children.Add(name);
            var row = new WrapPanel();
            for (var i = 0; i < NameColors.Length; i++)
            {
                var index = i;
                var swatch = Swatch(new SolidColorBrush(NameColors[i].Value), $"{characters[c]}: {l[NameColors[i].Name]}", "name" + c, 24, () =>
                {
                    perCharacter[character] = index;
                    name.Foreground = new SolidColorBrush(NameColors[index].Value);
                    SaveNames();
                    Preview();
                });
                swatch.IsChecked = perCharacter[c] == i;
                row.Children.Add(swatch);
            }
            line.Children.Add(row);
            nameArea.Children.Add(line);
        }
        nameArea.Children.Add(Hint("New characters get colors in turn.", new Thickness(0)));
    }

    /// <summary>Önizleme: üç satır, zemin rengi ve koyuluğu, yazı rengi, karakter adı rengi; kontrast 4,5'in altındaysa uyarı.</summary>
    private void Preview()
    {
        if (loading) return;
        var l = Localizer.Current;
        var darkness = Darkness[Math.Max(0, Array.FindIndex(darknessButtons, b => b.IsChecked == true))] / 100.0;
        // Önizleme (Mac ile aynı): kaydırıcıdaki boyun yarısı.
        var bg = Backgrounds[background].Value;
        var fg = TextColors[text].Value;
        backgroundName.Text = l.Format("Selected: %@.", l[Backgrounds[background].Name]);
        textName.Text = l.Format("Selected: %@.", l[TextColors[text].Name]);
        previewLines.Children.Clear();
        for (var i = 0; i < Sample.Length; i++)
        {
            var nameColor = nameMode == 0 ? fg : nameMode == 1 ? NameColors[singleName].Value : NameColors[perCharacter[i % perCharacter.Length]].Value;
            var line = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = Math.Round(size.Value * 0.5), Foreground = new SolidColorBrush(fg), TextAlignment = TextAlignment.Center };
            line.Inlines.Add(new System.Windows.Documents.Run(Sample[i].Name + ":") { Foreground = new SolidColorBrush(nameColor) });
            line.Inlines.Add(new System.Windows.Documents.Run(" " + Sample[i].Line));
            if (bg is null) line.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 3, ShadowDepth = 1, Opacity = 0.85, Color = Colors.Black };
            previewLines.Children.Add(new Border
            {
                Child = line, Padding = Sp.T("s", "titleBody", "s", "titleBody"), CornerRadius = new CornerRadius(10), Margin = Sp.T("0", "titleBody", "0", "0"), HorizontalAlignment = HorizontalAlignment.Center,
                Background = bg is { } color ? new SolidColorBrush(Color.FromArgb((byte)(darkness * 255), color.R, color.G, color.B)) : Brushes.Transparent,
            });
        }
        // Yarı saydam zemin TV görüntüsüyle (orta ton) karışır; kontrast karışık renge göre.
        var scene = Rgb(109, 106, 93);
        var mixed = bg is { } b2 ? Mix(b2, scene, darkness) : scene;
        lowContrast.Visibility = Contrast(fg, mixed) < 4.5 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static Color Mix(Color top, Color under, double alpha) =>
        Color.FromRgb((byte)(top.R * alpha + under.R * (1 - alpha)), (byte)(top.G * alpha + under.G * (1 - alpha)), (byte)(top.B * alpha + under.B * (1 - alpha)));

    private static double Contrast(Color a, Color b)
    {
        static double Lum(Color c)
        {
            static double Channel(byte v) { var x = v / 255.0; return x <= 0.03928 ? x / 12.92 : Math.Pow((x + 0.055) / 1.055, 2.4); }
            return 0.2126 * Channel(c.R) + 0.7152 * Channel(c.G) + 0.0722 * Channel(c.B);
        }
        var (la, lb) = (Lum(a), Lum(b));
        return (Math.Max(la, lb) + 0.05) / (Math.Min(la, lb) + 0.05);
    }

    private static Color Rgb(byte r, byte g, byte b) => Color.FromRgb(r, g, b);
    private static Color Rgb(int r, int g, int b) => Color.FromRgb((byte)r, (byte)g, (byte)b);

    /// <summary>"Zeminsiz" için dama deseni.</summary>
    private static Brush Checker()
    {
        var drawing = new DrawingGroup();
        drawing.Children.Add(new GeometryDrawing(new SolidColorBrush(Rgb(0xFA, 0xF8, 0xF4)), null, new RectangleGeometry(new Rect(0, 0, 10, 10))));
        drawing.Children.Add(new GeometryDrawing(new SolidColorBrush(Rgb(0xE3, 0xDD, 0xD3)), null, new RectangleGeometry(new Rect(0, 0, 5, 5))));
        drawing.Children.Add(new GeometryDrawing(new SolidColorBrush(Rgb(0xE3, 0xDD, 0xD3)), null, new RectangleGeometry(new Rect(5, 5, 5, 5))));
        return new DrawingBrush(drawing) { TileMode = TileMode.Tile, Viewport = new Rect(0, 0, 10, 10), ViewportUnits = BrushMappingMode.Absolute };
    }

    private ColorSwatch Swatch(Brush brush, string label, string group, double diameter, Action picked)
    {
        var swatch = new ColorSwatch { Swatch = brush, Diameter = diameter, GroupName = group + GetHashCode(), ToolTip = label, Margin = new Thickness(0, 0, Sp.V(diameter > 24 ? "s" : "xs"), Sp.V("xs")) };
        System.Windows.Automation.AutomationProperties.SetName(swatch, label);
        swatch.Checked += (_, _) => { if (!loading) picked(); };
        return swatch;
    }

    private Border Segments(string[] labels, RadioButton[] buttons, Action<int> picked)
    {
        var group = new Border();
        group.SetResourceReference(StyleProperty, "SegmentGroup");
        var row = new UniformGrid { Rows = 1 };
        var name = Guid.NewGuid().ToString("N");
        for (var i = 0; i < labels.Length; i++)
        {
            var index = i;
            var button = new RadioButton { Content = Localizer.Current[labels[i]], GroupName = name };
            button.SetResourceReference(StyleProperty, "SegmentButton");
            button.Checked += (_, _) => { if (!loading) picked(index); };
            buttons[i] = button;
            row.Children.Add(button);
        }
        group.Child = row;
        return group;
    }

    private static TextBlock UnitTitle(string key)
    {
        var title = new TextBlock { Text = Localizer.Current[key] };
        title.SetResourceReference(StyleProperty, "UnitTitleText");
        return title;
    }

    /// <summary>Ayar birimi (Mac DSUnit): başlık üstte, denetim altta (unitTitle 8), varsa açıklama en altta (unitHint 6).</summary>
    private static StackPanel Unit(string key, UIElement control, FrameworkElement? hint = null)
    {
        var unit = new StackPanel();
        var title = UnitTitle(key);
        title.Margin = Sp.T("0", "0", "0", "unitTitle");
        unit.Children.Add(title);
        unit.Children.Add(control);
        if (hint is not null)
        {
            hint.Margin = Sp.T("0", "unitHint", "0", "0");
            unit.Children.Add(hint);
        }
        return unit;
    }

    private static TextBlock Hint(string key, Thickness margin)
    {
        var hint = new TextBlock { Text = Localizer.Current[key], Margin = margin, VerticalAlignment = VerticalAlignment.Center };
        hint.SetResourceReference(StyleProperty, "HintText");
        return hint;
    }
}
