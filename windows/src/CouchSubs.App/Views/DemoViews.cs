// SPDX-License-Identifier: AGPL-3.0-only
// Deneme modu: konsol, hesap ve TV olmadan uygulamadaki örnek görüntülerle çeviri (Mac'teki DemoViews.swift ile aynı).

using System.ComponentModel;
using CouchSubs.App.Theme;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CouchSubs.App.Controls;
using CouchSubs.Core;
using CouchSubs.Shell;
using Frame = CouchSubs.Core.Frame;

namespace CouchSubs.App.Views;

/// <summary>Denetleyiciyi (DataContext) görünüm ağaçtayken dinleyen ortak taban.</summary>
public abstract class DemoView : UserControl
{
    private AppController? listening;

    protected DemoView()
    {
        Focusable = false;
        Loaded += (_, _) => Listen(DataContext as AppController);
        Unloaded += (_, _) => Listen(null);
        DataContextChanged += (_, _) => { if (IsLoaded) Listen(DataContext as AppController); };
    }

    protected AppController? Controller => DataContext as AppController;

    private void Listen(AppController? controller)
    {
        if (listening is not null) listening.PropertyChanged -= OnChanged;
        listening = controller;
        if (listening is not null) listening.PropertyChanged += OnChanged;
        Refresh();
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e) => Changed(e.PropertyName);

    protected abstract void Changed(string? property);
    protected abstract void Refresh();

    protected static TextBlock Hint(string key, Thickness margin)
    {
        var hint = new TextBlock { Text = Localizer.Current[key], TextWrapping = TextWrapping.Wrap, Margin = margin };
        hint.SetResourceReference(StyleProperty, "HintText");
        return hint;
    }
}

/// <summary>Kurulum sihirbazının alt çubuğunda, ana ekranda ve Ayarlar'da görünen "Deneme modu" düğmesi.</summary>
public sealed class DemoModeButton : DemoView
{
    private readonly Button button = new() { Padding = Sp.T("m", "0", "m", "0") };

    public DemoModeButton()
    {
        var glyph = new TextBlock { Text = Glyphs.Play, FontSize = 16, Margin = Sp.T("0", "0", "xs", "0"), VerticalAlignment = VerticalAlignment.Center };
        glyph.SetResourceReference(StyleProperty, "GlyphText");
        var label = new TextBlock { Text = Localizer.Current["Try demo mode (no console needed)"], VerticalAlignment = VerticalAlignment.Center };
        // Yazı ve simge düğmenin rengini alır (hayalet düğmede sarı, ikincilde birincil yazı rengi).
        foreach (var part in new[] { glyph, label })
            part.SetBinding(TextBlock.ForegroundProperty, new Binding(nameof(Foreground)) { Source = button });
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(glyph);
        content.Children.Add(label);
        button.Content = content;
        button.Click += OnClick;
        System.Windows.Automation.AutomationProperties.SetAutomationId(button, "demoModeButton");
        ButtonStyle = "SecondaryButton";
        Content = button;
    }

    /// <summary>Düğmenin stili (Theme/Styles.xaml): "GhostButton" ya da "SecondaryButton".</summary>
    public string ButtonStyle
    {
        get => buttonStyle;
        set
        {
            buttonStyle = value;
            button.SetResourceReference(StyleProperty, value);
        }
    }
    private string buttonStyle = "";

    /// <summary>Sihirbazın alt çubuğundaki ve ana ekrandaki büyük düğme yüksekliği.</summary>
    public bool Large
    {
        get => large;
        set
        {
            large = value;
            if (value) button.SetResourceReference(MinHeightProperty, "size.buttonLarge");
            else button.ClearValue(MinHeightProperty);
        }
    }
    private bool large;

    protected override void Changed(string? property)
    {
        if (property == nameof(AppController.IsStarting)) Refresh();
    }

    protected override void Refresh() => button.IsEnabled = Controller is { IsStarting: false };

    /// <summary>async void: buradan kaçan hata genel hata işleyicisine düşerdi; kaydedilir ve gösterilir.</summary>
    private async void OnClick(object sender, RoutedEventArgs e)
    {
        if (Controller is not { } controller) return;
        // Mac'teki gibi: Ayarlar'dan başlatılınca ana ekrana dönülür, deneme ana ekranda izlenir.
        var fromSettings = this.FindAncestor<SettingsView>() is not null;
        try
        {
            var starting = controller.StartDemoAsync();
            if (fromSettings) ShellWindow.Navigate(ShellTab.Home);
            await starting;
        }
        catch (Exception error)
        {
            StartupGuard.Log("Deneme modu başlatılamadı", error);
            StartupGuard.Show(Application.Current, StartupGuard.ErrorMessage(error));
        }
    }
}

