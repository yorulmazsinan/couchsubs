// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Hyperlink = System.Windows.Documents.Hyperlink;
using Run = System.Windows.Documents.Run;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using CouchSubs.App.Controls;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>Ana ekran: başlat/durdur, PS5 ve TV durumu, uyarılar, son altyazı.</summary>
public partial class MainView : UserControl
{
    private readonly AppController controller;
    private string? notesVersion;
    private bool notesUnavailable;
    // Çeviri sürerken PS5 ve TV bağlanamıyorsa güvenlik duvarı kartı önerilir.
    private readonly DispatcherTimer connectionWatch = new() { Interval = TimeSpan.FromSeconds(5) };
    /// <summary>Canlı altyazı karosu yalnız bu oturumun satırlarını gösterir (önceki oturumlar Geçmiş'te).</summary>
    private DateTime? sessionStartedAt;
    /// <summary>Karoda son satırın altında en çok bu kadar önceki satır durur.</summary>
    private const int PreviousLineCount = 8;

    public MainView(AppController controller)
    {
        this.controller = controller;
        DataContext = controller;
        InitializeComponent();
        OutputCard.Attach(controller);
        controller.PropertyChanged += OnChanged;
        connectionWatch.Tick += async (_, _) => await controller.CheckConnectionsAsync();
        Loaded += (_, _) => connectionWatch.Start();
        Services.CrashWatch.Changed += OnCrashChanged;
        Unloaded += (_, _) =>
        {
            controller.PropertyChanged -= OnChanged;
            Services.CrashWatch.Changed -= OnCrashChanged;
            connectionWatch.Stop();
        };
        ShowCrash();
        Refresh();
        ShowTiles();
        ShowUpdate();
        ShowGame();
        ShowPreviousLines();
        _ = controller.CheckForUpdateAsync();
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.IsRunning) or nameof(AppController.TranslatorStatus) or nameof(AppController.ModelInstalled)
            or nameof(AppController.OnlineIssue) or nameof(AppController.CanStart) or nameof(AppController.IsStarting)
            or nameof(AppController.DemoMode))
            Refresh();
        if (e.PropertyName is nameof(AppController.Settings) or nameof(AppController.InstalledPacks))
            ShowTiles();
        if (e.PropertyName is nameof(AppController.IsRunning) or nameof(AppController.DemoMode) or nameof(AppController.PlayedGame) or nameof(AppController.AskingGame)
            or nameof(AppController.AreaProfileGame) or nameof(AppController.OfferedAreaProfileGame))
            ShowGame();
        if (e.PropertyName is nameof(AppController.IsRunning) && controller.IsRunning)
            sessionStartedAt = DateTime.UtcNow;
        if (e.PropertyName is nameof(AppController.LastTranslation))
            FadeInLiveLine();
        if (e.PropertyName is nameof(AppController.History) or nameof(AppController.LastTranslation) or nameof(AppController.IsRunning))
            ShowPreviousLines();
        if (e.PropertyName is nameof(AppController.UpdateVersion) or nameof(AppController.Updating)
            or nameof(AppController.UpdateProgress) or nameof(AppController.UpdateError))
            ShowUpdate();
    }

    /// <summary>Kayıt arka planda hazırlanır; hazır olunca arayüz iş parçacığında gösterilir.</summary>
    private void OnCrashChanged() => Dispatcher.BeginInvoke(ShowCrash);

    /// <summary>Önceki çalışma yerel bir hatayla kapandıysa bir kez bildirilir (sonraki açılışta yinelenmez).</summary>
    private void ShowCrash()
    {
        var show = Services.CrashWatch.Pending is not null;
        CrashCard.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (show) Services.CrashWatch.MarkShown();
    }

    private void OnShowCrash(object sender, RoutedEventArgs e) => Services.CrashWatch.ShowInExplorer();

    private void OnCopyCrash(object sender, RoutedEventArgs e)
    {
        if (Services.CrashWatch.CopySummary()) CrashCopyButton.Content = Localizer.Current["Copied"];
    }

    private void OnDismissCrash(object sender, RoutedEventArgs e)
    {
        Services.CrashWatch.Dismiss();
        ShowCrash();
    }

    private void ShowUpdate()
    {
        var text = Localizer.Current;
        if (notesVersion is not null && notesVersion != controller.UpdateVersion)
        {
            UpdateNotes.IsExpanded = false;
            UpdateNotesText.Inlines.Clear();
            notesVersion = null;
        }
        UpdateCard.Visibility = controller.UpdateVersion is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateTitle.Text = text["A new version of CouchSubs is available: %@"].Replace("%@", controller.UpdateVersion ?? "");
        UpdateButton.Content = text[controller.CanUpdateItself ? "Update now" : "Download"];
        UpdateButton.IsEnabled = !controller.Updating;
        UpdateBar.Visibility = controller.Updating ? Visibility.Visible : Visibility.Collapsed;
        UpdateBar.Value = controller.UpdateProgress;
        UpdateErrorText.Text = controller.UpdateError ?? "";
        UpdateErrorText.Visibility = controller.UpdateError is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void OnUpdateNotesExpanded(object sender, RoutedEventArgs e)
    {
        if (controller.UpdateVersion is not { } version || (notesVersion == version && !notesUnavailable)) return;
        notesVersion = version;
        notesUnavailable = false;
        UpdateNotesText.Text = Localizer.Current["Loading release notes…"];
        var notes = await controller.LoadUpdateNotesAsync(version);
        if (controller.UpdateVersion != version || notesVersion != version) return;
        UpdateNotesText.Inlines.Clear();
        foreach (var note in notes)
        {
            var run = new Run(note.Text);
            if (note.Bold) run.FontWeight = FontWeights.SemiBold;
            if (note.Link is not { } url) UpdateNotesText.Inlines.Add(run);
            else
            {
                var link = new Hyperlink(run) { NavigateUri = url };
                link.SetResourceReference(Hyperlink.ForegroundProperty, "accentTextBrush");
                link.RequestNavigate += (_, args) => { controller.OpenInBrowser(args.Uri); args.Handled = true; };
                UpdateNotesText.Inlines.Add(link);
            }
        }
        notesUnavailable = notes.Count == 0;
        if (notesUnavailable) UpdateNotesText.Text = Localizer.Current["Release notes are unavailable."];
    }

    /// <summary>
    /// Çeviri karosunda seçili motor; paket karosu yalnız paketler açık, çeviri İngilizce→Türkçe ve kurulu paket varken
    /// görünür (paketler yalnız o dil çiftinde kullanılır).
    /// </summary>
    private void ShowTiles()
    {
        var text = Localizer.Current;
        var settings = controller.Settings;
        ShowScreenKeys(settings);
        EngineText.Text = settings.Engine == TranslationEngine.Free ? text["Free"] : settings.Engine.DisplayName();
        PictureSourceText.Text = controller.PictureSourceTitle ?? "";
        PictureSourceRow.Visibility = controller.PictureSourceTitle is null ? Visibility.Collapsed : Visibility.Visible;
        var packs = GameCatalog.PackShelf(controller.InstalledPacks).Count;
        var active = settings.GamePacks && settings.SourceLanguage == "en" && settings.TargetLanguage == "tr" && packs > 0;
        PackTile.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        PackText.Text = text.Format("Game packs are on · %lld games translated in advance", packs);
    }

    /// <summary>
    /// Bilgi karosunun "Ekranı çevir" satırı: Ayarlar › Kısayollar'da seçili her tuş bir Keycap, aralarında "ya da".
    /// Hiç kısayol yoksa "kısayol yok" yazar. Kısayol değişince Settings bildirimiyle yeniden kurulur.
    /// </summary>
    private void ShowScreenKeys(UserSettings settings)
    {
        var text = Localizer.Current;
        var keys = HotkeyTable.KeysFor(settings.Hotkeys, HotkeyAction.Screen);
        ScreenKeys.Children.Clear();
        ScreenKeys.ToolTip = HotkeyText.Title(settings, HotkeyAction.Screen, "Translate the screen (%@)");
        if (keys.Count == 0)
        {
            ScreenKeys.Children.Add(new TextBlock
            {
                Text = text["no shortcut"], Style = (Style)FindResource("CaptionText"),
                VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap,
            });
            return;
        }
        for (var index = 0; index < keys.Count; index++)
        {
            if (index > 0)
                ScreenKeys.Children.Add(new TextBlock
                {
                    Text = text["or"], Style = (Style)FindResource("CaptionText"), Margin = new Thickness(8, 0, 8, 0),
                    VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap,
                });
            var label = new TextBlock { Text = keys[index].Label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap };
            System.Windows.Documents.Typography.SetNumeralAlignment(label, FontNumeralAlignment.Tabular);
            ScreenKeys.Children.Add(new Border { Style = (Style)FindResource("Keycap"), Child = label });
        }
    }

    private async void OnUpdate(object sender, RoutedEventArgs e) => await controller.InstallUpdateAsync();

    private void Refresh()
    {
        var running = controller.IsRunning;
        // Deneme modunda düğme "Deneme modundan çık" olur; durum karosu "Deneme modu · Örnek görüntüler" yazar.
        var demo = controller.DemoMode;
        Toggle.Style = (Style)FindResource(running || demo ? "DangerButton" : "PrimaryButton");
        ToggleGlyph.Text = demo ? Glyphs.Cancel : running ? Glyphs.Stop : Glyphs.Play;
        ToggleText.Text = Localizer.Current[demo ? "Exit demo mode" : running ? "Stop translating" : "Start translating"];
        // Altyazının gideceği bir yer yoksa (TV seçili ama bağlı değil) çeviri başlatılamaz.
        Toggle.IsEnabled = !controller.IsStarting && (running || demo || controller.CanStart);
        ConsoleStatus.Glyph = demo ? Glyphs.Play : Glyphs.Controller;
        DemoButton.Visibility = !controller.CanStart && !running && !demo ? Visibility.Visible : Visibility.Collapsed;
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
            if (controller.DemoMode) controller.ExitDemo();
            else if (starting) await controller.StartAsync(); else controller.Stop();
        }
        catch (Exception error)
        {
            StartupGuard.Log(starting ? "Çeviri başlatılamadı" : "Çeviri durdurulamadı", error);
            StartupGuard.Show(Application.Current, StartupGuard.ErrorMessage(error));
        }
    }

    private void OnSettings(object sender, RoutedEventArgs e) => SettingsWindow.Open(Window.GetWindow(this), controller);

    private void OnTranslationSettings(object sender, RoutedEventArgs e) =>
        SettingsWindow.Open(Window.GetWindow(this), controller, SettingsSection.Translation);

    private void OnPictureSourceSettings(object sender, RoutedEventArgs e) =>
        SettingsWindow.Open(Window.GetWindow(this), controller, SettingsSection.PictureSource);

    /// <summary>Yeni canlı satır 0,18 sn'de belirir; Windows'ta animasyonlar kapalıysa geçiş yok (docs/TASARIM.md).</summary>
    private void FadeInLiveLine()
    {
        if (!SystemParameters.ClientAreaAnimation)
        {
            LiveLine.BeginAnimation(OpacityProperty, null);
            return;
        }
        LiveLine.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
        });
    }

    /// <summary>
    /// Son satır büyük ve sarı yazılır; bu oturumda ondan önce gösterilen satırlar altında, en yenisi üstte (geçmiş en
    /// yeniden eskiye sıralıdır). Son satır geçmişin en yenisiyse listede tekrar edilmez. Henüz satır yokken liste boştur.
    /// </summary>
    private void ShowPreviousLines()
    {
        if (string.IsNullOrEmpty(controller.LastTranslation))
        {
            PreviousLines.ItemsSource = null;
            return;
        }
        var since = sessionStartedAt ?? DateTime.MinValue;
        var lines = controller.History.Where(entry => entry.Date >= since).ToList();
        if (lines.Count > 0 && lines[0].Translation == controller.LastTranslation) lines.RemoveAt(0);
        PreviousLines.ItemsSource = lines.Take(PreviousLineCount).ToList();
    }

    private void OnHistory(object sender, RoutedEventArgs e) => HistoryWindow.Open(Window.GetWindow(this), controller);

    /// <summary>Deneme altyazısı (çeviri başlamadıysa altyazı sunucusu da açılır).</summary>
    private async void OnTest(object sender, RoutedEventArgs e)
    {
        try { await controller.SendTestSubtitleAsync(); }
        catch (Exception error) { StartupGuard.Log("Deneme altyazısı gönderilemedi", error); }
    }

    /// <summary>TV'siz kurulmuş uygulamada TV'yi sonradan bağlamak ya da TV'yi değiştirmek için sihirbazın TV adımı açılır.</summary>
    private void OnConnectTv(object sender, RoutedEventArgs e) => controller.Step = OnboardingStep.Tv;

    /// <summary>TV adımı açılır (kurulum kartı orada görünür) ve TV'ye yeniden bakılır.</summary>
    /// <summary>TV uygulaması bağlı değil: bekçi TV uygulamasını beklemeden yeniden açmaya çalışır.</summary>
    private void OnRetryTvOpen(object sender, RoutedEventArgs e) => controller.RetryTvOpen();
    private void OnLinkXbox(object sender, RoutedEventArgs e) => controller.LinkXbox();

    private void OnReconnect(object sender, RoutedEventArgs e) => controller.Reconnect();

    // "Yeniden kur" ve "Güncelle" ana ekranda kurar (kart TV karosunun altında açılır); TV adımına gidilmez.
    private async void OnReinstallTvApp(object sender, RoutedEventArgs e) => await controller.UpdateTvAppAsync();

    private async void OnUpdateTvApp(object sender, RoutedEventArgs e) => await controller.UpdateTvAppAsync();

    private void OnDismissTvAppUpdate(object sender, RoutedEventArgs e) => controller.DismissTvAppUpdate();

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
            controller.StopForRestart();
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
        // Deneme karelerinde oyun yoktur: oyun karosu gösterilmez.
        GameCard.Visibility = controller.IsRunning && !controller.DemoMode ? Visibility.Visible : Visibility.Collapsed;
        var asking = controller.AskingGame;
        GameRow.Visibility = asking ? Visibility.Collapsed : Visibility.Visible;
        GameAsk.Visibility = asking ? Visibility.Visible : Visibility.Collapsed;
        PlayedGameText.Text = controller.PlayedGame ?? text["Not known"];
        GameChangeButton.Content = text[controller.PlayedGame is null ? "Choose" : "Change"];
        if (asking) ShowGameSuggestions();
        else GameSearch.Text = "";
        ShowAreaProfile(asking);
    }

    /// <summary>
    /// Oyunun kayıtlı alanları: uygulandıysa "X için kayıtlı alanlar kullanılıyor · Geri al"; oyun yalnız paketten
    /// tanındıysa "X için kayıtlı alanlar var. Kullanılsın mı? · Kullan / Hayır" (Mac, iPhone ve Android ile aynı).
    /// </summary>
    private void ShowAreaProfile(bool asking)
    {
        var text = Localizer.Current;
        var offered = controller.OfferedAreaProfileGame;
        var active = controller.AreaProfileGame;
        AreaProfileRow.Visibility = !asking && (offered ?? active) is not null ? Visibility.Visible : Visibility.Collapsed;
        AreaProfileUse.Visibility = AreaProfileNo.Visibility = offered is not null ? Visibility.Visible : Visibility.Collapsed;
        AreaProfileUndo.Visibility = offered is null && active is not null ? Visibility.Visible : Visibility.Collapsed;
        AreaProfileText.Text = offered is not null ? text.Format("Saved areas for %@ are available. Use them?", offered)
            : active is not null ? text.Format("Using the saved areas for %@.", active) : "";
    }

    private void OnUseAreaProfile(object sender, RoutedEventArgs e) => controller.UseOfferedAreaProfile();
    private void OnDeclineAreaProfile(object sender, RoutedEventArgs e) => controller.DeclineOfferedAreaProfile();
    private void OnUndoAreaProfile(object sender, RoutedEventArgs e) => controller.UndoAreaProfile();

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
