// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CouchSubs.App.Controls;
using CouchSubs.App.Theme;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>
/// Sistem tepsisindeki CouchSubs simgesi ve açılır penceresi (Mac'teki menü çubuğu penceresinin karşılığı, tuval 17;
/// aynı içerik ve stil): başlıkta logo, ad, konsol ve TV, durum rozeti; Çeviriyi Başlat / Durdur; "Tıklamalar Alttaki
/// Pencereye Geçsin" anahtarı; Altyazıları Konumlandır; CouchSubs'ı Aç. Simge yalnız altyazı bu bilgisayarın ekranında
/// gösterilirken görünür. Pencere başka yere tıklanınca kapanır.
/// </summary>
public sealed class TrayPopup : Window
{
    private readonly AppController controller;
    private readonly System.Windows.Forms.NotifyIcon icon;
    private readonly TextBlock detail = new() { FontSize = 12, Margin = Sp.T("0", "xxs", "0", "0"), TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
    private readonly Badge badge = new();
    private readonly Button main = new() { HorizontalAlignment = HorizontalAlignment.Stretch, Height = 44, MinHeight = 44 };
    private readonly SwitchRow clicks;
    private bool updating;

    private TrayPopup(AppController controller)
    {
        this.controller = controller;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        Width = 360;
        SizeToContent = SizeToContent.Height;
        SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "textPrimaryBrush");

        var tile = new Border { Width = 40, Height = 40, CornerRadius = new CornerRadius(12), Child = new CouchLogo { Width = 26, Height = 19, Animated = false } };
        tile.SetResourceReference(Border.BackgroundProperty, "surface2Brush");
        detail.SetResourceReference(TextBlock.ForegroundProperty, "textSecondaryBrush");
        var names = new StackPanel { Margin = Sp.T("s", "0", "s", "0"), VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(new TextBlock { Text = "CouchSubs", FontSize = 15, FontWeight = FontWeights.SemiBold });
        names.Children.Add(detail);
        var head = new DockPanel();
        DockPanel.SetDock(tile, Dock.Left);
        DockPanel.SetDock(badge, Dock.Right);
        head.Children.Add(tile);
        head.Children.Add(badge);
        head.Children.Add(names);

        main.Click += async (_, _) =>
        {
            try
            {
                if (controller.DemoMode) controller.ExitDemo();
                else if (controller.IsRunning) controller.Stop();
                else await controller.StartAsync();
            }
            catch (Exception error) { StartupGuard.Log("Tepsi penceresinden çeviri değiştirilemedi", error); }
        };

        clicks = new SwitchRow
        {
            Content = Localizer.Current["Clicks Pass to the Window Below"], Description = Localizer.Current["Subtitles don't block clicks."], Divider = false,
        };
        clicks.Checked += (_, _) => SetClickThrough(true);
        clicks.Unchecked += (_, _) => SetClickThrough(false);

        var place = Item(Localizer.Current["Position the Subtitles"], false, () => controller.OverlayAdjusting = true);
        var open = Item(Localizer.Current["Show CouchSubs"], true, ShowMain);

        var stack = new StackPanel();
        stack.Children.Add(head);
        main.Margin = Sp.T("0", "s", "0", "s");
        stack.Children.Add(main);
        stack.Children.Add(Divider());
        stack.Children.Add(clicks);
        stack.Children.Add(place);
        stack.Children.Add(Divider());
        stack.Children.Add(open);
        var card = new Border { Child = stack, Padding = Sp.T("m"), CornerRadius = new CornerRadius(20), BorderThickness = new Thickness(1), Margin = Sp.T("m") };
        card.SetResourceReference(Border.BackgroundProperty, "surfaceBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "borderBrush");
        card.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 40, ShadowDepth = 16, Direction = 270, Opacity = 0.14, Color = Color.FromRgb(0x1D, 0x1E, 0x22) };
        Content = card;
        Deactivated += (_, _) => Hide();
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Hide(); };

        icon = new System.Windows.Forms.NotifyIcon
        {
            Text = "CouchSubs",
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? System.Reflection.Assembly.GetEntryAssembly()!.Location),
        };
        icon.MouseUp += (_, e) =>
        {
            if (e.Button == System.Windows.Forms.MouseButtons.Left || e.Button == System.Windows.Forms.MouseButtons.Right) Toggle();
        };
        controller.PropertyChanged += OnChanged;
        Refresh();
    }

    /// <summary>Tepsi simgesini kurar; uygulama kapanınca kaldırılır.</summary>
    public static TrayPopup? Attach(AppController controller)
    {
        try
        {
            var popup = new TrayPopup(controller);
            Application.Current.Exit += (_, _) => popup.Detach();
            return popup;
        }
        catch (Exception error)
        {
            StartupGuard.Log("Tepsi simgesi kurulamadı", error);
            return null;
        }
    }

    public void Detach()
    {
        controller.PropertyChanged -= OnChanged;
        icon.Visible = false;
        icon.Dispose();
        Close();
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.IsRunning) or nameof(AppController.IsStarting) or nameof(AppController.DemoMode)
            or nameof(AppController.Settings) or nameof(AppController.Ps5Tone) or nameof(AppController.TvTone) or nameof(AppController.Step))
            Dispatcher.BeginInvoke(Refresh);
    }

    private void Refresh()
    {
        var text = Localizer.Current;
        // Simge yalnız altyazı bu bilgisayarın ekranında gösterilirken görünür.
        icon.Visible = controller.ShowsOnComputer;
        if (!icon.Visible && IsVisible) Hide();
        var parts = new List<string> { controller.ConsoleTitle };
        if (controller.Console?.Name is { Length: > 0 } console && !controller.IsXbox) parts.Add(console);
        if (controller.ShowsOnTv && controller.Tv?.Name is { Length: > 0 } tv) parts.Add(tv);
        detail.Text = string.Join(" · ", parts);
        var running = controller.IsRunning;
        badge.Content = text[controller.DemoMode ? "Demo Mode" : running ? "Translation On" : "Ready"];
        badge.Tone = running ? PillTone.Success : controller.DemoMode ? PillTone.Attention : PillTone.Idle;
        main.SetResourceReference(StyleProperty, running || controller.DemoMode ? "LiveButton" : "PrimaryButton");
        main.Content = text[controller.IsStarting ? "Starting…" : controller.DemoMode ? "Exit Demo Mode" : running ? "Stop Translating" : "Start Translating"];
        main.IsEnabled = !controller.IsStarting && (running || controller.DemoMode || controller.CanStart);
        updating = true;
        clicks.IsChecked = controller.Settings.OverlayClickThrough;
        updating = false;
    }

    private void SetClickThrough(bool on)
    {
        if (!updating && controller.Settings.OverlayClickThrough != on) controller.ToggleClickThrough();
    }

    /// <summary>Pencere, tepsinin bulunduğu köşede (çalışma alanının sağ altı) açılır ya da kapanır.</summary>
    private void Toggle()
    {
        if (IsVisible)
        {
            Hide();
            return;
        }
        Refresh();
        Show();
        UpdateLayout();
        var work = SystemParameters.WorkArea;
        Left = work.Right - ActualWidth;
        Top = work.Bottom - ActualHeight;
        Activate();
        Motion.EnterFrom((FrameworkElement)Content, 12, Motion.Medium);
    }

    private void ShowMain()
    {
        Hide();
        if (Application.Current.MainWindow is not { } window) return;
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    private static Border Divider()
    {
        var line = new Border { Height = 1, Margin = Sp.T("0", "xxs", "0", "xxs") };
        line.SetResourceReference(Border.BackgroundProperty, "borderBrush");
        return line;
    }

    /// <summary>Menü satırı: 44 yüksek, 14 orta kalın; sonunda isteğe bağlı ok.</summary>
    private Button Item(string label, bool arrow, Action run)
    {
        var row = new DockPanel();
        if (arrow)
        {
            var mark = new TextBlock { Text = "→", FontSize = 13 };
            mark.SetResourceReference(TextBlock.ForegroundProperty, "textTertiaryBrush");
            DockPanel.SetDock(mark, Dock.Right);
            row.Children.Add(mark);
        }
        row.Children.Add(new TextBlock { Text = label, FontSize = 14, FontWeight = FontWeights.Medium });
        var button = new Button { Content = row, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Height = 44, MinHeight = 44, Padding = Sp.T("s", "0", "s", "0") };
        button.SetResourceReference(StyleProperty, "GhostButton");
        button.SetResourceReference(ForegroundProperty, "textPrimaryBrush");
        button.Click += (_, _) => run();
        return button;
    }
}
