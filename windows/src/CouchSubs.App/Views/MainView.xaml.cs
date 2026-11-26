// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Hyperlink = System.Windows.Documents.Hyperlink;
using Run = System.Windows.Documents.Run;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using CouchSubs.App.Controls;
using CouchSubs.App.Theme;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>
/// Ana ekran (Perde): perde ve üç düğme, dört durum karosu, bildirimler, Canlı Akış ya da "Sorun Var" kartı. Saniyede bir
/// kare hızı, sessizlik ve sayılar yenilenir. Çeviri sürerken yalnız canlı nabız atar (hareket kapısı).
/// </summary>
public partial class MainView : UserControl
{
    private readonly AppController controller;
    private string? notesVersion;
    private bool notesUnavailable;
    // Çeviri sürerken PS5 ve TV bağlanamıyorsa güvenlik duvarı kartı önerilir.
    private readonly DispatcherTimer connectionWatch = new() { Interval = TimeSpan.FromSeconds(5) };
    /// <summary>Kare hızı, sessizlik nedeni ve durum karoları saniyede bir yenilenir.</summary>
    private readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromSeconds(1) };
    /// <summary>Canlı akış ve durum karoları yalnız bu oturumun satırlarını sayar (önceki oturumlar Geçmiş'te).</summary>
    private DateTime? sessionStartedAt;
    /// <summary>Canlı akışta en çok bu kadar satır durur.</summary>
    private const int FeedLineCount = 20;
    private int framesThisSecond;
    private int framesPerSecond;

    public MainView(AppController controller)
    {
        this.controller = controller;
        DataContext = controller;
        InitializeComponent();
        controller.PropertyChanged += OnChanged;
        connectionWatch.Tick += async (_, _) => await controller.CheckConnectionsAsync();
        tick.Tick += (_, _) => OnTick();
        // Uzun pencerede perde boş yüksekliği doldurur (sol sütun en az 2/3, en çok %70), kalan boşlukta içerik cam
        // çubukların arasında dikeyde ortalanır (Mac HomeStage.leftWidth).
        Page.SizeChanged += (_, _) => FitStage();
        Loaded += (_, _) =>
        {
            connectionWatch.Start();
            tick.Start();
            Preview.SetFrame(controller.LastFrame);
        };
        Services.CrashWatch.Changed += OnCrashChanged;
        Unloaded += (_, _) =>
        {
            connectionWatch.Stop();
            tick.Stop();
        };
        if (controller.IsRunning) sessionStartedAt = DateTime.UtcNow;
        ShowCrash();
        Refresh();
        ShowChips();
        ShowUpdate();
        ShowGame();
        ShowFeed();
        ShowNotices();
        OnTick();
        Preview.SetRegion(controller.Settings.Region);
        Preview.SetLine(controller.IsRunning ? controller.LastTranslation : null);
        _ = controller.CheckForUpdateAsync();
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppController.LastFrame):
                framesThisSecond++;
                if (IsVisible) Preview.SetFrame(controller.LastFrame);
                return;
            case nameof(AppController.IsRunning):
                if (controller.IsRunning) sessionStartedAt = DateTime.UtcNow;
                break;
        }
        if (e.PropertyName is nameof(AppController.IsRunning) or nameof(AppController.TranslatorStatus) or nameof(AppController.ModelInstalled)
            or nameof(AppController.OnlineIssue) or nameof(AppController.CanStart) or nameof(AppController.IsStarting)
            or nameof(AppController.DemoMode))
            Refresh();
        if (e.PropertyName is nameof(AppController.Settings) or nameof(AppController.InstalledPacks) or nameof(AppController.PlayedGame)
            or nameof(AppController.XboxNeedsGame) or nameof(AppController.IsRunning) or nameof(AppController.Ps5Tone) or nameof(AppController.TvTone) or nameof(AppController.TvClients)
            or nameof(AppController.DemoMode) or nameof(AppController.CanStart) or nameof(AppController.TranslatorStatus) or nameof(AppController.OnlineIssue)
            or nameof(AppController.TvReconnecting) or nameof(AppController.TvStatusText))
            ShowChips();
        if (e.PropertyName is nameof(AppController.Settings))
            Preview.SetRegion(controller.Settings.Region);
        if (e.PropertyName is nameof(AppController.IsRunning) or nameof(AppController.DemoMode) or nameof(AppController.PlayedGame) or nameof(AppController.AskingGame)
            or nameof(AppController.XboxNeedsGame) or nameof(AppController.AreaProfileGame) or nameof(AppController.OfferedAreaProfileGame))
            ShowGame();
        if (e.PropertyName is nameof(AppController.LastTranslation) or nameof(AppController.IsRunning))
            Preview.SetLine(controller.IsRunning ? controller.LastTranslation : null);
        if (e.PropertyName is nameof(AppController.History) or nameof(AppController.LastTranslation) or nameof(AppController.IsRunning))
        {
            ShowFeed();
            ShowStats();
        }
        if (e.PropertyName is nameof(AppController.MetricsText)) ShowStats();
        if (e.PropertyName is nameof(AppController.UpdateVersion) or nameof(AppController.Updating)
            or nameof(AppController.UpdateProgress) or nameof(AppController.UpdateError))
            ShowUpdate();
        if (e.PropertyName is nameof(AppController.NeedsXboxLink) or nameof(AppController.OffersReconnect) or nameof(AppController.ShowsOnTv)
            or nameof(AppController.NeedsTv) or nameof(AppController.CanReconnectTv) or nameof(AppController.ShowTvAppUpdate)
            or nameof(AppController.CanReinstallTvApp) or nameof(AppController.ShowTvOpenHint) or nameof(AppController.ShowTestTvHint)
            or nameof(AppController.TvAppUpdating) or nameof(AppController.TvClients) or nameof(AppController.IsRunning)
            or nameof(AppController.Settings) or nameof(AppController.CanStart) or nameof(AppController.DemoMode))
            ShowNotices();
    }

    /// <summary>Saniyede bir: kare hızı, CANLI hapı, sessizlik nedeni ve durum karoları.</summary>
    private void OnTick()
    {
        framesPerSecond = framesThisSecond;
        framesThisSecond = 0;
        var text = Localizer.Current;
        var running = controller.IsRunning;
        Preview.SetLive(running);
        // Kaynak + kare hızı (pencereden okunurken kaynak adı yok; Mac frameRate).
        var rate = text.Format("%lld Frames/s", framesPerSecond);
        var windowSource = controller.IsXbox ? controller.XboxReadsWindow : controller.Settings.FrameSource == FrameSource.CaptureWindow;
        Preview.SetRate(running ? windowSource ? rate : $"{(controller.IsXbox ? "Xbox" : "PS5")} · {rate}" : null);
        ShowProblem();
        ShowStats();
    }

    private void FitStage()
    {
        if (Page.ActualWidth <= 0) return;
        var inset = Body.Parent is Border holder ? holder.Padding : new Thickness(0);
        var gap = Sp.V("l");
        var total = Math.Max(0, Page.ActualWidth - 2 * gap - gap);
        var free = Page.ActualHeight - inset.Top - inset.Bottom - 2 * gap;
        var fill = (free - Sp.V("m") - Palette.Size["button"]) * 16 / 9;
        var left = Math.Floor(Math.Min(Math.Max(total * 2 / 3, fill), total * 0.7));
        Body.ColumnDefinitions[0].Width = new GridLength(Math.Max(0, left));
        Body.ColumnDefinitions[2].Width = new GridLength(1, GridUnitType.Star);
        Body.MinHeight = Math.Max(0, free);
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

    private void OnEnableGamePhone(object sender, RoutedEventArgs e) => controller.EnableGamePhone();

    private void OnDismissGamePhoneHint(object sender, RoutedEventArgs e) => controller.DismissGamePhoneHint();

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
        UpdateTitle.Text = controller.UpdateTitle;
        UpdateButton.Content = controller.UpdateButtonText;
        UpdateButton.IsEnabled = !controller.Updating;
        UpdateBar.Visibility = controller.Updating ? Visibility.Visible : Visibility.Collapsed;
        UpdateBar.Value = controller.UpdateProgress;
        var problem = controller.UpdateError ?? controller.UpdateHint;
        UpdateErrorText.Text = problem ?? "";
        UpdateErrorText.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
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

    private async void OnUpdate(object sender, RoutedEventArgs e) => await controller.InstallUpdateAsync();

    private void Refresh()
    {
        var text = Localizer.Current;
        var running = controller.IsRunning;
        // Deneme modunda düğme "Deneme Modundan Çık" olur.
        var demo = controller.DemoMode;
        Toggle.Style = (Style)FindResource(running || demo ? "LiveButton" : "PrimaryButton");
        Toggle.Content = text[controller.IsStarting ? "Starting…" : demo ? "Exit Demo Mode" : running ? "Stop Translating" : "Start Translating"];
        // Altyazının gideceği bir yer yoksa (TV seçili ama bağlı değil) çeviri başlatılamaz.
        Toggle.IsEnabled = !controller.IsStarting && (running || demo || controller.CanStart);
        ModelCard.Visibility = controller.ModelInstalled ? Visibility.Collapsed : Visibility.Visible;
        EngineCard.Visibility = controller.TranslatorStatus == TranslatorStatus.EngineFailed ? Visibility.Visible : Visibility.Collapsed;
        // Çevrimiçi motor çeviremiyor; satırlar bu arada cihaz üstü modelle geliyor.
        var issue = running ? controller.OnlineIssue : null;
        OnlineCard.Visibility = issue is null ? Visibility.Collapsed : Visibility.Visible;
        if (issue is { } state)
        {
            var engine = controller.Settings.OnlineEngine;
            OnlineTitle.Text = text.Format("%@ is not translating right now", engine.DisplayName());
            // Cihaz üstü model kurulu değilse ya da açılamadıysa "ücretsiz çeviri kullanılıyor" denmez: bu arada yalnız
            // oyun paketleri çevirir (GitHub #1322; Mac ve iPhone ile aynı metin).
            var freeTranslation = controller.ModelInstalled && controller.TranslatorStatus != TranslatorStatus.EngineFailed;
            OnlineReason.Text = state.Describe(engine, text, controller.Settings.LocalAiServer) + " "
                + text[freeTranslation ? "Meanwhile the free translation is used." : "The free translation doesn't work on this system, so meanwhile only game packs translate."];
        }
        Preview.SetLive(running);
        ShowNotices();
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

    private void OnSettings(object sender, RoutedEventArgs e) => SettingsView.Open(Window.GetWindow(this), controller);

    // Durum karoları ilgili ayara gider (Mac HomeTile): konsol → Konsol ve Kaynak, TV → Ayarlar (TV kurulmadıysa TV adımı),
    // oyun → "Hangi Oyun?", çeviri → Çeviri.
    private void OnConsoleTile(object sender, RoutedEventArgs e)
    {
        if (controller.NeedsXboxLink) controller.LinkXbox();
        else SettingsView.Open(Window.GetWindow(this), controller, SettingsSection.PictureSource);
    }

    private void OnTvTile(object sender, RoutedEventArgs e)
    {
        if (controller.ShowsOnTv && !controller.HasTv) controller.Step = OnboardingStep.Tv;
        else SettingsView.Open(Window.GetWindow(this), controller, SettingsSection.Appearance);
    }

    private void OnGameTile(object sender, RoutedEventArgs e) => controller.AskGame();

    private void OnEngineTile(object sender, RoutedEventArgs e) => SettingsView.Open(Window.GetWindow(this), controller, SettingsSection.Translation);

    private void OnTranslationSettings(object sender, RoutedEventArgs e) =>
        SettingsView.Open(Window.GetWindow(this), controller, SettingsSection.Translation);

    private void OnPictureSourceSettings(object sender, RoutedEventArgs e) =>
        SettingsView.Open(Window.GetWindow(this), controller, SettingsSection.PictureSource);

    /// <summary>Kabuk bu ana ekranı bırakınca (kurulum yeniden açıldı) denetleyiciden ayrılır.</summary>
    public void Detach()
    {
        controller.PropertyChanged -= OnChanged;
        Services.CrashWatch.Changed -= OnCrashChanged;
        connectionWatch.Stop();
        tick.Stop();
    }

    /// <summary>
    /// Dört durum karosu (Mac StatusTiles): konsol (ya da seçilen pencere / deneme), TV (ya da bilgisayar ekranı), oynanan oyun
    /// (kapağıyla), çeviri motoru. Yeşil nokta hazır ya da bağlı, kırmızı sorun, gri kurulmamış ya da bekliyor demektir.
    /// </summary>
    private void ShowChips()
    {
        var text = Localizer.Current;
        var settings = controller.Settings;
        var running = controller.IsRunning;
        var consoleTone = controller.DemoMode ? StatusTone.Good : running ? controller.Ps5Tone : controller.CanStart ? StatusTone.Good : StatusTone.Idle;
        var shortState = running ? controller.Ps5Tone switch { StatusTone.Good => text["Connected"], StatusTone.Warning => text["Not Connected"], _ => text["Connecting…"] } : null;
        if (controller.DemoMode)
            ConsoleTile.Show(text["Demo Mode"], text["Sample pictures"], null, consoleTone, Glyphs.Play, IconTone.Amber);
        else if (controller.IsXbox ? controller.XboxReadsWindow : controller.Settings.FrameSource == FrameSource.CaptureWindow)
            ConsoleTile.Show(text["Window"], controller.ConsoleTitle, shortState, consoleTone, "\uE8A7", IconTone.Gray);
        else if (controller.IsXbox)
            ConsoleTile.Show(text["Xbox · Beta"], "Xbox", shortState, consoleTone, "\uE7FC", IconTone.Olive);
        else
            ConsoleTile.Show("PS5", controller.Console?.Name is { Length: > 0 } name ? name : controller.CanStart ? "PS5" : text["Not Set Up"],
                shortState ?? (controller.CanStart ? text["Ready"] : null), consoleTone, "\uE7FC", IconTone.Gray);

        if (!controller.ShowsOnTv) TvTile.Show(text["Computer Screen"], text["This PC"], null, StatusTone.Good, "\uE7F8", IconTone.Teal);
        else if (!controller.HasTv) TvTile.Show("TV", text["Not Set Up"], null, StatusTone.Idle, "\uE7F4", IconTone.Gray);
        else
        {
            var tone = controller.TvTone == StatusTone.Warning ? StatusTone.Warning : controller.TvClients > 0 || !running ? StatusTone.Good : StatusTone.Idle;
            // TV koptuysa bir dakika "Yeniden bağlanılıyor…" (TV alındısı; Mac ile aynı), sonra "Bekleniyor".
            var more = controller.TvClients > 0 ? null : controller.TvReconnecting ? text["Reconnecting…"] : running ? text["Waiting"] : null;
            TvTile.Show("TV", controller.Tv?.Name ?? "TV", more, tone, "\uE7F4", IconTone.Amber);
        }

        var packs = GameCatalog.PackShelf(controller.InstalledPacks);
        var game = controller.PlayedGame;
        var hasPack = game is not null && settings.GamePacks && packs.Any(item => item.Titles.Append(item.Title).Any(title => GameName.Key(title) == GameName.Key(game)));
        // Xbox oynanan oyunu bildirmez: oyun seçilmediyse karo amber halkayla vurgulanır (zorlayıcı kart açılmaz).
        var needsGame = controller.XboxNeedsGame;
        GameTile.Show(text["Game"], game ?? text["Not Recognized"], hasPack ? text["Pack"] : needsGame ? text["Choose"] : null,
            needsGame ? StatusTone.Warning : game is null ? StatusTone.Idle : StatusTone.Good, "\uE9CE", IconTone.Gray, game, needsGame);

        var engineTone = controller.TranslatorStatus == TranslatorStatus.EngineFailed || (running && controller.OnlineIssue is not null) ? StatusTone.Warning : StatusTone.Good;
        var engine = settings.Engine == TranslationEngine.Free ? text["Free Translation"] : settings.Engine.DisplayName();
        EngineTile.Show(text["Translation"], engine, $"{settings.SourceLanguage.ToUpperInvariant()}→{settings.TargetLanguage.ToUpperInvariant()}", engineTone, "\uF2B7", IconTone.Sky);

        // Ekranı Çevir düğmesinin kısayolu ipucunda (Ayarlar › Klavye Kısayolları).
        ScreenButton.ToolTip = HotkeyText.Title(settings, HotkeyAction.Screen, "Translate the screen (%@)");
    }

    /// <summary>Sağ sütundaki konsol ve TV bildirim kartları yalnız yapılacak bir şey varken görünür.</summary>
    private void ShowNotices()
    {
        ConsoleCard.Visibility = controller.NeedsXboxLink || controller.OffersReconnect ? Visibility.Visible : Visibility.Collapsed;
        var tvNeedsWork = controller.ShowsOnTv && (controller.NeedsTv || controller.CanReconnectTv && controller.IsRunning || controller.ShowTvAppUpdate
            || controller.CanReinstallTvApp || controller.ShowTvOpenHint || controller.ShowTestTvHint || controller.TvAppUpdating);
        TvCard.Visibility = tvNeedsWork ? Visibility.Visible : Visibility.Collapsed;
        DemoButton.Visibility = !controller.CanStart && !controller.IsRunning && !controller.DemoMode ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>
    /// Durum karoları: bu oturumun satır sayısı ve son dakikadaki hızı (kıvılcım çizgisi 15 sn'lik dilimler), paketten
    /// gelen satırlar ve oranı, son satırların ortalama gecikmesi.
    /// </summary>
    private void ShowStats()
    {
        var text = Localizer.Current;
        var now = DateTime.UtcNow;
        var since = sessionStartedAt ?? DateTime.MaxValue;
        var lines = controller.History.Where(entry => entry.Date >= since).ToList();
        var perMinute = lines.Count(entry => now - entry.Date <= TimeSpan.FromMinutes(1));
        LineCount.Text = lines.Count.ToString(CultureInfo.CurrentCulture);
        LineRate.Text = text.Format("Lines · %lld/min", perMinute);
        LineSpark.Values = Enumerable.Range(0, 12).Select(slot =>
        {
            var end = now - TimeSpan.FromSeconds(15 * (11 - slot));
            var start = end - TimeSpan.FromSeconds(15);
            return (double)lines.Count(entry => entry.Date > start && entry.Date <= end);
        }).ToList();
        var fromPack = lines.Count(entry => entry.Origin == LineOrigin.Pack);
        var share = lines.Count == 0 ? 0 : (int)Math.Round(100.0 * fromPack / lines.Count);
        PackCount.Text = fromPack.ToString(CultureInfo.CurrentCulture);
        PackShare.Text = text.Format("From Pack · %lld%%", share);
        var delays = controller.RecentDelaysMs;
        DelayValue.Text = delays.Count == 0 ? "–" : $"{(int)Math.Round(delays.Average())} ms";
        // Akış boşken durum hapı: çeviri sürüyorsa amber "Altyazı Bekleniyor", değilse gri "Çeviri Durdu".
        StateChip.Text = text[controller.IsRunning ? "Waiting for Subtitles" : "Translation Stopped"];
        StateChip.Tone = controller.IsRunning ? ChipTone.Amber : ChipTone.Muted;
    }

    /// <summary>
    /// "Sorun Var" kartı (HomeProblem): görüntü durdu, menü açık ya da oyunun altyazısı kapalı. Kart görünürken Durum kartı
    /// gizlenir; çözüm düğmeleri işi yapar ya da ilgili ayarı açar.
    /// </summary>
    private void ShowProblem()
    {
        var text = Localizer.Current;
        var now = DateTime.UtcNow;
        var kind = HomeProblem.For(controller.IsRunning, controller.DemoMode, controller.LastFrameAt is { } at ? now - at : null,
            controller.ScreenMenuOpen, controller.ShowsSubtitleOffTip);
        ProblemCard.Visibility = kind == HomeProblemKind.None ? Visibility.Collapsed : Visibility.Visible;
        FeedCard.Visibility = kind == HomeProblemKind.None ? Visibility.Visible : Visibility.Collapsed;
        if (kind == HomeProblemKind.None)
        {
            shownProblem = kind;
            return;
        }
        var lastLine = controller.History.FirstOrDefault()?.Date;
        var silent = HomeProblem.SilentSeconds(now, lastLine, sessionStartedAt ?? now);
        SilentFor.Text = controller.IsRunning ? text.Format("%lld s silent", silent) : text["Issue"];
        var pictureGap = controller.LastFrameAt is { } last ? (int)(now - last).TotalSeconds : 0;
        switch (kind)
        {
            case HomeProblemKind.PictureStopped:
                ProblemTitle.Text = text.Format("The PS5 picture hasn't arrived for %lld seconds.", pictureGap);
                ProblemText.Text = text["The connection may have weakened. CouchSubs is trying to reconnect; if it doesn't, check that you're on the same Wi-Fi network as the PS5 and using 5 GHz."];
                break;
            case HomeProblemKind.MenuOpen:
                ProblemTitle.Text = text["A menu is open in the game; there's no subtitle."];
                ProblemText.Text = text["We don't translate the text in the pause menu. The subtitles come back by themselves when you return to the game."];
                break;
            default:
                ProblemTitle.Text = text["Game Subtitles Off?"];
                ProblemText.Text = text["CouchSubs reads the English subtitles on screen, not the audio. Turn on the game's own subtitles."];
                break;
        }
        if (kind == shownProblem) return;
        shownProblem = kind;
        Motion.EnterFrom(ProblemCard, -8);
        ProblemFixes.Children.Clear();
        switch (kind)
        {
            case HomeProblemKind.PictureStopped:
                AddFix(text["Reconnect Now"], null, primary: true, () => controller.Reconnect());
                AddFix(text["Open the Connection Test"], null, primary: false,
                    () => SettingsView.Open(Window.GetWindow(this), controller, SettingsSection.PictureSource));
                break;
            case HomeProblemKind.MenuOpen:
                var on = controller.Settings is { AutoScreenText: true, ScreenTextMenus: true };
                AddFix(text["Translate Menus Too (On-Screen Text)"], text[on ? "Completed" : "Off"], primary: !on,
                    () => controller.Settings = controller.Settings with { AutoScreenText = true, ScreenTextMenus = true });
                break;
            default:
                AddFix(text["Draw the Area Manually"], null, primary: false, () => SettingsView.Open(Window.GetWindow(this), controller));
                break;
        }
    }

    private HomeProblemKind shownProblem;

    /// <summary>Çözüm düğmesi: 48 yüksek, solda iş, sağda mono durum ("Kapalı" / "Yapıldı"); ilki amber.</summary>
    private void AddFix(string label, string? state, bool primary, Action run)
    {
        var row = new DockPanel { LastChildFill = true };
        if (state is not null)
        {
            var mark = new TextBlock { Text = state, VerticalAlignment = VerticalAlignment.Center, Margin = Sp.T("s", "0", "0", "0") };
            mark.SetResourceReference(StyleProperty, "MonoText");
            mark.FontSize = 12;
            DockPanel.SetDock(mark, Dock.Right);
            row.Children.Add(mark);
        }
        row.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap });
        var button = new Button
        {
            Content = row, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = Sp.T("m", "0", "m", "0"), Margin = Sp.T("0", "0", "0", "xs"),
        };
        button.SetResourceReference(StyleProperty, primary ? "PrimaryButton" : "SecondaryButton");
        button.Click += (_, _) =>
        {
            run();
            shownProblem = HomeProblemKind.None;
            ShowProblem();
        };
        ProblemFixes.Children.Add(button);
    }

    /// <summary>Canlı akış: bu oturumun satırları (çeviri yokken son satırlar), en yenisi üstte.</summary>
    private void ShowFeed()
    {
        var since = controller.IsRunning ? sessionStartedAt ?? DateTime.MinValue : DateTime.MinValue;
        var lines = controller.History.Where(entry => entry.Date >= since).Take(FeedLineCount).ToList();
        Feed.ItemsSource = lines.Select((entry, index) =>
        {
            var (speaker, line) = SubtitlePlate.Split(entry.Translation);
            return new FeedLine(speaker?.TrimEnd(':'), line, entry.Source, Math.Min(index, 2));
        }).ToList();
        FeedEmpty.Visibility = lines.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnHistory(object sender, RoutedEventArgs e) => ShellWindow.Navigate(ShellTab.History);

    /// <summary>Ekranı Çevir (kısayoldaki gibi): ekranın tamamı bir kez çevrilir.</summary>
    private async void OnTranslateScreen(object sender, RoutedEventArgs e)
    {
        try { await controller.TranslateScreenAsync(); }
        catch (Exception error) { StartupGuard.Log("Ekran çevrilemedi", error); }
    }

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
        var wasAsking = GameAsk.Visibility == Visibility.Visible;
        GameAsk.Visibility = asking ? Visibility.Visible : Visibility.Collapsed;
        // Kart açıkken ana ekran bulanıklaşır ve soluklaşır (tasarım: filter blur(2px), opacity .5).
        Body.Effect = asking ? new System.Windows.Media.Effects.BlurEffect { Radius = 4 } : null;
        Body.Opacity = asking ? 0.5 : 1;
        if (asking && !wasAsking) Theme.Motion.EnterFrom((FrameworkElement)GameAsk.Children[0], 12, Theme.Motion.Page);
        PlayedGameText.Text = controller.PlayedGame ?? text["Not known"];
        GameChangeButton.Content = text[controller.PlayedGame is null ? "Choose" : "Change"];
        XboxGameNote.Visibility = controller.XboxNeedsGame && !asking ? Visibility.Visible : Visibility.Collapsed;
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

    /// <summary>
    /// Kapak rafı (Perde DSCoverShelf): en çok beş öneri, 3:4 kapak (adından degrade, kalın beyaz ad); paketi olan "Paket Var",
    /// son oynanan "Son Oynanan" cam hapıyla; seçili oyun amber halka + kapak ışıması.
    /// </summary>
    private void ShowGameSuggestions()
    {
        var text = Localizer.Current;
        var typed = GameSearch.Text.Trim();
        GameSearchHint.Visibility = typed.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var suggestions = controller.GameSuggestions(typed).Take(5).ToList();
        var last = controller.LastPlayedGame;
        var shelf = GameCatalog.PackShelf(controller.InstalledPacks);
        var chosen = controller.PlayedGame is { } played ? GameName.Key(played) : null;
        GameList.Children.Clear();
        foreach (var name in suggestions)
        {
            var hasPack = shelf.Any(item => item.Titles.Append(item.Title).Any(title => GameName.Key(title) == GameName.Key(name)));
            var status = hasPack ? text["Pack Available"] : name == last ? text["Last Played"] : null;
            var cover = new GameCover(name, status, GameName.Key(name) == chosen) { Margin = GameList.Children.Count == 0 ? new Thickness(0) : Sp.T("s", "0", "0", "0") };
            cover.Click += (_, _) => controller.ChooseGame(name);
            GameList.Children.Add(cover);
        }
    }

    /// <summary>Kapak rafı yatay kayar (kaydırma çubuğu gizli, Mac gibi): fare tekerleği rafı yana kaydırır.</summary>
    private void OnShelfWheel(object sender, System.Windows.Input.MouseWheelEventArgs e)
    {
        GameShelf.ScrollToHorizontalOffset(GameShelf.HorizontalOffset - e.Delta / 2.0);
        e.Handled = true;
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

    /// <summary>"Listede Yok": yazılan ad kullanılır; bir şey yazılmadıysa arama kutusuna odaklanılır.</summary>
    private void OnCustomGame(object sender, RoutedEventArgs e)
    {
        if (GameSearch.Text.Trim() is { Length: > 0 } typed) controller.ChooseGame(typed);
        else GameSearch.Focus();
    }
}