/// <summary>Ayarlar › Görüntü kaynağı: deneme modunu açar ya da kapatır.</summary>
public sealed class DemoModeCard : DemoView
{
    private readonly Button exit = new() { HorizontalAlignment = HorizontalAlignment.Left, Padding = Sp.T("m", "0", "m", "0"), Margin = Sp.T("0", "s", "0", "0") };
    private readonly DemoModeButton start = new() { HorizontalAlignment = HorizontalAlignment.Left, Margin = Sp.T("0", "s", "0", "0") };

    public DemoModeCard()
    {
        exit.Content = Localizer.Current["Exit demo mode"];
        exit.SetResourceReference(StyleProperty, "SecondaryButton");
        exit.Click += (_, _) => Controller?.ExitDemo();
        var panel = new StackPanel();
        panel.Children.Add(Hint("Demo mode shows the whole app with sample pictures built into the app. No console, account or TV is needed.", new Thickness(0)));
        panel.Children.Add(exit);
        panel.Children.Add(start);
        Content = new Card { Title = Localizer.Current["Demo mode"], Content = panel };
    }

    protected override void Changed(string? property)
    {
        if (property == nameof(AppController.DemoMode)) Refresh();
    }

    protected override void Refresh()
    {
        var demo = Controller?.DemoMode == true;
        exit.Visibility = demo ? Visibility.Visible : Visibility.Collapsed;
        start.Visibility = demo ? Visibility.Collapsed : Visibility.Visible;
    }
}

/// <summary>Ana ekranda deneme modunda: "Deneme modu" rozeti, "Çık" düğmesi ve okunan örnek oyun görüntüsü.</summary>
public sealed class DemoFrameTile : DemoView
{
    private readonly Image image = new() { Stretch = Stretch.Uniform, MaxHeight = 260 };
    private Frame? shown;

    public DemoFrameTile()
    {
        var pill = new Border { Child = new TextBlock { Text = Localizer.Current["Demo mode"], VerticalAlignment = VerticalAlignment.Center } };
        pill.SetResourceReference(StyleProperty, "ProPill");
        var exit = new Button { Content = Localizer.Current["Exit"], Padding = Sp.T("m", "0", "m", "0") };
        exit.SetResourceReference(StyleProperty, "SecondaryButton");
        exit.Click += (_, _) => Controller?.ExitDemo();
        System.Windows.Automation.AutomationProperties.SetAutomationId(exit, "demoModeExit");
        var header = new DockPanel();
        DockPanel.SetDock(exit, Dock.Right);
        header.Children.Add(exit);
        header.Children.Add(pill);
        // Kare gelene kadar boş bir alan durur.
        var picture = new Border { Child = image, Margin = Sp.T("0", "s", "0", "0"), MaxHeight = 260, MinHeight = 120 };
        picture.SetResourceReference(Border.BackgroundProperty, "backgroundBrush");
        picture.SetResourceReference(Border.CornerRadiusProperty, "radius.inner");
        var panel = new StackPanel();
        panel.Children.Add(header);
        panel.Children.Add(picture);
        panel.Children.Add(Hint("Sample game picture: the app reads the English subtitle in it, translates it and shows it below and on the subtitle screen.",
            new Thickness(0, 12, 0, 0)));
        Content = new Card { Content = panel };
        Visibility = Visibility.Collapsed;
    }

    protected override void Changed(string? property)
    {
        if (property is nameof(AppController.DemoMode) or nameof(AppController.LastFrame)) Refresh();
    }

    protected override void Refresh()
    {
        var demo = Controller?.DemoMode == true;
        Visibility = demo ? Visibility.Visible : Visibility.Collapsed;
        var frame = demo ? Controller?.LastFrame : null;
        if (ReferenceEquals(frame, shown)) return;
        shown = frame;
        if (frame is null)
        {
            image.Source = null;
            return;
        }
        // Kare opaktır; alfa yok sayılır.
        var bitmap = BitmapSource.Create(frame.Width, frame.Height, 96, 96, PixelFormats.Bgr32, null, frame.Pixels, frame.Stride);
        bitmap.Freeze();
        image.Source = bitmap;
    }
}
