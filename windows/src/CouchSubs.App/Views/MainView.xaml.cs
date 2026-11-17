// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using CouchSubs.App.Controls;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>Ana ekran: başlat/durdur, PS5 ve TV durumu, uyarılar, son altyazı.</summary>
public partial class MainView : UserControl
{
    private readonly AppController controller;
    // Çeviri sürerken PS5 ve TV bağlanamıyorsa güvenlik duvarı kartı önerilir.
    private readonly DispatcherTimer connectionWatch = new() { Interval = TimeSpan.FromSeconds(5) };

    public MainView(AppController controller)
    {
        this.controller = controller;
        DataContext = controller;
        InitializeComponent();
        OutputCard.Attach(controller);
        controller.PropertyChanged += OnChanged;
        connectionWatch.Tick += async (_, _) => await controller.CheckConnectionsAsync();
        Loaded += (_, _) => connectionWatch.Start();
        Unloaded += (_, _) =>
        {
            controller.PropertyChanged -= OnChanged;
            connectionWatch.Stop();
        };
        Refresh();
        ShowTiles();
        ShowUpdate();
        ShowGame();
        _ = controller.CheckForUpdateAsync();
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.IsRunning) or nameof(AppController.TranslatorStatus) or nameof(AppController.ModelInstalled)
            or nameof(AppController.OnlineIssue) or nameof(AppController.CanStart) or nameof(AppController.IsStarting))
            Refresh();
        if (e.PropertyName is nameof(AppController.Settings) or nameof(AppController.InstalledPacks))
            ShowTiles();
        if (e.PropertyName is nameof(AppController.IsRunning) or nameof(AppController.PlayedGame) or nameof(AppController.AskingGame))
            ShowGame();
        if (e.PropertyName is nameof(AppController.UpdateVersion) or nameof(AppController.Updating)
            or nameof(AppController.UpdateProgress) or nameof(AppController.UpdateError))
            ShowUpdate();
    }

    private void ShowUpdate()
    {
        var text = Localizer.Current;
        UpdateCard.Visibility = controller.UpdateVersion is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateTitle.Text = text["A new version of CouchSubs is available: %@"].Replace("%@", controller.UpdateVersion ?? "");
        UpdateButton.Content = text[controller.CanUpdateItself ? "Update now" : "Download"];
        UpdateButton.IsEnabled = !controller.Updating;
        UpdateBar.Visibility = controller.Updating ? Visibility.Visible : Visibility.Collapsed;
        UpdateBar.Value = controller.UpdateProgress;
        UpdateErrorText.Text = controller.UpdateError ?? "";
        UpdateErrorText.Visibility = controller.UpdateError is null ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>
    /// Çeviri karosunda seçili motor; paket karosu yalnız paketler açık, çeviri İngilizce→Türkçe ve kurulu paket varken
    /// görünür (paketler yalnız o dil çiftinde kullanılır).
    /// </summary>
    private void ShowTiles()
    {
        var text = Localizer.Current;
        var settings = controller.Settings;
        ScreenShortcutText.Text = HotkeyText.Title(settings, HotkeyAction.Screen, "Translate the screen (%@)");
        EngineText.Text = settings.Engine == TranslationEngine.Free ? text["Free"] : settings.Engine.DisplayName();
        var packs = controller.InstalledPacks.Count;
        var active = settings.GamePacks && settings.SourceLanguage == "en" && settings.TargetLanguage == "tr" && packs > 0;
        PackTile.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        PackText.Text = text.Format("Game packs are on · %lld games translated in advance", packs);
    }

    private async void OnUpdate(object sender, RoutedEventArgs e) => await controller.InstallUpdateAsync();

    private void Refresh()
    {
        var running = controller.IsRunning;
        Toggle.Style = (Style)FindResource(running ? "DangerButton" : "PrimaryButton");
        ToggleGlyph.Text = running ? Glyphs.Stop : Glyphs.Play;
        ToggleText.Text = Localizer.Current[running ? "Stop translating" : "Start translating"];
        // Altyazının gideceği bir yer yoksa (TV seçili ama bağlı değil) çeviri başlatılamaz.
        Toggle.IsEnabled = !controller.IsStarting && (running || controller.CanStart);
        ModelCard.Visibility = controller.ModelInstalled ? Visibility.Collapsed : Visibility.Visible;
        EngineCard.Visibility = controller.TranslatorStatus == TranslatorStatus.EngineFailed ? Visibility.Visible : Visibility.Collapsed;
        // Çevrimiçi motor çeviremiyor; satırlar bu arada cihaz üstü modelle geliyor.
        var issue = running ? controller.OnlineIssue : null;
        OnlineCard.Visibility = issue is null ? Visibility.Collapsed : Visibility.Visible;
        if (issue is { } state)
        {
            var engine = controller.Settings.OnlineEngine;
            OnlineTitle.Text = Localizer.Current.Format("%@ is not translating right now", engine.DisplayName());
            OnlineReason.Text = state.Describe(engine, Localizer.Current, controller.Settings.LocalAiServer) + " " + Localizer.Current["Meanwhile the free translation is used."];
        }
    }

    /// <summary>
    /// async void: buradan kaçan hata uygulamanın genel hata işleyicisine düşerdi. Başlatma ya da durdurma hatası
    /// kaydedilir ve gösterilir; uygulama açık kalır.
    /// </summary>
    private async void OnToggle(object sender, RoutedEventArgs e)
    {
        var starting = !controller.IsRunning;
        try
        {
            if (starting) await controller.StartAsync(); else controller.Stop();
        }
        catch (Exception error)
        {
            StartupGuard.Log(starting ? "Çeviri başlatılamadı" : "Çeviri durdurulamadı", error);
            StartupGuard.Show(Application.Current, StartupGuard.ErrorMessage(error));
        }
    }

    private void OnSettings(object sender, RoutedEventArgs e) => SettingsWindow.Open(Window.GetWindow(this), controller);

    private void OnHistory(object sender, RoutedEventArgs e) => HistoryWindow.Open(Window.GetWindow(this), controller);

    /// <summary>Deneme altyazısı (çeviri başlamadıysa altyazı sunucusu da açılır).</summary>
    private async void OnTest(object sender, RoutedEventArgs e)
    {
        try { await controller.SendTestSubtitleAsync(); }
        catch (Exception error) { StartupGuard.Log("Deneme altyazısı gönderilemedi", error); }
    }

    /// <summary>TV'siz kurulmuş uygulamada TV'yi sonradan bağlamak için sihirbazın TV adımı açılır.</summary>
    private void OnConnectTv(object sender, RoutedEventArgs e) => controller.Step = OnboardingStep.Tv;

    private void OnDownload(object sender, RoutedEventArgs e) => controller.StartModelDownload();

    /// <summary>
    /// Oyun dilinin Windows yazı tanıma paketini yönetici izniyle kurar (Add-WindowsCapability), sonra okumayı
    /// yeni paketle yeniden başlatır.
    /// </summary>
    private async void OnInstallOcr(object sender, RoutedEventArgs e)
    {
        var language = controller.Settings.SourceLanguage;
        var script = $"Get-WindowsCapability -Online | Where-Object {{ $_.Name -like 'Language.OCR~~~{language}-*' -and $_.State -ne 'Installed' }} | Select-Object -First 1 | Add-WindowsCapability -Online";
        InstallOcr.IsEnabled = false;
        try
        {
            using var process = Process.Start(new ProcessStartInfo("powershell.exe", $"-NoProfile -WindowStyle Hidden -Command \"{script}\"")
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            });
            if (process is not null) await process.WaitForExitAsync();
            if (!controller.IsRunning) return;
            controller.Stop();
            await controller.StartAsync();
        }
        catch (System.ComponentModel.Win32Exception) { /* izin verilmedi */ }
        finally { InstallOcr.IsEnabled = true; }
    }

    private void OnLanguageSettings(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("ms-settings:regionlanguage") { UseShellExecute = true });

    /// <summary>
    /// Oynanan oyun karosu (yalnız çeviri sürerken): "Oynanan oyun: X · Değiştir" ya da "Hangi oyunu oynuyorsunuz?" kartı
    /// (Mac, iPhone ve Android ile aynı metin ve davranış).
    /// </summary>
    private void ShowGame()
    {
        var text = Localizer.Current;
        GameCard.Visibility = controller.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        var asking = controller.AskingGame;
        GameRow.Visibility = asking ? Visibility.Collapsed : Visibility.Visible;
        GameAsk.Visibility = asking ? Visibility.Visible : Visibility.Collapsed;
        PlayedGameText.Text = controller.PlayedGame ?? text["Not known"];
        GameChangeButton.Content = text[controller.PlayedGame is null ? "Choose" : "Change"];
        if (asking) ShowGameSuggestions();
        else GameSearch.Text = "";
    }

    private void ShowGameSuggestions()
    {
        var typed = GameSearch.Text.Trim();
        var suggestions = controller.GameSuggestions(typed).Take(5).ToList();
        var last = controller.LastPlayedGame;
        GameList.Children.Clear();
        foreach (var name in suggestions)
        {
            var label = new DockPanel();
            if (name == last)
            {
                var note = new TextBlock { Text = Localizer.Current["Last played"], Style = (Style)FindResource("CaptionText"), VerticalAlignment = VerticalAlignment.Center };
                DockPanel.SetDock(note, Dock.Right);
                label.Children.Add(note);
            }
            label.Children.Add(new TextBlock { Text = name, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
            var button = new Button
            {
                Content = label, Style = (Style)FindResource("GhostButton"), HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 2, 0, 2),
            };
            button.Click += (_, _) => controller.ChooseGame(name);
            GameList.Children.Add(button);
        }
        var custom = typed.Length > 0 && !suggestions.Any(n => GameName.Key(n) == GameName.Key(typed));
        GameCustom.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
        GameCustom.Content = Localizer.Current.Format("Not listed: use “%@”", typed);
    }

    private void OnChangeGame(object sender, RoutedEventArgs e) => controller.AskGame();

    private void OnDontAskGame(object sender, RoutedEventArgs e) => controller.DismissGame();

    private void OnGameSearch(object sender, TextChangedEventArgs e) => ShowGameSuggestions();

    private void OnGameSearchKey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != System.Windows.Input.Key.Enter || GameSearch.Text.Trim() is not { Length: > 0 } typed) return;
        controller.ChooseGame(typed);
        e.Handled = true;
    }

    private void OnCustomGame(object sender, RoutedEventArgs e) => controller.ChooseGame(GameSearch.Text.Trim());
}
