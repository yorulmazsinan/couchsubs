// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using CouchSubs.Shell;

namespace CouchSubs.App.Controls;

// Ortak bileşenler (docs/TASARIM.md). Görünümleri Theme/Styles.xaml'daki şablonlarda; ölçü ve renkler
// tokens.json'dan gelen kaynaklardan. Mac'teki bileşenlerle aynı adları taşır.

/// <summary>Sihirbaz adımlarının ortak düzeni: başlık, açıklama, içerik (simge rozeti yok).</summary>
public class StepLayout : ContentControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(StepLayout));
    public static readonly DependencyProperty MessageProperty = DependencyProperty.Register(nameof(Message), typeof(string), typeof(StepLayout));

    static StepLayout() => DefaultStyleKeyProperty.OverrideMetadata(typeof(StepLayout), new FrameworkPropertyMetadata(typeof(StepLayout)));

    public string Title { get => (string)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string Message { get => (string)GetValue(MessageProperty); set => SetValue(MessageProperty, value); }
}

/// <summary>Karonun görünümü: sıradan ya da etkin (seçili seçenek: 1 px sarı çerçeve). Parıltı ve degrade yok.</summary>
public enum TileKind { Normal, Active }

/// <summary>Başlıklı ya da başlıksız içerik kartı (karo).</summary>
public class Card : ContentControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(Card));
    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(nameof(Kind), typeof(TileKind), typeof(Card),
        new FrameworkPropertyMetadata(TileKind.Normal));

    static Card() => DefaultStyleKeyProperty.OverrideMetadata(typeof(Card), new FrameworkPropertyMetadata(typeof(Card)));

    public string? Title { get => (string?)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public TileKind Kind { get => (TileKind)GetValue(KindProperty); set => SetValue(KindProperty, value); }
}

/// <summary>Numaralı talimat satırı.</summary>
public class NumberedRow : Control
{
    public static readonly DependencyProperty NumberProperty = DependencyProperty.Register(nameof(Number), typeof(int), typeof(NumberedRow));
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(NumberedRow));

    static NumberedRow() => DefaultStyleKeyProperty.OverrideMetadata(typeof(NumberedRow), new FrameworkPropertyMetadata(typeof(NumberedRow)));

    public int Number { get => (int)GetValue(NumberProperty); set => SetValue(NumberProperty, value); }
    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
}

/// <summary>Durum karosunun içi: üstte simge, ad ve durum noktası; altında değer.</summary>
public class StatusRow : Control
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(StatusRow));
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(nameof(Value), typeof(string), typeof(StatusRow));
    public static readonly DependencyProperty ToneProperty = DependencyProperty.Register(nameof(Tone), typeof(StatusTone), typeof(StatusRow));
    public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(StatusRow));

    static StatusRow() => DefaultStyleKeyProperty.OverrideMetadata(typeof(StatusRow), new FrameworkPropertyMetadata(typeof(StatusRow)));

    public string Title { get => (string)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string Value { get => (string)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public StatusTone Tone { get => (StatusTone)GetValue(ToneProperty); set => SetValue(ToneProperty, value); }
    /// <summary>Karonun sol üstündeki simge (Segoe Fluent Icons).</summary>
    public string? Glyph { get => (string?)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }
}

/// <summary>Segoe Fluent Icons simge adları (Mac'teki SF Symbols karşılıkları).</summary>
public static class Glyphs
{
    /// <summary>Segoe Fluent Icons "Characters" (U+E8C1); "Daha iyi çeviri" adımı.</summary>
    public const string Characters = "";
    public const string Captions = "";
    public const string People = "";
    public const string Person = "";
    public const string Controller = "";
    public const string Tv = "";
    public const string Seal = "";
    public const string Download = "";
    public const string Play = "";
    public const string Stop = "";
    public const string Settings = "";
    public const string Check = "";
    public const string Warning = "";
    /// <summary>Segoe Fluent Icons "Globe" (U+E774); çeviri motoru karosu.</summary>
    public const string Globe = "\uE774";
    /// <summary>Segoe Fluent Icons "KeyboardClassic" (U+E765); kısayol karosu.</summary>
    public const string Keyboard = "\uE765";
    /// <summary>Segoe Fluent Icons "Package" (U+E7B8); oyun paketi karosu.</summary>
    public const string Package = "\uE7B8";
}
