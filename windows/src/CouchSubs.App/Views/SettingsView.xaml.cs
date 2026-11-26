// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using CouchSubs.App.Theme;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Navigation;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CouchSubs.App.Services;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.Shell;
using Microsoft.Win32;

namespace CouchSubs.App.Views;

/// <summary>Ayarların doğrudan açılabilen bölümleri.</summary>
public enum SettingsSection { Appearance, Translation, PictureSource }

public partial class SettingsView : UserControl
{
    private static readonly (string Code, string Name)[] Languages =
        [("en", "English"), ("ja", "Japanese"), ("de", "German"), ("fr", "French"), ("es", "Spanish")];

    private readonly AppController controller;
    private bool loading = true;
    /// <summary>Çerçevesi düzenlenen alan: 0 altyazı, 1, 2 ve 3 sıradaki ek alanlar.</summary>
    private int area;
    /// <summary>Önizlemenin oyun görüntüsüyle son yenilendiği an (ms).</summary>
    private long lastPreview;
    /// <summary>Kısayollar'da yeni tuşu bekleyen yuva; null ise beklenmiyor.</summary>
    private (HotkeyAction Action, int Slot, Button Button)? recording;
    /// <summary>Kısayollar'daki düğmeler: iş ve yuvaya göre.</summary>
    private readonly Dictionary<(HotkeyAction, int), Button> shortcutButtons = [];

    internal SettingsView(AppController controller)
    {
        this.controller = controller;
        controller.NoteScreen("settings");
        InitializeComponent();
        InstalledVersion.Text = Localizer.Current.Format("Installed version: %@", AppVersion.Current(typeof(SettingsView).Assembly));
        var settings = controller.Settings;
        DataContext = controller;
        GeminiPaidTier.IsChecked = settings.GeminiPaidTier;
        TextSize.Value = Math.Clamp(settings.Style.FontSize, TextSize.Minimum, TextSize.Maximum);
        TextSizeValue.Text = ((int)TextSize.Value).ToString();
        Position.Value = settings.Style.BottomPercent;
        Placement.SelectedItem = Placement.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Style.Placement.ToString());
        ShowPlacement(settings.Style.Placement);
        BackgroundOpacity.Value = settings.Style.Background;
        BackgroundShape.SelectedItem = BackgroundShape.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Style.BackgroundShape.ToString());
        Bold.IsChecked = settings.Style.Bold;
        StackPrevious.IsChecked = settings.Style.StackPrevious;
        MisreadWait.Value = settings.MisreadWaitMs / 1000.0;
        PartialWait.Value = settings.PartialWaitMs / 1000.0;
        ShowWaits();
        TextColor.SelectedItem = TextColor.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Style.TextColor.ToString());
        DisplayMode.SelectedItem = DisplayMode.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Style.DisplayMode.ToString());
        // Yalnız çeviri modeli olan diller listelenir; tek dil varsa seçim gösterilmez.
        foreach (var (code, name) in Languages.Where(l => controller.SupportsLanguage(l.Code)))
            GameLanguage.Items.Add(new ComboBoxItem { Content = Localizer.Current[name], Tag = code, IsSelected = code == settings.SourceLanguage });
        LanguageCard.Visibility = GameLanguage.Items.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        (settings.FreeAreaTarget switch { ResultTarget.Pc => FreePc, ResultTarget.Both => FreeBoth, _ => FreeTv }).IsChecked = true;
        Region.Frame = controller.LastFrame;
        ObsAddress.Text = controller.ObsAddress;
        LegacyTvWarning.Visibility = controller.LegacyTvWarning ? Visibility.Visible : Visibility.Collapsed;
        // Localhost'u kabul etmeyen yayın programları (TikTok LIVE Studio) için aynı adres bilgisayarın ağ adresiyle.
        if (controller.NetworkObsAddress is { } networkObs) NetworkObsAddress.Text = networkObs;
        else NetworkObsPanel.Visibility = Visibility.Collapsed;
        var streamBackground = controller.StreamBackground.ToString();
        StreamBackgroundChoice.SelectedItem = StreamBackgroundChoice.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == streamBackground);
        ShowArea(0);
        ShowAreaProfile();
        GameProfilesHint.Text = Localizer.Current["Each game keeps its own subtitle area and extra areas. A game that isn't in the list can be added by typing its name; one profile never overwrites another."];
        ShowGameProfiles();
        // Num 8: oyunun o anki görüntüsü önizlemeye alınır.
        controller.SnapshotRequested += OnSnapshot;
        Unloaded += (_, _) => controller.SnapshotRequested -= OnSnapshot;
        Dubbing.Attach(controller);
        FirewallSettings.Attach(controller);
        OutputCard.Attach(controller);
        SecondScreenCard.Attach(controller);
        ShowStyleTitle();
        controller.PropertyChanged += OnControllerChanged;
        Unloaded += (_, _) => controller.PropertyChanged -= OnControllerChanged;
        // Eşli TV kartı görünürken TV uygulaması bağlı değilse ~10 sn'de bir adres yoklanır: sessizse kart "Yanıt vermiyor —
        // yeniden aranıyor…" der, TV ağda aranır (en çok 30 sn'de bir) ve bulunursa yeni adres kartta görünür.
        tvReachWatch.Tick += async (_, _) => { if (IsVisible && controller.ShowsOnTv) await controller.CheckTvReachableAsync(); };
        Loaded += (_, _) => { tvReachWatch.Start(); _ = controller.CheckTvReachableAsync(); };
        Unloaded += (_, _) => tvReachWatch.Stop();
        ShowTvUnreachable();
        tvOutcomeTimer.Tick += (_, _) => ShowTvOutcome(null, false);
        Unloaded += (_, _) => tvOutcomeTimer.Stop();
        lastTvClients = controller.TvClients;
        wasInstallingTvApp = controller.TvApp.Kind == TvAppKind.Working;
        ShowTvActions();
        Engine.SelectedItem = Engine.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Engine.ToString());
        TranslationDeviceChoice.SelectedItem = TranslationDeviceChoice.Items.Cast<ComboBoxItem>()
            .First(item => (string)item.Tag == settings.TranslationDevice.ToString());
        foreach (var count in CpuThreadOptions.Available(Environment.ProcessorCount))
            CpuThreadChoice.Items.Add(new ComboBoxItem { Content = count.ToString(), Tag = count });
        CpuThreadChoice.SelectedItem = CpuThreadChoice.Items.Cast<ComboBoxItem>()
            .First(item => (int)item.Tag == CpuThreadOptions.Normalize(settings.CpuTranslationThreads, Environment.ProcessorCount));
        FastSubtitleDetection.IsChecked = settings.FastSubtitleDetection;
        AutoReadGamePhone.IsChecked = settings.TranslatesGamePhone;
        PhoneMessagesPanel.IsChecked = settings.PhoneMessagesPanel;
        PhoneMessagesBubbles.IsChecked = !settings.PhoneMessagesPanel;
        OcrEngineChoice.SelectedItem = OcrEngineChoice.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.OcrEngine.ToString());
        ShowAdvancedOcr();
        ShowCpuThreads();
        ShowEngine();
        GamePacks.IsChecked = settings.GamePacks;
        SharePool.IsChecked = settings.SharePool;
        UsageData.IsChecked = settings.UsageData;
        // Telefonlardaki Profil › Kullanım verisi ile aynı; ölçüm bu derlemede yoksa gizli.
        UsageDataRow.Visibility = controller.UsageConfigured ? Visibility.Visible : Visibility.Collapsed;
        AskGame.IsChecked = settings.AskGame;
        SpeakerNames.IsChecked = settings.ShowSpeakerNames;
        SpeakerColors.IsChecked = settings.SpeakerColors;
        AutoScreenText.IsChecked = settings.AutoScreenText;
        ScreenTextMission.IsChecked = settings.ScreenTextMission;
        ScreenTextHelp.IsChecked = settings.ScreenTextHelp;
        ScreenTextMenus.IsChecked = settings.ScreenTextMenus;
        ScreenTextOther.IsChecked = settings.ScreenTextOther;
        ScreenTextKindsPanel.Visibility = settings.AutoScreenText ? Visibility.Visible : Visibility.Collapsed;
        SetTextApart.IsChecked = settings.SetTextApart;
        GameAreaPresets.IsChecked = settings.GameAreaPresets;
        ShowPacks();
        (settings.Appearance switch { AppAppearance.Light => AppearanceLight, AppAppearance.System => AppearanceSystem, _ => AppearanceDark }).IsChecked = true;
        StartupSound.IsChecked = settings.StartupSound;
        TransitionAnimations.IsChecked = settings.TransitionAnimations;
        ShowPace();
        MiniPreview.Content = new AspectBox { Child = AppearanceEditor.PerdeStage(MiniSubtitle, null) };
        ShowMiniSubtitle();
        ShowTvStatus();
        Sections.SelectedIndex = 0;
        ShowHeading();
        // Yazı boyutu, koyuluk ve yazı rengi artık düzenleyicide; eski satırlar gizlenir (ayarın kendisi aynı).
        AppearanceHost.Content = new AppearanceEditor(controller);
        foreach (var old in new FrameworkElement[] { TextSizeUnit, BackgroundUnit, TextColorUnit })
            old.Visibility = Visibility.Collapsed;
        RemotePlayAppChoice.SelectedItem = RemotePlayAppChoice.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.RemotePlayApp.ToString());
        XboxAudioOnComputer.IsChecked = settings.XboxAudioOnComputer;
        XboxLegacyFrameRate.IsChecked = settings.XboxLegacyFrameRate;
        ShowConsole();
        ShowPasscode();
        BuildShortcuts();
        ShowShortcutTexts();
        PreviewKeyDown += OnShortcutKey;
        ShowStreamWindowToggle();
        // Akış penceresi kendi düğmesiyle kapanmış olabilir; Ayarlar açılınca düğme güncellenir.
        Loaded += (_, _) => ShowStreamWindowToggle();
        Glow.Paused = controller.IsRunning;
        Loaded += (_, _) => DarkenAmberGlyph();
        Loaded += (_, _) => MoveSelection(false);
        NavHost.SizeChanged += (_, _) => MoveSelection(false);
        SizeChanged += (_, e) => { if (e.WidthChanged) UseCompactNav(ActualWidth < CompactNavBelow); };
        Unloaded += (_, _) => StopRecording();
        loading = false;
    }

    /// <summary>PS5 giriş şifresi kayıtlıysa yalnız "kaydedildi" görünür; şifrenin kendisi geri okunmaz.</summary>
    private void ShowPasscode()
    {
        var saved = controller.HasLoginPasscode;
        NewPasscode.Visibility = saved ? Visibility.Collapsed : Visibility.Visible;
        SavedPasscode.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnPasscodeSave(object sender, RoutedEventArgs e)
    {
        var accepted = controller.SetLoginPasscode(PasscodeBox.Password);
        PasscodeError.Visibility = accepted ? Visibility.Collapsed : Visibility.Visible;
        if (accepted) PasscodeBox.Clear();
        ShowPasscode();
    }

    private void OnPasscodeRemove(object sender, RoutedEventArgs e)
    {
        controller.RemoveLoginPasscode();
        ShowPasscode();
    }

    /// <summary>Remote Play uygulaması seçimi ve ipuçları yalnız seçili görüntü kaynağına göre görünür.</summary>
    private void ShowFrameSource()
    {
        // Xbox'ta (#853) seçenekler "Xbox (bu uygulama bağlanır)" ve "OBS projektörü veya oyun penceresi"; PS5'inkiler gizli.
        var xbox = controller.IsXbox;
        var settings = controller.Settings;
        var selectedTag = xbox ? (settings.XboxFrameSource == XboxFrameSource.CaptureWindow ? "CaptureWindow" : "Xbox") : settings.FrameSource.ToString();
        XboxSourceItem.Visibility = xbox ? Visibility.Visible : Visibility.Collapsed;
        Ps5SourceItem.Visibility = RemotePlaySourceItem.Visibility = xbox ? Visibility.Collapsed : Visibility.Visible;
        var wasLoading = loading;
        loading = true;
        FrameSourceChoice.SelectedItem = FrameSourceChoice.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == selectedTag);
        loading = wasLoading;
        XboxWindowHint.Visibility = xbox ? Visibility.Visible : Visibility.Collapsed;
        XboxPictureSourceCard.Visibility = xbox && !controller.XboxReadsWindow ? Visibility.Visible : Visibility.Collapsed;
        var window = !xbox && settings.FrameSource == FrameSource.RemotePlayWindow;
        var capture = xbox ? controller.XboxReadsWindow : settings.FrameSource == FrameSource.CaptureWindow;
        RemotePlayAppPanel.Visibility = window ? Visibility.Visible : Visibility.Collapsed;
        WindowSourceHint.Visibility = window ? Visibility.Visible : Visibility.Collapsed;
        CaptureWindowPanel.Visibility = capture ? Visibility.Visible : Visibility.Collapsed;
        if (capture) RefreshCaptureWindows();
        Ps5SourceHint.Visibility = xbox || window || capture ? Visibility.Collapsed : Visibility.Visible;
        SonyInstallRow.Visibility = ChiakiInstallRow.Visibility = window ? Visibility.Visible : Visibility.Collapsed;
        var sony = controller.RemotePlayInstalled(RemotePlayApp.Sony);
        var chiaki = controller.RemotePlayInstalled(RemotePlayApp.Chiaki);
        SonyInstalledText.Visibility = sony ? Visibility.Visible : Visibility.Collapsed;
        SonyDownloadButton.Visibility = sony ? Visibility.Collapsed : Visibility.Visible;
        ChiakiInstalledText.Visibility = chiaki ? Visibility.Visible : Visibility.Collapsed;
        ChiakiDownloadButton.Visibility = chiaki ? Visibility.Collapsed : Visibility.Visible;
        Ps5LinkPanel.Visibility = controller.NeedsPs5Link ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnDownloadSony(object sender, RoutedEventArgs e) => OpenUrl(AppController.SonyRemotePlayDownload);
    private void OnDownloadChiaki(object sender, RoutedEventArgs e) => OpenUrl(AppController.ChiakiDownload);
    private static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();

    /// <summary>"Hesabı bağla": sihirbaz ikinci hesap adımından açılır; ayar penceresi kapanır, sihirbaz ana pencerede görünür.</summary>
    /// <summary>Konsol kartı ve konsola bağlı bölümler (Mac Ayarlar › Konsol ile aynı).</summary>
    private void ShowConsole()
    {
        var xbox = controller.IsXbox;
        var wasLoading = loading;
        loading = true;
        (xbox ? ConsoleXbox : ConsolePlayStation).IsChecked = true;
        loading = wasLoading;
        // Kart her zaman görünür (Mac ConsoleSettingsCard); Xbox kapalıysa yalnız PS5 ↔ Xbox seçici gizlenir.
        ConsoleTabs.Visibility = controller.XboxAvailable ? Visibility.Visible : Visibility.Collapsed;
        ConsolePlayStationHint.Visibility = xbox ? Visibility.Collapsed : Visibility.Visible;
        var text = Localizer.Current;
        if (controller.Console is { } ps5)
        {
            ConsolePs5Row.Title = string.IsNullOrEmpty(ps5.Name) ? "PS5" : ps5.Name;
            ConsolePs5Row.Text = ps5.Host;
            ConsolePs5Badge.Text = text["Connected"];
            ConsolePs5Badge.Tone = Controls.ChipTone.Ok;
        }
        else
        {
            ConsolePs5Row.Title = "PS5";
            ConsolePs5Row.Text = text["With Remote Play and a second PSN account."];
            ConsolePs5Badge.Text = text["Not Set Up"];
            ConsolePs5Badge.Tone = Controls.ChipTone.Muted;
        }
        Ps5AddressActions.Visibility = !xbox && controller.Console is not null ? Visibility.Visible : Visibility.Collapsed;
        ConsoleXboxPanel.Visibility = xbox ? Visibility.Visible : Visibility.Collapsed;
        ConsoleXboxName.Text = controller.SelectedXboxConsole is { } console ? "  ·  " + (string.IsNullOrEmpty(console.Name) ? "Xbox" : console.Name) : "";
        // Microsoft hesap kartı (Mac DSAccountCard): girişliyse "Yeniden Giriş Yap" ve Diğer Giriş Yolları'nda Xbox seçimi ve çıkış.
        MicrosoftAccount.SignedIn = controller.HasXboxAccount;
        MicrosoftAccount.HasOthers = controller.HasXboxAccount;
        if (controller.HasXboxAccount && controller.NeedsXboxLink) MicrosoftAccount.Expanded = true;
        // TV girişi kartı: PS5'te ve HDMI'ye bağlı TV eşleşmişken (kurulumdaki TV Girişi adımı ile aynı koşul).
        HdmiCard.Visibility = !xbox && controller.NeedsHdmiStep ? Visibility.Visible : Visibility.Collapsed;
        var hdmiLoading = loading;
        loading = true;
        foreach (var input in new[] { Hdmi1, Hdmi2, Hdmi3, Hdmi4 })
            input.IsChecked = (string)input.Tag == controller.Settings.Style.HdmiInput?.ToString(System.Globalization.CultureInfo.InvariantCulture);
        loading = hdmiLoading;
        ConsoleXboxLink.Content = Localizer.Current["Choose your Xbox"];
        ConsoleXboxSignedIn.Visibility = controller.HasXboxAccount ? Visibility.Visible : Visibility.Collapsed;
        ShowFrameSource();
        PasscodeTab.Visibility = xbox ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnConsoleKind(object sender, RoutedEventArgs e)
    {
        if (loading || sender is not RadioButton { Tag: string tag }) return;
        controller.ChangeConsoleKind(tag == "Xbox" ? GameConsoleKind.Xbox : GameConsoleKind.PlayStation);
        ShowConsole();
    }

    private void OnLinkXbox(object sender, RoutedEventArgs e)
    {
        controller.LinkXbox();
        Leave();
    }

    private void OnSignOutXbox(object sender, RoutedEventArgs e)
    {
        controller.SignOutXbox();
        ShowConsole();
    }

    private void OnLinkPs5(object sender, RoutedEventArgs e)
    {
        controller.LinkPs5Account();
        Leave();
    }

    private void OnFrameSource(object sender, SelectionChangedEventArgs e)
    {
        if (loading || FrameSourceChoice.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        if (controller.IsXbox)
            Update(s => s with { XboxFrameSource = tag == "CaptureWindow" ? XboxFrameSource.CaptureWindow : XboxFrameSource.Xbox });
        else
            Update(s => s with { FrameSource = Enum.Parse<FrameSource>(tag) });
        ShowConsole();
    }

    private void OnXboxLegacyFrameRate(object sender, RoutedEventArgs e) =>
        Update(s => s with { XboxLegacyFrameRate = XboxLegacyFrameRate.IsChecked == true });

    private void OnXboxAudioOnComputer(object sender, RoutedEventArgs e) =>
        Update(s => s with { XboxAudioOnComputer = XboxAudioOnComputer.IsChecked == true });

    private void OnRemotePlayApp(object sender, SelectionChangedEventArgs e)
    {
        if (RemotePlayAppChoice.SelectedItem is ComboBoxItem { Tag: string tag })
            Update(s => s with { RemotePlayApp = Enum.Parse<RemotePlayApp>(tag) });
    }

    private bool refreshingCaptureWindows;

    private void RefreshCaptureWindows()
    {
        if (refreshingCaptureWindows) return;
        refreshingCaptureWindows = true;
        try
        {
            var saved = controller.Settings.CaptureWindow;
            var windows = controller.AvailableCaptureWindows();
            CaptureWindowChoice.Items.Clear();
            ComboBoxItem? selected = null;
            foreach (var target in windows)
            {
                var option = new ComboBoxItem { Content = $"{target.Title} ({target.ProcessName})", Tag = target };
                CaptureWindowChoice.Items.Add(option);
                if (target == saved) selected = option;
            }
            if (saved is not null && selected is null)
            {
                selected = new ComboBoxItem { Content = $"{saved.Title} ({saved.ProcessName}) — {Localizer.Current["Not currently open"]}", Tag = saved };
                CaptureWindowChoice.Items.Insert(0, selected);
            }
            CaptureWindowChoice.SelectedItem = selected;
            // Görünen liste: her pencere bir seçenek kartı (ad kalın, altında uygulama); seçili olan amber çerçeveli.
            CaptureWindowCards.Children.Clear();
            foreach (ComboBoxItem item in CaptureWindowChoice.Items)
            {
                if (item.Tag is not WindowCaptureTarget target) continue;
                var card = new Controls.OptionCard
                {
                    Content = target.Title, Description = item == selected && !windows.Contains(target)
                        ? $"{target.ProcessName} · {Localizer.Current["Not currently open"]}" : target.ProcessName,
                    GroupName = "captureWindow", IsChecked = item == selected, Margin = Sp.T("0", "0", "0", "xs"), MinHeight = 64,
                };
                card.Checked += (_, _) => { if (!refreshingCaptureWindows) CaptureWindowChoice.SelectedItem = item; };
                CaptureWindowCards.Children.Add(card);
            }
            CaptureWindowEmpty.Visibility = windows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            UpdateSourceProjectorHint(saved);
        }
        finally { refreshingCaptureWindows = false; }
    }

    private void OnRefreshCaptureWindows(object sender, RoutedEventArgs e) => RefreshCaptureWindows();

    private void OnCaptureWindowChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || refreshingCaptureWindows) return;
        if (CaptureWindowChoice.SelectedItem is ComboBoxItem { Tag: WindowCaptureTarget target })
        {
            Update(s => s with { CaptureWindow = target });
            UpdateSourceProjectorHint(target);
        }
    }

    /// <summary>OBS'in Program/Önizleme projektörü seçiliyse Kaynak projektörü önerilir (görüntüde CouchSubs'ın katmanı da var).</summary>
    private void UpdateSourceProjectorHint(WindowCaptureTarget? target) =>
        SourceProjectorHint.Visibility = ObsProjector.NeedsSourceProjectorHint(target) ? Visibility.Visible : Visibility.Collapsed;

    private void OnAppearance(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton { Tag: string tag })
            Update(s => s with { Appearance = Enum.Parse<AppAppearance>(tag) });
    }

    private void OnControllerChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.TvStatusText) or nameof(AppController.TvClients) or nameof(AppController.TvReconnecting)
            or nameof(AppController.Tv) or nameof(AppController.HasTv) or nameof(AppController.TvNotResponding))
            Dispatcher.BeginInvoke(ShowTvStatus);
        if (e.PropertyName is nameof(AppController.TvUnreachableProblem) or nameof(AppController.Tv))
            Dispatcher.BeginInvoke(ShowTvUnreachable);
        if (e.PropertyName is nameof(AppController.TvClients) or nameof(AppController.Tv) or nameof(AppController.HasTv)
            or nameof(AppController.TvApp) or nameof(AppController.TvAppOutdated) or nameof(AppController.OpeningTvAppForTest))
            Dispatcher.BeginInvoke(() =>
            {
                TrackTvOutcome();
                ShowTvActions();
            });
        if (e.PropertyName is nameof(AppController.Ps5AddressProblem)) Dispatcher.BeginInvoke(ShowPs5AddressProblem);
        if (e.PropertyName is nameof(AppController.Console)) Dispatcher.BeginInvoke(ShowConsole);
        // Menü arkasındaki renk geçişi çeviri sürerken durur (işlemci oyuna kalsın).
        if (e.PropertyName == nameof(AppController.IsRunning)) Dispatcher.BeginInvoke(() => Glow.Paused = controller.IsRunning);
        if (e.PropertyName is nameof(AppController.ObsAddress) or nameof(AppController.NetworkObsAddress) or nameof(AppController.LegacyTvWarning))
        {
            ObsAddress.Text = controller.ObsAddress;
            NetworkObsAddress.Text = controller.NetworkObsAddress ?? "";
            LegacyTvWarning.Visibility = controller.LegacyTvWarning ? Visibility.Visible : Visibility.Collapsed;
        }
        if (e.PropertyName is nameof(AppController.Settings) or nameof(AppController.ShowsOnTv) or nameof(AppController.ShowsOnComputer))
            ShowStyleTitle();
        if (e.PropertyName == nameof(AppController.LastFrame)) ShowLiveFrame();
        if (e.PropertyName == nameof(AppController.InstalledPacks)) ShowPacks();
        if (e.PropertyName is nameof(AppController.Settings) or nameof(AppController.AdvancedOcrInstalled) or nameof(AppController.AdvancedOcrDownloading)
            or nameof(AppController.AdvancedOcrProgress) or nameof(AppController.AdvancedOcrError))
            ShowAdvancedOcr();
        if (e.PropertyName == nameof(AppController.Settings)) ShowShortcutTexts();
        if (e.PropertyName is nameof(AppController.AreaProfileGame) or nameof(AppController.AreaProfileUnsaved)
            or nameof(AppController.AreaProfileTarget) or nameof(AppController.OfferedAreaProfileGame))
            ShowAreaProfile();
        if (e.PropertyName is nameof(AppController.GameProfiles) or nameof(AppController.AreaProfileGame)) ShowGameProfiles();
        // Oyun değişince alanlar profilden gelir ya da genel alanlara dönülür: açık sekme yeni alanı gösterir.
        if (e.PropertyName == nameof(AppController.AreaProfileGame) && !Region.IsDragging) ShowArea(area);
    }

    /// <summary>
    /// "Bu oyunun alanları": profil etkinse hangi oyunun alanları olduğu (kaydedilmemiş değişiklik varsa "Profile kaydet");
    /// değilse oynanan oyuna kaydetme; oyun bilinmiyorsa nasıl kaydedileceği.
    /// </summary>
    private void ShowAreaProfile()
    {
        var text = Localizer.Current;
        var active = controller.AreaProfileGame;
        var target = controller.AreaProfileTarget;
        var unsaved = controller.AreaProfileUnsaved;
        AreaProfileText.Text = active is not null ? text.Format("These areas are saved for %@.", active)
            : target is not null ? text["These are your general areas."]
            : text["Areas can be saved for a game while translating, once the game being played is known."];
        AreaProfileHint.Text = active is not null
            ? text[unsaved ? "Your changes are not saved yet; they are dropped when translating stops." : "They come back by themselves whenever you play this game."]
            : target is not null ? text.Format("Save them for %@ and they come back by themselves the next time you play it.", target)
            : text["The played game is shown on the home screen; you can choose it there."];
        // Oynanan oyunun kayıtlı alanları uygulanmadıysa üzerine yazılmaz: düğme o alanları kullanır.
        var other = controller.AreaProfileTargetHasOther;
        AreaProfileSave.Content = other && target is not null ? text.Format("Use the saved areas for %@", target)
            : active is not null ? text["Save to profile"] : target is not null ? text.Format("Save for %@", target) : "";
        AreaProfileSave.Visibility = target is not null && (other || active is null || unsaved) ? Visibility.Visible : Visibility.Collapsed;
        AreaProfileDelete.Visibility = active is not null ? Visibility.Visible : Visibility.Collapsed;
        AreaProfileButtons.Visibility = AreaProfileSave.Visibility == Visibility.Visible || active is not null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnSaveAreaProfile(object sender, RoutedEventArgs e)
    {
        if (controller.AreaProfileTargetHasOther
            && AreaProfiles.Key(controller.AreaProfileTarget, controller.Settings.AreaSource) is { } key)
            controller.UseAreaProfile(key);
        else
            controller.SaveAreaProfile();
    }

    // --- Oyun profilleri: listede olmayan oyun adı yazılarak eklenir; seç, yeniden adlandır, çoğalt, sil ---

    /// <summary>Ad yazılan işlem: yeni profil (null anahtar), yeniden adlandırma ya da çoğaltma.</summary>
    private (string? Key, bool Duplicate)? profileEditing;

    private void ShowGameProfiles()
    {
        var text = Localizer.Current;
        GameProfileList.Children.Clear();
        var active = controller.Settings.ActiveAreaProfile;
        foreach (var profile in controller.GameProfiles)
        {
            // Ad üstte, düğmeler altında ve sığmazsa alt satıra sarılır: dar sütunda dört düğme adı ezip kartın dışına taşıyordu.
            var row = new StackPanel { Margin = Sp.T("0", "xxs", "0", "xxs") };
            var buttons = new WrapPanel { Margin = Sp.T("0", "xs", "0", "0") };
            void AddButton(string title, Action run)
            {
                var button = new Button { Content = text[title], Padding = Sp.T("s", "0", "s", "0"), Margin = Sp.T("0", "0", "xs", "xs") };
                button.Click += (_, _) => run();
                buttons.Children.Add(button);
            }
            var key = profile.Key;
            var game = profile.Game;
            if (key != active) AddButton("Use", () => controller.UseAreaProfile(key));
            AddButton("Rename", () => BeginProfileEdit((key, false), game));
            AddButton("Duplicate", () => BeginProfileEdit((key, true), ""));
            AddButton("Delete profile", () =>
            {
                if (MessageBox.Show(Host, text.Format("Delete the saved areas for %@?", game), text["Delete profile"], MessageBoxButton.YesNo,
                                    MessageBoxImage.Question) == MessageBoxResult.Yes)
                    controller.DeleteAreaProfile(key);
            });
            row.Children.Add(new TextBlock
            {
                Text = key == active ? game + " · " + text["In use"] : game,
                TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
            });
            row.Children.Add(buttons);
            GameProfileList.Children.Add(row);
        }
        GameProfileList.Visibility = GameProfileList.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BeginProfileEdit((string? Key, bool Duplicate) editing, string name)
    {
        var text = Localizer.Current;
        profileEditing = editing;
        GameProfileName.Text = name;
        GameProfileProblem.Visibility = Visibility.Collapsed;
        GameProfileCommit.Content = text[editing.Key is null ? "Save current areas" : editing.Duplicate ? "Duplicate" : "Rename"];
        GameProfileEditor.Visibility = Visibility.Visible;
        GameProfileNew.Visibility = Visibility.Collapsed;
        GameProfileName.Focus();
        GameProfileName.SelectAll();
    }

    private void EndProfileEdit()
    {
        profileEditing = null;
        GameProfileEditor.Visibility = Visibility.Collapsed;
        GameProfileNew.Visibility = Visibility.Visible;
    }

    private void OnNewGameProfile(object sender, RoutedEventArgs e) => BeginProfileEdit((null, false), controller.PlayedGame ?? "");

    private void OnCancelGameProfile(object sender, RoutedEventArgs e) => EndProfileEdit();

    private void OnGameProfileNameKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) OnCommitGameProfile(sender, e);
        else if (e.Key == Key.Escape) EndProfileEdit();
    }

    private void OnCommitGameProfile(object sender, RoutedEventArgs e)
    {
        if (profileEditing is not { } editing) return;
        var text = Localizer.Current;
        var name = GameProfileName.Text.Trim();
        var edit = editing.Key is not { } key ? controller.SaveAreaProfileAs(name)
            : editing.Duplicate ? controller.DuplicateAreaProfile(key, name)
            : controller.RenameAreaProfile(key, name);
        switch (edit)
        {
            case AreaProfiles.Edit.Done:
                EndProfileEdit();
                ShowGameProfiles();
                break;
            case AreaProfiles.Edit.Exists:
                GameProfileProblem.Text = text.Format("There is already a profile for %@.", name);
                GameProfileProblem.Visibility = Visibility.Visible;
                break;
            default:
                GameProfileProblem.Text = text["Type the game's name."];
                GameProfileProblem.Visibility = Visibility.Visible;
                break;
        }
    }

    private void OnDeleteAreaProfile(object sender, RoutedEventArgs e)
    {
        if (controller.AreaProfileGame is not { } game) return;
        var text = Localizer.Current;
        if (MessageBox.Show(Host, text.Format("Delete the saved areas for %@?", game), text["Delete profile"], MessageBoxButton.YesNo,
                            MessageBoxImage.Question) == MessageBoxResult.Yes)
            controller.DeleteAreaProfile();
    }

    /// <summary>TV eşli değil: TV adımı açılır (TV seçilir ve eşleşir).</summary>
    private void OnPairTv(object sender, RoutedEventArgs e)
    {
        controller.ChangeTv();
        Leave();
    }

    /// <summary>"TV'de CouchSubs'ı Aç": düğme iş bitene kadar "TV'de açılıyor…" der ve basılamaz; sonuç kısa süre görünür.</summary>
    private async void OnOpenTvApp(object sender, RoutedEventArgs e)
    {
        if (tvOpening) return;
        tvOpening = true;
        ShowTvOutcome(null, false);
        ShowTvActions();
        try
        {
            var connected = await controller.OpenTvAppOnTvAsync();
            // TV'ye ulaşılamadıysa kartta zaten açık hata ve çözümler var.
            if (!connected && !controller.HasTvUnreachableProblem)
                ShowTvOutcome(Localizer.Current["The TV app did not connect. Make sure the TV is on and on the same network, then try again."], true);
        }
        catch (Exception error) { ShowTvOutcome(error.Message, true); }
        finally
        {
            tvOpening = false;
            ShowTvActions();
        }
    }

    private bool tvOpening;
    private int lastTvClients;
    private bool wasInstallingTvApp;
    private readonly System.Windows.Threading.DispatcherTimer tvOutcomeTimer = new() { Interval = TimeSpan.FromSeconds(4) };

    /// <summary>TV kartının düğmeleri ve süren işin adımı (Mac TV kartıyla aynı kurallar).</summary>
    private void ShowTvActions()
    {
        var text = Localizer.Current;
        var installing = controller.TvApp.Kind == TvAppKind.Working;
        PairTvButton.Visibility = controller.HasTv ? Visibility.Collapsed : Visibility.Visible;
        OpenTvAppButton.Visibility = controller.HasTv && controller.TvClients == 0 ? Visibility.Visible : Visibility.Collapsed;
        OpenTvAppButton.Content = text[tvOpening ? "Opening on the TV…" : "Open CouchSubs on the TV"];
        PerdeProps.SetBusy(OpenTvAppButton, tvOpening);
        OpenTvAppButton.IsEnabled = !tvOpening && !installing;
        TestTvButton.IsEnabled = !tvOpening && !installing;

        string? phase = null;
        var step = -1;
        if (installing)
        {
            phase = controller.TvAppOutdated is not null ? "Updating the TV app…" : "Installing the TV app…";
            step = 1;
        }
        else if (controller.OpeningTvAppForTest) { phase = "Opening on the TV…"; step = 2; }
        else if (tvOpening) { phase = "Connecting to the TV…"; step = 0; }
        TvProgressPanel.Visibility = phase is null ? Visibility.Collapsed : Visibility.Visible;
        TvProgressText.Text = phase is null ? "" : text[phase];
        TvStepLine.Visibility = step < 0 ? Visibility.Collapsed : Visibility.Visible;
        TvStepLine.Inlines.Clear();
        if (step < 0) return;
        string[] steps = ["Connecting to the TV", "Installing the app", "Opening"];
        for (var index = 0; index < steps.Length; index++)
        {
            if (index > 0) TvStepLine.Inlines.Add(new System.Windows.Documents.Run(" → "));
            var part = new System.Windows.Documents.Run(text[steps[index]]);
            if (index == step)
            {
                part.FontWeight = FontWeights.SemiBold;
                part.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "accentBrush");
            }
            TvStepLine.Inlines.Add(part);
        }
    }

    /// <summary>Biten işin sonucu: başarı 4 sn görünür, hata kalır (yeni eylemde silinir).</summary>
    private void ShowTvOutcome(string? message, bool failed)
    {
        tvOutcomeTimer.Stop();
        TvOutcomeOk.Visibility = message is not null && !failed ? Visibility.Visible : Visibility.Collapsed;
        TvOutcomeOk.Text = !failed ? message ?? "" : "";
        TvOutcomeError.Visibility = message is not null && failed ? Visibility.Visible : Visibility.Collapsed;
        TvOutcomeError.Text = failed ? message ?? "" : "";
        if (message is not null && !failed) tvOutcomeTimer.Start();
    }

    /// <summary>Bağlantı ve kurulum geçişlerinde sonuç gösterilir ("Bağlandı", "Güncellendi: 0.9.98" ya da hata).</summary>
    private void TrackTvOutcome()
    {
        var text = Localizer.Current;
        if (lastTvClients == 0 && controller.TvClients > 0) ShowTvOutcome(text["Connected"], false);
        lastTvClients = controller.TvClients;
        var installing = controller.TvApp.Kind == TvAppKind.Working;
        if (wasInstallingTvApp && !installing)
        {
            if (controller.TvApp is { Kind: TvAppKind.UpToDate, Version: { } version }) ShowTvOutcome(text.Format("Updated: %@", version), false);
            else if (controller.TvApp.Kind == TvAppKind.Failed)
                ShowTvOutcome(text["The TV app could not be installed. The details are in the TV app card below."], true);
        }
        wasInstallingTvApp = installing;
    }

    private void OnRenewAccessKey(object sender, RoutedEventArgs e) => controller.RotateSubtitleKey();

    /// <summary>
    /// Alan sekmesi açıkken önizleme oyunun görüntüsüyle saniyede dört kez yenilenir (çerçeve sürüklenirken beklenir); çerçeve
    /// akan görüntüde yerleştirilir. Yalnız bu sekme açıkken; okuma hattına iş eklemez.
    /// </summary>
    private const int PreviewIntervalMs = 250;

    private void ShowLiveFrame()
    {
        if (!AreaTab.IsSelected || Region.IsDragging || controller.LastFrame is not { } frame) return;
        var now = Environment.TickCount64;
        if (now - lastPreview < PreviewIntervalMs) return;
        lastPreview = now;
        Region.Frame = frame;
    }

    /// <summary>Altyazı bilgisayar ekranında da gösteriliyorsa görünüm kartı yalnız TV'ye ait değildir.</summary>
    private void ShowStyleTitle()
    {
        // Başlıksız kart (Mac AppearanceCard); TV ya da OBS yokken yalnız bilgisayar ekranı yer düğmesi kalır.
        // Görüntü modu yalnız Android TV uygulamasında var.
        DisplayModePanel.Visibility = controller.ShowsOnTv && controller.Tv?.Brand == TvBrand.AndroidTv
            ? Visibility.Visible : Visibility.Collapsed;
        // Yer ayarları TV içindir; bilgisayar ekranında "ekrandaki konum ayarı işlemiyor" sanılıyordu (Genzo, 2026-11-13).
        // OBS katmanı da yeri kullanır ("Yalnız OBS (yayın)").
        TvPlacementPanel.Visibility = controller.ShowsOnTv || controller.Settings.Output == SubtitleOutput.Obs ? Visibility.Visible : Visibility.Collapsed;
        ComputerPlacementPanel.Visibility = controller.ShowsOnComputer ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnAdjustOverlay(object sender, RoutedEventArgs e) => controller.OverlayAdjusting = true;
    /// <summary>
    /// Kurulu oyun paketleri: iki sütunlu karolar (kısaltma rozeti, ad, satır sayısı) ve üstte "Ücretsiz · n oyun" hapı.
    /// Masaüstünde paketler ücretsizdir.
    /// </summary>
    private void ShowPacks()
    {
        var text = Localizer.Current;
        PackList.Items.Clear();
        // Oyunun "(ek satırlar)" paketi asıl paketin karosunda (#353).
        var packs = GameCatalog.PackShelf(controller.InstalledPacks);
        PacksPill.Visibility = packs.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        PacksPill.Text = text.Format("Free · %lld games", packs.Count);
        if (UpdatePacksProgress.Visibility != Visibility.Visible) UpdatePacks.IsEnabled = controller.CanUpdatePacks;
        if (packs.Count == 0)
        {
            PackList.Items.Add(new TextBlock
            {
                Text = text["No game pack is installed."], Style = (Style)FindResource("HintText"), TextWrapping = TextWrapping.Wrap,
                Margin = Sp.T("xs"),
            });
            return;
        }
        foreach (var pack in packs) PackList.Items.Add(PackTile(pack, text.Format("%@ lines", pack.Entries.ToString("N0"))));
    }

    /// <summary>
    /// Paket karosu (Perde, Mac PackTile): 120 genişlikte 3:4 kapak (kullanıcının seçtiği görsel ya da adından türeyen
    /// degrade, alttan scrim üstünde kalın beyaz ad); oynanan oyunun paketi "Oynanıyor" cam hapı + amber halka + kapak
    /// ışıması; altında yeşil nokta ve mono satır sayısı. Kapağa tıklayınca görsel seçilir, sağ tıkta seç/kaldır.
    /// </summary>
    private FrameworkElement PackTile(PackShelfItem pack, string lines)
    {
        var text = Localizer.Current;
        const double width = 120;
        var playing = controller.PlayedGame is { } game && pack.Titles.Append(pack.Title).Any(title => GameName.Key(title) == GameName.Key(game));
        var cover = new Controls.GameCover(pack.Title, playing ? text["Playing"] : null, playing, width)
        {
            ToolTip = CoverText("Choose game cover…", "Oyun kapağı seç…"),
        };
        var coverPath = GameCoverStore.PathFor(pack.Id);
        if (coverPath is not null && File.Exists(coverPath))
        {
            try
            {
                // OnLoad releases the file before the image is displayed, so replacing a cover works immediately.
                using var stream = File.OpenRead(coverPath);
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.DecodePixelWidth = 256;
                image.StreamSource = stream;
                image.EndInit();
                image.Freeze();
                // Seçilen görsel kapağın degradesinin yerine (scrim ve ad üstünde kalır).
                if (FindCoverArt(cover) is { } art && art.Parent is Grid stage)
                {
                    var index = stage.Children.IndexOf(art);
                    stage.Children.Insert(index + 1, new Image { Source = image, Stretch = Stretch.UniformToFill });
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or FormatException or NotSupportedException)
            {
                // A corrupted optional cover must never hide the pack or prevent opening Settings.
            }
        }
        System.Windows.Automation.AutomationProperties.SetName(cover, CoverText("Choose game cover…", "Oyun kapağı seç…") + " " + pack.Title);
        cover.Click += (_, _) => ChoosePackCover(pack.Id);
        var choose = new MenuItem { Header = CoverText("Choose game cover…", "Oyun kapağı seç…") };
        choose.Click += (_, _) => ChoosePackCover(pack.Id);
        var remove = new MenuItem
        {
            Header = CoverText("Remove game cover", "Oyun kapağını kaldır"), IsEnabled = coverPath is not null && File.Exists(coverPath),
        };
        remove.Click += (_, _) =>
        {
            try { GameCoverStore.Remove(pack.Id); ShowPacks(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                MessageBox.Show(Host, CoverText("The game cover could not be saved.", "Oyun kapağı kaydedilemedi."), text["Game packs"],
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
        cover.ContextMenu = new ContextMenu { Items = { choose, remove } };

        var dot = new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, VerticalAlignment = VerticalAlignment.Center, Margin = Sp.T("0", "0", "xxs", "0") };
        dot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "successBrush");
        var count = new TextBlock { Text = lines, FontSize = 11, FontWeight = FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        System.Windows.Documents.Typography.SetNumeralAlignment(count, FontNumeralAlignment.Tabular);
        count.SetResourceReference(TextBlock.ForegroundProperty, "mutedBrush");
        var meta = new StackPanel { Orientation = Orientation.Horizontal, Margin = Sp.T("0", "xs", "0", "0") };
        meta.Children.Add(dot);
        meta.Children.Add(count);
        var tile = new StackPanel { Width = width, Margin = Sp.T("0", "s", "m", "s") };
        tile.Children.Add(cover);
        tile.Children.Add(meta);
        return tile;
    }

    /// <summary>Kapak kartının içindeki degrade katmanı (seçilen görsel onun hemen üstüne konur).</summary>
    private static Controls.CoverArt? FindCoverArt(DependencyObject root)
    {
        // Görsel ağaç henüz kurulmadığından mantıksal ağaçta aranır; bulanık ışıma kopyası (Border içinde) atlanır.
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            if (child is Controls.CoverArt art && art.Parent is Grid) return art;
            if (FindCoverArt(child) is { } found) return found;
        }
        return null;
    }

    /// <summary>Import and center-crop one cover to a 128px PNG; no network or image dependency is needed.</summary>
    private void ChoosePackCover(string packId)
    {
        var text = Localizer.Current;
        if (GameCoverStore.PathFor(packId) is null) return;
        var picker = new OpenFileDialog
        {
            Title = CoverText("Choose game cover…", "Oyun kapağı seç…"), CheckFileExists = true,
            Filter = $"{CoverText("Images", "Görseller")} (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg",
        };
        if (picker.ShowDialog(Host) != true) return;
        try
        {
            if (new FileInfo(picker.FileName).Length > 8 * 1024 * 1024)
                throw new InvalidDataException("Image exceeds 8 MB.");
            using var source = File.OpenRead(picker.FileName);
            // Decode a bounded preview instead of expanding a potentially huge original into RAM.
            var frame = new BitmapImage();
            frame.BeginInit();
            frame.CacheOption = BitmapCacheOption.OnLoad;
            frame.DecodePixelWidth = 512;
            frame.StreamSource = source;
            frame.EndInit();
            frame.Freeze();
            if (frame.PixelWidth > 4096 || frame.PixelHeight > 4096)
                throw new InvalidDataException("Image dimensions are too large.");
            var side = Math.Min(frame.PixelWidth, frame.PixelHeight);
            if (side == 0) throw new InvalidDataException("Empty image.");
            var crop = new CroppedBitmap(frame,
                new Int32Rect((frame.PixelWidth - side) / 2, (frame.PixelHeight - side) / 2, side, side));
            var thumb = new TransformedBitmap(crop, new ScaleTransform(128.0 / side, 128.0 / side));
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(thumb));
            using var output = new MemoryStream();
            encoder.Save(output);
            GameCoverStore.Save(packId, output.ToArray());
            ShowPacks();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or InvalidDataException or ArgumentException or FormatException or NotSupportedException)
        {
            MessageBox.Show(Host, CoverText("The game cover could not be saved.", "Oyun kapağı kaydedilemedi."), text["Game packs"],
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    // Kapak metinleri artık Mac ile ortak katalogda (Localizable.xcstrings); Türkçe parametre yalnız okunurluk için kalır.
    private static string CoverText(string english, string turkish) => Localizer.Current[english];

    /// <summary>"Grand Theft Auto V" → "GTA": ilk üç sözcüğün baş harfleri (rakam olduğu gibi).</summary>
    internal static string Initials(string title)
    {
        var words = title.Split([' ', ':', '-', '(', ')'], StringSplitOptions.RemoveEmptyEntries);
        var letters = words.Where(word => char.IsLetterOrDigit(word[0])).Take(3).Select(word => char.ToUpperInvariant(word[0]));
        return string.Concat(letters);
    }

    /// <summary>
    /// "Paketleri şimdi güncelle": beklerken düğme "Güncelleniyor…" olur; sonuç ("Paketler zaten güncel." ya da neyin
    /// geldiği) iletide gösterilir, hatada "Yeniden dene" sorulur.
    /// </summary>
    private async void OnUpdatePacks(object sender, RoutedEventArgs e)
    {
        var text = Localizer.Current;
        while (true)
        {
            UpdatePacks.IsEnabled = false;
            UpdatePacks.Content = text["Updating…"];
            UpdatePacksProgress.Visibility = UpdatePacksStatus.Visibility = Visibility.Visible;
            PackUpdateOutcome? outcome;
            try
            {
                outcome = await controller.UpdatePacksNowAsync();
            }
            finally
            {
                UpdatePacks.Content = text["Update the packs now"];
                UpdatePacks.IsEnabled = controller.CanUpdatePacks;
                UpdatePacksProgress.Visibility = UpdatePacksStatus.Visibility = Visibility.Collapsed;
            }
            if (outcome is null || !IsLoaded) return;
            if (outcome.Result != PackUpdateOutcome.Kind.Failed)
            {
                MessageBox.Show(Host, outcome.Message(text), outcome.Title(text), MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            var again = MessageBox.Show(Host, outcome.Message(text) + "\n\n" + text["Try again"] + "?", outcome.Title(text),
                MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
            if (again != MessageBoxResult.Yes) return;
        }
    }

    private async void OnImportPack(object sender, RoutedEventArgs e)
    {
        var text = Localizer.Current;
        var picker = new OpenFileDialog
        {
            Title = text["Import game pack"],
            Filter = $"{text["Translation files"]} (*.json, *.txt, *.srt)|*.json;*.txt;*.srt",
        };
        if (picker.ShowDialog(Host) != true) return;

        var sourcePath = picker.FileName;
        ImportPack.IsEnabled = false;
        GamePackImportPreview preview;
        try
        {
            preview = await Task.Run(() =>
            {
                if (new FileInfo(sourcePath).Length > GamePackImporter.MaxFileBytes) throw new InvalidDataException("The file is too large.");
                return GamePackImporter.Parse(File.ReadAllBytes(sourcePath), Path.GetFileName(sourcePath));
            });
        }
        catch (InvalidDataException error)
        {
            SubtitleLog.Write($"Paket içe aktarılamadı ({Path.GetFileName(sourcePath)}): {error.Message}");
            if (IsLoaded)
                MessageBox.Show(Host, text["The translation file could not be imported. Check its format and encoding."],
                    picker.Title, MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            if (IsLoaded)
                MessageBox.Show(Host, text["The translation file could not be read."], picker.Title,
                    MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }
        finally
        {
            ImportPack.IsEnabled = true;
        }

        // Kaç satır kabul edildi, kaçı neden atlandı (#1355).
        SubtitleLog.Write(preview.LogLine(Path.GetFileName(sourcePath)));
        if (IsLoaded && new GamePackImportWindow(preview, sourcePath) { Owner = Host }.ShowDialog() == true)
            controller.ReloadGamePacks();
    }

    private void OnGamePacks(object sender, RoutedEventArgs e) => Update(s => s with { GamePacks = GamePacks.IsChecked == true });

    private void OnSharePool(object sender, RoutedEventArgs e) => Update(s => s with { SharePool = SharePool.IsChecked == true });

    private void OnUsageData(object sender, RoutedEventArgs e) => Update(s => s with { UsageData = UsageData.IsChecked == true });

    private void OnAskGame(object sender, RoutedEventArgs e) => Update(s => s with { AskGame = AskGame.IsChecked == true });

    private void OnSpeakerNames(object sender, RoutedEventArgs e) => Update(s => s with { ShowSpeakerNames = SpeakerNames.IsChecked == true });

    private void OnSpeakerColors(object sender, RoutedEventArgs e) => Update(s => s with { SpeakerColors = SpeakerColors.IsChecked == true });

    private void OnAutoScreenText(object sender, RoutedEventArgs e)
    {
        // Türler yalnız ayar açıkken görünür.
        ScreenTextKindsPanel.Visibility = AutoScreenText.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        Update(s => s with { AutoScreenText = AutoScreenText.IsChecked == true });
    }

    /// <summary>Otomatik ekran yazısının türleri (bkz. <see cref="ScreenTextKind"/>).</summary>
    private void OnScreenTextKind(object sender, RoutedEventArgs e) => Update(s => s with
    {
        ScreenTextMission = ScreenTextMission.IsChecked == true,
        ScreenTextHelp = ScreenTextHelp.IsChecked == true,
        ScreenTextMenus = ScreenTextMenus.IsChecked == true,
        ScreenTextOther = ScreenTextOther.IsChecked == true,
    });

    private void OnSetTextApart(object sender, RoutedEventArgs e) => Update(s => s with { SetTextApart = SetTextApart.IsChecked == true });

    private void OnGameAreaPresets(object sender, RoutedEventArgs e) => Update(s => s with { GameAreaPresets = GameAreaPresets.IsChecked == true });

    /// <summary>Seçili motor (ayarlarda ücretsiz ise Free).</summary>
    private TranslationEngine SelectedEngine =>
        Engine.SelectedItem is ComboBoxItem { Tag: string tag } ? Enum.Parse<TranslationEngine>(tag) : TranslationEngine.Free;

    private void OnGeminiPaidTier(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        Update(s => s with { GeminiPaidTier = GeminiPaidTier.IsChecked == true });
        ShowEngine();
    }

    /// <summary>Ayarlar › Konsol › TV girişi: seçilen giriş kaydedilir ve TV'de deneme altyazısı gösterilir (Mac ile aynı).</summary>
    private void OnHdmiInput(object sender, RoutedEventArgs e)
    {
        if (loading || sender is not FrameworkElement { Tag: string tag } || !int.TryParse(tag, out var input)) return;
        if (controller.Settings.Style.HdmiInput == input) return;
        controller.TryHdmiInput(input, confirmed: true);
        controller.SendTestSubtitle();
    }

    /// <summary>Motor seçenek kartı seçildi: gizli Engine kutusu da aynı motora geçer (OnEngine kaydeder).</summary>
    private void OnEngineOption(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string tag }) return;
        var item = Engine.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == tag);
        if (item is not null && !ReferenceEquals(Engine.SelectedItem, item)) Engine.SelectedItem = item;
    }

    private void ShowEngine()
    {
        var text = Localizer.Current;
        var engine = SelectedEngine;
        foreach (var option in EngineOptions.Children.OfType<Controls.OptionCard>())
            option.IsChecked = (string)option.Tag == engine.ToString();
        EngineHint.Text = text[engine switch
        {
            TranslationEngine.Free => "Free. The translation model built into CouchSubs runs on this computer; subtitle text never leaves it.",
            TranslationEngine.DeepL => "Optional. With your own free DeepL key, translations read more naturally. Subtitle text is sent to DeepL; when DeepL cannot be reached, the translation model on this computer takes over.",
            TranslationEngine.Gemini => "Google's AI translates with the game's tone and keeps names as they are. Subtitle text is sent to Google with your own key, and any cost is billed to your Google account. When Gemini cannot be reached, the free translation takes over.",
            TranslationEngine.OpenAi => "OpenAI's AI translates with the game's tone and keeps names as they are. Subtitle text is sent to OpenAI with your own key, and any cost is billed to your OpenAI account. When OpenAI cannot be reached, the free translation takes over.",
            TranslationEngine.Local => "Free, with no quota. An AI model on this computer (Ollama or LM Studio) translates; subtitle text never leaves it. Speed depends on your computer. When the model cannot be reached, the free translation takes over.",
            _ => "Anthropic's Claude translates with the game's tone and keeps names as they are. Subtitle text is sent to Anthropic with your own key, and any cost is billed to your Anthropic account. When Claude cannot be reached, the free translation takes over.",
        }];
        EnglishOnlyHint.Visibility = engine != TranslationEngine.Free && controller.Settings.SourceLanguage != "en" ? Visibility.Visible : Visibility.Collapsed;
        KeyPanel.Visibility = engine == TranslationEngine.Free ? Visibility.Collapsed : Visibility.Visible;
        FreeGeminiOffer.Visibility = engine == TranslationEngine.Free ? Visibility.Visible : Visibility.Collapsed;
        FreeGeminiNotes.Visibility = engine == TranslationEngine.Gemini ? Visibility.Visible : Visibility.Collapsed;
        FreeGeminiLimit.Visibility = controller.Settings.GeminiPaidTier ? Visibility.Collapsed : Visibility.Visible;
        KeyStatus.Visibility = Visibility.Collapsed;
        KeyError.Visibility = Visibility.Collapsed;
        if (engine == TranslationEngine.Free) return;

        var saved = controller.HasKey(engine);
        var isLocal = engine == TranslationEngine.Local;
        NewKey.Visibility = saved ? Visibility.Collapsed : Visibility.Visible;
        SavedKey.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
        // DeepL'in denemesi bu ayki kullanımı gösterir; ayrı bir "Dene" düğmesi gerekmez.
        KeyTest.Visibility = engine == TranslationEngine.DeepL ? Visibility.Collapsed : Visibility.Visible;
        // Yerel modelde anahtar isteğe bağlıdır: düğme yalnız bağlantıyı dener (yazılan anahtar kabul edilirse saklanır).
        NoKeyHint.Visibility = engine == TranslationEngine.DeepL || isLocal ? Visibility.Collapsed : Visibility.Visible;
        KeySave.Content = text[isLocal ? "Test connection" : "Save and test"];
        KeyTest.Content = text[isLocal ? "Test connection" : "Test"];
        var provider = engine.Provider();
        KeyLink.NavigateUri = provider?.KeyPage() ?? new Uri("https://www.deepl.com/pro-api");
        KeyLinkText.Text = isLocal ? text["Download Ollama"]
            : provider is { } named ? text.Format("Get a %@ API key", named.DisplayName()) : text["Get a free DeepL API key"];
        ModelPanel.Visibility = provider is null || isLocal ? Visibility.Collapsed : Visibility.Visible;
        LocalPanel.Visibility = isLocal ? Visibility.Visible : Visibility.Collapsed;
        // Ek talimat yalnız yapay zekâ motorlarında (Gemini, OpenAI, Claude, yerel model); DeepL'de yoktur.
        InstructionPanel.Visibility = provider is null ? Visibility.Collapsed : Visibility.Visible;
        if (!Instruction.IsKeyboardFocusWithin) Instruction.Text = controller.Settings.AiInstruction;
        LocalKeyLabel.Visibility = saved ? Visibility.Collapsed : Visibility.Visible;
        // Yerel modelde geçersiz adres düğmeleri kapatır; başka motora geçince yeniden açılır.
        KeySave.IsEnabled = true;
        KeyTest.IsEnabled = true;
        if (isLocal) ShowLocal();
        else if (provider is { } p) ShowModels(p);
        if (saved && engine == TranslationEngine.DeepL) _ = ShowDeepLUsageAsync();
    }

    /// <summary>Yerel modelin kayıtlı adresi ve model adı; adres geçersizse uyarı.</summary>
    private void ShowLocal()
    {
        var settings = controller.Settings;
        LocalAddress.Text = settings.LocalAiBaseUrl;
        LocalModel.Text = settings.LocalAiModel;
        ShowLocalAddressError();
    }

    private void ShowLocalAddressError()
    {
        var invalid = LocalAiServer.Normalize(LocalAddress.Text) is null;
        LocalAddressError.Visibility = invalid ? Visibility.Visible : Visibility.Collapsed;
        LocalAddressError.Text = Localizer.Current.Format("This address is not valid. Example: %@", LocalAiServer.OllamaUrl);
        KeySave.IsEnabled = !invalid;
        KeyTest.IsEnabled = !invalid;
    }

    /// <summary>Yazılan adres ve model alandan çıkınca ya da Enter'a basınca kaydedilir; her tuşta hat yeniden kurulmaz.</summary>
    private void CommitLocal()
    {
        var address = LocalAddress.Text.Trim();
        var model = LocalModel.Text.Trim();
        var settings = controller.Settings;
        if (address != settings.LocalAiBaseUrl || model != settings.LocalAiModel)
        {
            Update(s => s with { LocalAiBaseUrl = address, LocalAiModel = model });
            KeyStatus.Visibility = Visibility.Collapsed;
            KeyError.Visibility = Visibility.Collapsed;
        }
        ShowLocalAddressError();
    }

    private void OnLocalChanged(object sender, RoutedEventArgs e) => CommitLocal();

    /// <summary>Ek talimat alandan çıkınca kaydedilir; her tuşta çeviri hattı yeniden kurulmaz.</summary>
    private void OnInstructionChanged(object sender, RoutedEventArgs e)
    {
        var instruction = Instruction.Text.Trim();
        if (instruction != controller.Settings.AiInstruction) Update(s => s with { AiInstruction = instruction });
    }

    private void OnInstructionTyped(object sender, System.Windows.Controls.TextChangedEventArgs e) =>
        InstructionPlaceholder.Visibility = Instruction.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

    private void OnLocalKey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Enter) CommitLocal();
    }

    private void OnUseOllama(object sender, RoutedEventArgs e) => UseLocalAddress(LocalAiServer.OllamaUrl);

    private void OnUseLmStudio(object sender, RoutedEventArgs e) => UseLocalAddress(LocalAiServer.LmStudioUrl);

    private void UseLocalAddress(string address)
    {
        LocalAddress.Text = address;
        CommitLocal();
    }

    private void ShowStatus(string message, bool error)
    {
        KeyStatus.Visibility = error ? Visibility.Collapsed : Visibility.Visible;
        KeyError.Visibility = error ? Visibility.Visible : Visibility.Collapsed;
        (error ? KeyError : KeyStatus).Text = message;
    }

    private void ShowDeepLStatus(OnlineKeyCheck check)
    {
        var text = Localizer.Current;
        // Mac/iPhone'daki DeepLUsageText ile aynı metinler: her hata kendi nedeniyle (geçersiz karakter, 429, HTTP kodu, ağ yok).
        ShowStatus(check.State switch
        {
            OnlineKeyState.Valid when check.Limit >= OnlineKeyCheck.Unlimited => text.Format("This month: %@ characters used (no limit).", check.Used.ToString("N0")),
            OnlineKeyState.Valid when check.Limit <= 0 => text["DeepL accepted the key. This month's usage could not be read."],
            OnlineKeyState.Valid => text.Format("This month: %1$@ of %2$@ characters used.", check.Used.ToString("N0"), check.Limit.ToString("N0")),
            OnlineKeyState.QuotaExceeded => text["This month's DeepL limit is used up. Until it renews, the translation model on this computer translates."],
            OnlineKeyState.Invalid when check.Reason == OnlineKeyReason.MalformedKey =>
                text["The key contains characters a DeepL key cannot have. Copy it again from your DeepL account page."],
            OnlineKeyState.Invalid => text["DeepL did not accept this key. Copy it again from your DeepL account page."],
            OnlineKeyState.KeychainWriteFailed => text["The API key could not be saved to this computer's secure storage."],
            OnlineKeyState.Busy => text["DeepL is receiving too many requests right now (HTTP 429). The key is saved; DeepL translates again in a few minutes."],
            _ when check.Reason == OnlineKeyReason.HttpStatus => text.Format("DeepL answered with an error (HTTP %lld). Try again in a few minutes.", check.Code),
            _ => text["DeepL could not be reached. Check your internet connection."],
        }, check.State is not (OnlineKeyState.Valid or OnlineKeyState.QuotaExceeded or OnlineKeyState.Busy));
    }

    private void ShowAiResult(AiTestResult result, TranslationEngine engine)
    {
        if (result.State == OnlineKeyState.Valid)
            ShowStatus(Localizer.Current.Format("It works. Sample translation: %@", result.Sample ?? ""), false);
        else
            ShowStatus(result.State.Describe(engine, Localizer.Current, controller.Settings.LocalAiServer), true);
    }

    private async Task ShowDeepLUsageAsync() => ShowDeepLStatus(await controller.CheckDeepLKeyAsync());

    private void OnEngine(object sender, SelectionChangedEventArgs e)
    {
        if (loading) return;
        Update(s => s.WithEngine(SelectedEngine));
        ShowEngine();
    }

    private void OnOcrEngine(object sender, SelectionChangedEventArgs e)
    {
        if (OcrEngineChoice.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        var engine = Enum.Parse<OcrEngine>(tag);
        if (controller.Settings.OcrEngine == engine) return;
        Update(s => s with { OcrEngine = engine });
        // İlk seçişte model kendiliğinden iner; inene kadar Windows'un yazı tanıması okur.
        if (engine == OcrEngine.Advanced && !controller.AdvancedOcrInstalled) _ = controller.DownloadAdvancedOcrAsync();
        ShowAdvancedOcr();
    }

    private async void OnDownloadAdvancedOcr(object sender, RoutedEventArgs e) => await controller.DownloadAdvancedOcrAsync();

    /// <summary>Gelişmiş yazı tanıma seçiliyse modelin durumu: indirme düğmesi, ilerleme, hata.</summary>
    private void ShowAdvancedOcr()
    {
        OcrEnginePanel.Visibility = controller.AdvancedOcrAvailable ? Visibility.Visible : Visibility.Collapsed;
        var advanced = controller.Settings.OcrEngine == OcrEngine.Advanced;
        AdvancedOcrDownload.Visibility = advanced && !controller.AdvancedOcrInstalled ? Visibility.Visible : Visibility.Collapsed;
        AdvancedOcrDownloadButton.IsEnabled = !controller.AdvancedOcrDownloading;
        AdvancedOcrProgress.Visibility = AdvancedOcrProgressText.Visibility =
            controller.AdvancedOcrDownloading ? Visibility.Visible : Visibility.Collapsed;
        AdvancedOcrProgress.Value = controller.AdvancedOcrProgress;
        AdvancedOcrProgressText.Text = Localizer.Current["Downloading the model… %lld%%"]
            .Replace("%lld", ((int)(controller.AdvancedOcrProgress * 100)).ToString()).Replace("%%", "%");
        AdvancedOcrError.Text = controller.AdvancedOcrError ?? "";
        AdvancedOcrError.Visibility = advanced && controller.AdvancedOcrError is not null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnTranslationDevice(object sender, SelectionChangedEventArgs e)
    {
        ShowCpuThreads();
        if (TranslationDeviceChoice.SelectedItem is ComboBoxItem { Tag: string tag })
            Update(s => s with { TranslationDevice = Enum.Parse<TranslationDevice>(tag) });
    }

    private void OnCpuThreads(object sender, SelectionChangedEventArgs e)
    {
        ShowCpuThreads();
        if (CpuThreadChoice.SelectedItem is ComboBoxItem { Tag: int count })
            Update(s => s with { CpuTranslationThreads = count });
    }

    private void ShowCpuThreads()
    {
        if (CpuThreadPanel is null || CpuThreadWarning is null) return;
        CpuThreadPanel.Visibility = TranslationDeviceChoice.SelectedItem is ComboBoxItem { Tag: "Cpu" }
            ? Visibility.Visible : Visibility.Collapsed;
        CpuThreadWarning.Visibility = CpuThreadChoice?.SelectedItem is ComboBoxItem { Tag: int count }
                                      && CpuThreadOptions.NearCapacity(count, Environment.ProcessorCount)
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnFastSubtitleDetection(object sender, RoutedEventArgs e) =>
        Update(s => s with { FastSubtitleDetection = FastSubtitleDetection.IsChecked == true });

    private void OnAutoReadGamePhone(object sender, RoutedEventArgs e) =>
        Update(s => s with { TranslatesGamePhone = AutoReadGamePhone.IsChecked == true });

    private void OnPhoneMessages(object sender, RoutedEventArgs e) =>
        Update(s => s with { PhoneMessagesPanel = PhoneMessagesPanel.IsChecked == true });

    private async void OnKeySave(object sender, RoutedEventArgs e)
    {
        var engine = SelectedEngine;
        KeySave.IsEnabled = false;
        KeyBox.IsEnabled = false;
        // Deneme sürerken düğme bekleme durumunu gösterir (Mac'teki "Testing…" ile aynı).
        KeySave.Content = Localizer.Current["Testing…"];
        try
        {
            if (engine == TranslationEngine.Local)
            {
                CommitLocal();
                var result = await controller.TestLocalAiAsync(KeyBox.Password);
                if (controller.HasKey(engine)) KeyBox.Clear();
                ShowEngine();
                ShowAiResult(result, engine);
            }
            else if (engine.Provider() is { } provider)
            {
                var result = await controller.SetAiKeyAsync(provider, KeyBox.Password);
                var saved = controller.HasKey(engine);
                if (saved) KeyBox.Clear();
                ShowEngine();
                ShowAiResult(result, engine);
            }
            else
            {
                var check = await controller.SetDeepLKeyAsync(KeyBox.Password);
                if (controller.HasDeepLKey) KeyBox.Clear();
                ShowEngine();
                ShowDeepLStatus(check);
            }
        }
        finally
        {
            KeySave.IsEnabled = engine != TranslationEngine.Local || LocalAiServer.Normalize(LocalAddress.Text) is not null;
            KeyBox.IsEnabled = true;
            KeySave.Content = Localizer.Current[engine == TranslationEngine.Local ? "Test connection" : "Save and test"];
        }
    }

    private async void OnKeyTest(object sender, RoutedEventArgs e)
    {
        var engine = SelectedEngine;
        if (engine.Provider() is not { } provider) return;
        var isLocal = engine == TranslationEngine.Local;
        if (isLocal) CommitLocal();
        KeyTest.IsEnabled = false;
        KeyTest.Content = Localizer.Current["Testing…"];
        try
        {
            ShowAiResult(isLocal ? await controller.TestLocalAiAsync() : await controller.TestAiKeyAsync(provider), engine);
        }
        finally
        {
            KeyTest.IsEnabled = true;
            KeyTest.Content = Localizer.Current[isLocal ? "Test connection" : "Test"];
        }
    }

    private void OnKeyRemove(object sender, RoutedEventArgs e)
    {
        var engine = SelectedEngine;
        controller.RemoveKey(engine);
        ShowEngine();
    }

    /// <summary>Hizmetin listedeki modelleri; seçili olan işaretlenir.</summary>
    private void ShowModels(AiProvider provider)
    {
        var wasLoading = loading;
        loading = true;
        ModelChoice.Items.Clear();
        var selected = provider.Model(controller.Settings.ModelFor(provider)).Id;
        foreach (var option in provider.Models())
            ModelChoice.Items.Add(new ComboBoxItem { Content = Localizer.Current[option.Label], Tag = option.Id, IsSelected = option.Id == selected });
        loading = wasLoading;
    }

    private void OnModel(object sender, SelectionChangedEventArgs e)
    {
        if (loading || SelectedEngine.Provider() is not { } provider || ModelChoice.SelectedItem is not ComboBoxItem { Tag: string id }) return;
        Update(s => s.WithModel(provider, id));
    }

    /// <summary>"Ücretsiz anahtar al": Gemini seçilir (anahtar alanı görünür) ve Google AI Studio'nun anahtar sayfası açılır.</summary>
    private void OnFreeGemini(object sender, RoutedEventArgs e)
    {
        controller.ChooseFreeGemini();
        loading = true;
        Engine.SelectedItem = Engine.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == nameof(TranslationEngine.Gemini));
        loading = false;
        ShowEngine();
        Process.Start(new ProcessStartInfo(AiProvider.Gemini.KeyPage().AbsoluteUri) { UseShellExecute = true });
    }

    private void OnLink(object sender, RequestNavigateEventArgs e) =>
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });

    /// <summary>Ayarların sahibi olan pencere (ileti kutuları ve dosya seçicileri bunun üstünde açılır).</summary>
    private Window? Host => Window.GetWindow(this) ?? Application.Current?.MainWindow;

    /// <summary>Ayarlardan bir işe geçilince (Xbox bağla, yeniden kur …) ana ekrana dönülür; eskiden ayar penceresi kapanırdı.</summary>
    private void Leave() => ShellWindow.Navigate(ShellTab.Home);

    /// <summary>Ayarlar sekmesini açar.</summary>
    public static void Open(Window? owner, AppController controller) => ShellWindow.Navigate(ShellTab.Settings);

    /// <summary>Ayarları belli bir bölümde açar (ana ekrandaki bilgi karosunun "Çeviri" satırı).</summary>
    public static void Open(Window? owner, AppController controller, SettingsSection section) => ShellWindow.Navigate(ShellTab.Settings, section);

    /// <summary>Kabuk Ayarlar sekmesini açınca istenen bölüm seçilir.</summary>
    internal void Show(SettingsSection? section)
    {
        if (section is not { } wanted) return;
        Sections.SelectedItem = wanted switch
        {
            SettingsSection.Appearance => AppearanceSection,
            SettingsSection.Translation => TranslationSection,
            SettingsSection.PictureSource => PictureSourceSection,
            _ => Sections.SelectedItem,
        };
    }

    private void Update(Func<UserSettings, UserSettings> change)
    {
        if (loading) return;
        controller.Settings = change(controller.Settings);
        ShowPace();
        ShowMiniSubtitle();
    }

    // ───── Yeni arayüz: gezinme, Temel sayfası ─────

    /// <summary>Soldaki gezinme satırı seçilince o sayfa açılır.</summary>
    /// <summary>Menüdeki sırasıyla sayfa açar (0 Temel … 8 Konsol ve Kaynak); ekran görüntüsü aracı için.</summary>
    public void ShowPage(int index) => Sections.SelectedIndex = index;

    private void OnNav(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string tag } && int.TryParse(tag, out var index) && Sections.SelectedIndex != index)
            Sections.SelectedIndex = index;
    }

    /// <summary>Sayfa başka yoldan (ana ekrandaki satır, "Altyazı Görünümünü Düzenle") açılınca gezinme de seçilir.</summary>
    private void OnSection(object sender, SelectionChangedEventArgs e)
    {
        if (e.OriginalSource != Sections) return;
        foreach (var item in Nav.Children.OfType<Controls.NavItem>())
            item.IsChecked = item.Tag is string tag && tag == Sections.SelectedIndex.ToString(System.Globalization.CultureInfo.InvariantCulture);
        MoveSelection(true);
        ShowHeading();
        if (Sections.SelectedContent is FrameworkElement page) Theme.Motion.EnterFrom(page, 8, Theme.Motion.Medium);
    }

    private void OnEditAppearance(object sender, RoutedEventArgs e) => Sections.SelectedItem = AppearanceSection;

    /// <summary>Bu genişliğin altında soldaki menü yalnız simgelere iner (ad ipucunda); sağdaki sayfaya yer kalır.</summary>
    private const double CompactNavBelow = 1000;
    private bool compactNav;

    /// <summary>
    /// Dar pencere (ör. 800 px): menü kartı 240'tan simge genişliğine (simge 30 + satır ve kart iç boşlukları + 1 px
    /// kenarlar) iner, satırın adı ipucunda görünür. Genişleyince eski haline döner. Seçim hapı NavHost boyu değişince
    /// yeniden yerleşir.
    /// </summary>
    private void UseCompactNav(bool compact)
    {
        if (compact == compactNav) return;
        compactNav = compact;
        if (compact) NavCard.Width = 30 + 4 * Sp.V("s") + 2;
        else NavCard.SetResourceReference(WidthProperty, "size.settingsNav");
        foreach (var item in Nav.Children.OfType<Controls.NavItem>())
        {
            item.Compact = compact;
            item.ToolTip = compact ? item.Content : null;
        }
    }

    /// <summary>
    /// Seçim hapını seçili menü satırına taşır (Mac matchedGeometryEffect): konum ve yükseklik giriş eğrisiyle orta sürede
    /// kayar; hareket azaltılmışsa ya da Geçiş Animasyonları kapalıysa kısa sürede.
    /// </summary>
    private void MoveSelection(bool animate)
    {
        var item = Nav.Children.OfType<Controls.NavItem>().FirstOrDefault(i => i.IsChecked == true);
        if (item is null || !item.IsLoaded || item.ActualHeight <= 0)
        {
            Selection.Visibility = Visibility.Hidden;
            return;
        }
        var top = item.TranslatePoint(new Point(0, 0), NavHost).Y;
        var height = item.ActualHeight;
        var wasHidden = Selection.Visibility != Visibility.Visible;
        Selection.Visibility = Visibility.Visible;
        if (!animate || wasHidden)
        {
            SelectionOffset.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty, null);
            Selection.BeginAnimation(HeightProperty, null);
            SelectionOffset.Y = top;
            Selection.Height = height;
            return;
        }
        SelectionOffset.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty, Theme.Motion.To(top, Theme.Motion.Medium));
        Selection.BeginAnimation(HeightProperty, Theme.Motion.To(height, Theme.Motion.Medium));
    }

    /// <summary>
    /// Çeviri hızı: Hızlı (kötü okunan satır beklenmez), Dengeli (önerilen bekleme süreleri), Doğru (cümle tamamlanana
    /// dek daha uzun beklenir). Gelişmiş'teki iki kaydırıcının hazır değerleridir; onlar elle değişince seçim kalkar.
    /// </summary>
    private static readonly (string Tag, int Misread, int Partial, string Hint)[] Paces =
    [
        ("Fast", 400, 0, "Subtitles arrive as fast as possible; you may rarely see half a sentence."),
        ("Balanced", 800, 300, "Recommended for most games. Speed and accuracy balanced."),
        ("Accurate", 1000, 800, "Translated once the sentence is complete; arrives about half a second later."),
    ];

    private void OnPace(object sender, RoutedEventArgs e)
    {
        if (loading || sender is not RadioButton { Tag: string tag }) return;
        var pace = Paces.First(p => p.Tag == tag);
        MisreadWait.Value = pace.Misread / 1000.0;
        PartialWait.Value = pace.Partial / 1000.0;
        ShowPace();
    }

    private void ShowPace()
    {
        var settings = controller.Settings;
        var match = Paces.FirstOrDefault(p => p.Misread == settings.MisreadWaitMs && p.Partial == settings.PartialWaitMs);
        var was = loading;
        loading = true;
        PaceFast.IsChecked = match.Tag == "Fast";
        PaceBalanced.IsChecked = match.Tag == "Balanced";
        PaceAccurate.IsChecked = match.Tag == "Accurate";
        loading = was;
        PaceHint.Text = match.Tag is null ? "" : Localizer.Current[match.Hint];
        PaceHint.Visibility = match.Tag is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnStartupSound(object sender, RoutedEventArgs e)
    {
        Update(s => s with { StartupSound = StartupSound.IsChecked == true });
    }

    private void OnTransitionAnimations(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        var on = TransitionAnimations.IsChecked == true;
        Update(s => s with { TransitionAnimations = on });
        Theme.Motion.AnimationsEnabled = on;
    }

    /// <summary>Ekran yazıları kartı varsayılana döner (Mac, iPhone, Android ile aynı alanlar).</summary>
    private void OnScreenTextDefaults(object sender, RoutedEventArgs e)
    {
        var defaults = new UserSettings();
        AutoScreenText.IsChecked = defaults.AutoScreenText;
        AutoReadGamePhone.IsChecked = defaults.TranslatesGamePhone;
        SetTextApart.IsChecked = defaults.SetTextApart;
        ScreenTextMission.IsChecked = defaults.ScreenTextMission;
        ScreenTextHelp.IsChecked = defaults.ScreenTextHelp;
        ScreenTextMenus.IsChecked = defaults.ScreenTextMenus;
        ScreenTextOther.IsChecked = defaults.ScreenTextOther;
    }

    /// <summary>TV durumu noktası: bağlı yeşil, yeniden bağlanıyor amber, bekliyor gri.</summary>
    private void ShowTvStatus()
    {
        TvStatusDot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty,
            controller.TvClients > 0 ? "successBrush" : controller.TvReconnecting || controller.TvNotResponding ? "accentBrush" : "textTertiaryBrush");
        TvCardHost.Content = TvCard(controller.Tv, controller.HasTv, controller.TvClients > 0);
    }

    /// <summary>
    /// TV kartı (Mac DSTVCard, eylemsiz): 36'lık simge karesi, ad + mono "Marka · adres", sağda durum hapı. Her zaman kıl çizgi;
    /// TV uygulaması bağlıyken 2 px amber kenar + amber yumuşak dolgu + ışıma ve amber simge.
    /// </summary>
    private static FrameworkElement TvCard(CouchSubs.Core.LgTv.LgTv? tv, bool linked, bool connected)
    {
        var text = Localizer.Current;
        var brand = tv?.Brand switch { CouchSubs.Core.LgTv.TvBrand.Samsung => "Samsung", CouchSubs.Core.LgTv.TvBrand.AndroidTv => "Android TV", _ => "LG" };
        var name = new TextBlock { Text = tv is null ? "TV" : tv.Name.Length == 0 ? brand : tv.Name, FontWeight = FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        name.SetResourceReference(TextBlock.FontSizeProperty, "bodyStrongFontSize");
        name.SetResourceReference(TextBlock.ForegroundProperty, "textBrush");
        var detail = new TextBlock { Text = tv is null ? "" : $"{brand} · {tv.Host}", FontSize = 11, FontWeight = FontWeights.Medium, Margin = Sp.T("0", "line", "0", "0"),
            TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        System.Windows.Documents.Typography.SetNumeralAlignment(detail, FontNumeralAlignment.Tabular);
        detail.SetResourceReference(TextBlock.ForegroundProperty, "mutedBrush");
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = Sp.T("s", "0", "s", "0") };
        names.Children.Add(name);
        if (tv is not null) names.Children.Add(detail);
        var row = new DockPanel();
        var square = new Controls.IconSquare { Glyph = "", Tone = connected ? Controls.IconTone.Amber : Controls.IconTone.Gray, Size = 36 };
        DockPanel.SetDock(square, Dock.Left);
        row.Children.Add(square);
        if (linked)
        {
            var chip = new Controls.Chip { Text = text["Linked"], Tone = connected ? Controls.ChipTone.Ok : Controls.ChipTone.Muted };
            DockPanel.SetDock(chip, Dock.Right);
            row.Children.Add(chip);
        }
        row.Children.Add(names);
        var card = new Border { CornerRadius = new CornerRadius(18), Padding = Sp.T("s"), MinHeight = 64, BorderThickness = new Thickness(connected ? 2 : 1), Child = row };
        card.SetResourceReference(Border.BackgroundProperty, connected ? "amberSoftBrush" : "surfaceBrush");
        card.SetResourceReference(Border.BorderBrushProperty, connected ? "amberBrush" : "cardEdgeBrush");
        if (!connected) return card;
        // Seçili (bağlı) kartın arkasında hafif amber ışıma.
        var glow = new Border { CornerRadius = new CornerRadius(18), Effect = Controls.PerdeEffects.AmberGlow(22, 0, 0.35) };
        glow.SetResourceReference(Border.BackgroundProperty, "surfaceBrush");
        var surface = new Border { CornerRadius = new CornerRadius(18) };
        surface.SetResourceReference(Border.BackgroundProperty, "surfaceBrush");
        var stack = new Grid();
        stack.Children.Add(glow);
        stack.Children.Add(surface);
        stack.Children.Add(card);
        return stack;
    }

    /// <summary>Temel sayfasındaki küçük altyazı plakası (Perde sahnesinin altında).</summary>
    private readonly Border MiniSubtitle = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = Sp.T("m"), Padding = Sp.T("s", "xs", "s", "xs"),
        CornerRadius = new CornerRadius(10), Child = new TextBlock { FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center },
    };

    private TextBlock MiniSubtitleText => (TextBlock)MiniSubtitle.Child;

    /// <summary>Bölümlerin başlığı (Mac SectionHeading): simge, ton, ad ve iki kelimelik alt yazı; menü sırasıyla.</summary>
    private static readonly (string Glyph, Controls.IconTone Tone, string Title, string Hint)[] Headings =
    [
        ("\uE9E9", Controls.IconTone.Amber, "Basics", "Translation, Sound"),
        ("\uE8D2", Controls.IconTone.Peach, "Subtitle Appearance", "Size, Colors"),
        ("\uE713", Controls.IconTone.Gray, "Advanced", "Engine, On-Screen Text"),
        ("\uE8B3", Controls.IconTone.Olive, "Subtitle Area", "Frame, Extra Areas"),
        ("\uE7B8", Controls.IconTone.Olive, "Game Packs", "Ready Translations"),
        ("\uE8D6", Controls.IconTone.Plum, "Turkish Dubbing", "Voices, Characters"),
        ("\uE7F4", Controls.IconTone.Teal, "Output Screens", "TV, OBS"),
        ("\uE765", Controls.IconTone.Sky, "Keyboard Shortcuts", "Translation Keys"),
        ("\uE7FC", Controls.IconTone.Gray, "Console and Source", "PS5, Xbox"),
    ];

    /// <summary>
    /// Sağ sütunun başındaki bölüm başlığı (Mac SectionHeading): 40'lık renkli simge karesi + başlık (24) + iki kelimelik alt
    /// yazı. Kayan içeriğin içinde durur (cam üst çubuğun arkasından geçer).
    /// </summary>
    private void ShowHeading()
    {
        var index = Math.Clamp(Sections.SelectedIndex, 0, Headings.Length - 1);
        var (glyph, tone, title, hint) = Headings[index];
        var text = Localizer.Current;
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = Sp.T("s", "0", "0", "0") };
        var heading = new TextBlock { Text = text[title], FontWeight = FontWeights.Medium };
        heading.SetResourceReference(TextBlock.FontSizeProperty, "h2FontSize");
        heading.SetResourceReference(TextBlock.ForegroundProperty, "textBrush");
        System.Windows.Automation.AutomationProperties.SetHeadingLevel(heading, System.Windows.Automation.AutomationHeadingLevel.Level1);
        names.Children.Add(heading);
        var sub = new TextBlock { Text = text[hint], Margin = Sp.T("0", "line", "0", "0") };
        sub.SetResourceReference(StyleProperty, "HintText");
        names.Children.Add(sub);
        var row = new DockPanel { Margin = Sp.T("0", "0", "0", "m") };
        var square = new Controls.IconSquare { Glyph = glyph, Tone = tone, Size = 40 };
        DockPanel.SetDock(square, Dock.Left);
        row.Children.Add(square);
        row.Children.Add(names);
        Sections.Tag = row;
    }

    /// <summary>Menüde amber simge karesinin simgesi koyu (Perde: amberde koyu, diğer tonlarda beyaz).</summary>
    private void DarkenAmberGlyph()
    {
        foreach (var item in Nav.Children.OfType<Controls.NavItem>().Where(item => item.Tag is "0"))
        {
            item.ApplyTemplate();
            if (item.Template?.FindName("Glyph", item) is TextBlock glyph) glyph.Foreground = new SolidColorBrush(Color.FromRgb(0x1D, 0x1E, 0x22));
        }
    }

    /// <summary>Temel sayfasındaki küçük altyazı önizlemesi: yazı boyu, zemin koyuluğu ve yazı rengi.</summary>
    private void ShowMiniSubtitle()
    {
        var style = controller.Settings.Style;
        var alpha = (byte)Math.Round(Math.Clamp(style.Background, 0, 100) / 100.0 * 255);
        MiniSubtitle.Background = new SolidColorBrush(SpeakerText.Rgb(style.BackgroundRgb, alpha));
        MiniSubtitleText.Foreground = new SolidColorBrush(SpeakerText.Rgb(style.TextRgb));
        // Kaydırıcıdaki boy (16–50) yarıya (Mac ile aynı önizleme).
        MiniSubtitleText.FontSize = Math.Clamp(Math.Round((16 + (style.FontSize - 16) * 34.0 / 74) * 0.5), 8, 25);
        MiniSubtitleText.TextWrapping = TextWrapping.NoWrap;
        MiniSubtitleText.Inlines.Clear();
        var name = new System.Windows.Documents.Run("Jason: ");
        name.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "accentBrush");
        MiniSubtitleText.Inlines.Add(name);
        MiniSubtitleText.Inlines.Add(new System.Windows.Documents.Run(Localizer.Current.Language == "tr" ? "Tamam. Gidelim." : "Okay. Let's go."));
    }


    private void OnTextSize(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (loading) return;
        var size = (int)Math.Round(e.NewValue);
        TextSizeValue.Text = size.ToString();
        Update(s => s with { Style = s.Style with { FontSize = size } });
    }

    private void OnFreeTarget(object sender, RoutedEventArgs e)
    {
        if (loading || sender is not RadioButton { Tag: string tag }) return;
        var target = Enum.Parse<ResultTarget>(tag);
        Update(s => s with { FreeAreaTarget = target });
    }

    /// <summary>Önizlemeyi oyunun şu anki görüntüsüyle yeniler (çerçeve olduğu gibi kalır).</summary>
    private void OnRefresh(object sender, RoutedEventArgs e) => Region.Frame = controller.LastFrame;

    private void OnSnapshot() => Dispatcher.Invoke(() => Region.Frame = controller.LastFrame);

    private void OnPosition(object sender, RoutedPropertyChangedEventArgs<double> e) =>
        Update(s => s with { Style = s.Style with { BottomPercent = (int)Math.Round(e.NewValue) } });

    private void OnPositionStart(object sender, System.Windows.Input.MouseButtonEventArgs e) => controller.SendTestSubtitle();

    private void OnPlacement(object sender, SelectionChangedEventArgs e)
    {
        if (Placement.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        var placement = Enum.Parse<SubtitlePlacement>(tag);
        ShowPlacement(placement);
        Update(s => s with { Style = s.Style with { Placement = placement } });
    }

    /// <summary>Elle ayarlanan yükseklik yalnız sabit yerleşimde anlamlıdır.</summary>
    private void ShowPlacement(SubtitlePlacement placement)
    {
        var isFixed = placement == SubtitlePlacement.Fixed;
        FixedPanel.Visibility = isFixed ? Visibility.Visible : Visibility.Collapsed;
        FollowsHint.Visibility = isFixed ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnBackground(object sender, RoutedPropertyChangedEventArgs<double> e) =>
        Update(s => s with { Style = s.Style with { Background = (int)Math.Round(e.NewValue) } });

    private void OnBackgroundShape(object sender, SelectionChangedEventArgs e)
    {
        if (BackgroundShape.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        var shape = Enum.Parse<SubtitleBackgroundShape>(tag);
        Update(s => s with { Style = s.Style with { BackgroundShape = shape } });
    }

    private void OnBold(object sender, RoutedEventArgs e) =>
        Update(s => s with { Style = s.Style with { Bold = Bold.IsChecked == true } });

    private void OnMisreadWait(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        ShowWaits();
        Update(s => s with { MisreadWaitMs = (int)Math.Round(e.NewValue * 1000) });
    }

    private void OnPartialWait(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        ShowWaits();
        Update(s => s with { PartialWaitMs = (int)Math.Round(e.NewValue * 1000) });
    }

    private void OnWaitDefaults(object sender, RoutedEventArgs e)
    {
        FastSubtitleDetection.IsChecked = new UserSettings().FastSubtitleDetection;
        MisreadWait.Value = SubtitlePipeline.PackWaitMs / 1000.0;
        PartialWait.Value = SubtitlePipeline.CleanWaitMs / 1000.0;
    }

    /// <summary>Kaydırıcıların yanındaki süre ("0,8 sn").</summary>
    private void ShowWaits()
    {
        if (MisreadWaitValue is null || PartialWaitValue is null) return;
        var unit = Localizer.Current["sec"];
        MisreadWaitValue.Text = $"{MisreadWait.Value.ToString("0.0", System.Globalization.CultureInfo.CurrentCulture)} {unit}";
        PartialWaitValue.Text = $"{PartialWait.Value.ToString("0.0", System.Globalization.CultureInfo.CurrentCulture)} {unit}";
    }

    private void OnStackPrevious(object sender, RoutedEventArgs e) =>
        Update(s => s with { Style = s.Style with { StackPrevious = StackPrevious.IsChecked == true } });

    private void OnTextColor(object sender, SelectionChangedEventArgs e)
    {
        if (TextColor.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        Update(s => s with { Style = s.Style with { TextColor = Enum.Parse<SubtitleTextColor>(tag) } });
    }

    private void OnDisplayMode(object sender, SelectionChangedEventArgs e)
    {
        if (DisplayMode.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        Update(s => s with { Style = s.Style with { DisplayMode = Enum.Parse<TvDisplayMode>(tag) } });
    }

    private void OnLanguage(object sender, SelectionChangedEventArgs e)
    {
        if (GameLanguage.SelectedItem is ComboBoxItem { Tag: string code }) Update(s => s with { SourceLanguage = code });
    }

    /// <summary>
    /// Çerçeve elle değişti. Altyazı bölgesinde seçim, bölge bir hazır seçimle aynıysa ("Alanı sıfırla") o, değilse Özel olur.
    /// </summary>
    private void OnRegion(object? sender, CropRegion region)
    {
        if (area == 0)
        {
            Update(s => s with { Region = region, AreaPreset = AreaPresets.Matching(region) });
            ShowPreset();
        }
        else if (SelectedExtraArea() is { } extra)
        {
            Update(s => s.WithExtraArea(extra.Id, a => a with { Region = region }));
        }
    }

    /// <summary>Düzenlenen ek alan; altyazı alanı seçiliyse null.</summary>
    private ExtraArea? SelectedExtraArea() => area == 0 ? null : controller.Settings.ExtraAreaAt(area);

    /// <summary>Altyazı bölgesinin hazır seçimi işaretlenir; Özel'de kaydırıcılar bölgeyi gösterir.</summary>
    private void ShowPreset()
    {
        var wasLoading = loading;
        loading = true;
        var settings = controller.Settings;
        (settings.AreaPreset switch
        {
            AreaPreset.Top => PresetTop,
            AreaPreset.Full => PresetFull,
            AreaPreset.Custom => PresetCustom,
            _ => PresetBottom,
        }).IsChecked = true;
        CustomPanel.Visibility = settings.AreaPreset == AreaPreset.Custom ? Visibility.Visible : Visibility.Collapsed;
        var (position, height) = settings.Region.VerticalPercent();
        VerticalPosition.Value = Math.Clamp(Math.Round(position), VerticalPosition.Minimum, VerticalPosition.Maximum);
        AreaHeight.Value = Math.Clamp(Math.Round(height), AreaHeight.Minimum, AreaHeight.Maximum);
        ShowVerticalValues();
        loading = wasLoading;
    }

    private void ShowVerticalValues()
    {
        var text = Localizer.Current;
        VerticalPositionValue.Text = text.Format("%lld%%", (int)Math.Round(VerticalPosition.Value));
        AreaHeightValue.Text = text.Format("%lld%%", (int)Math.Round(AreaHeight.Value));
    }

    /// <summary>Hazır seçim bölgeyi değiştirir; Özel'de kayıtlı bölge kalır, kaydırıcılar açılır.</summary>
    private void OnPreset(object sender, RoutedEventArgs e)
    {
        if (loading || area != 0 || sender is not RadioButton { Tag: string tag }) return;
        var preset = Enum.Parse<AreaPreset>(tag);
        Update(s => s.WithAreaPreset(preset));
        Region.ShowRegion(controller.Settings.Region);
        ShowPreset();
    }

    /// <summary>Özel bölgenin dikey konumu ya da yüksekliği değişti; sol ve sağ kenar olduğu gibi kalır.</summary>
    private void OnVertical(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (loading || area != 0) return;
        ShowVerticalValues();
        var region = controller.Settings.Region.WithVertical(Math.Round(VerticalPosition.Value), Math.Round(AreaHeight.Value));
        Update(s => s.WithCustomRegion(region));
        Region.ShowRegion(region);
    }

    private void OnArea(object sender, RoutedEventArgs e)
    {
        if (!loading && sender is RadioButton { Tag: int tag }) ShowArea(tag);
    }

    /// <summary>
    /// Alan sekmeleri: "Altyazı" ve her ek alan adıyla (adsızsa "Bölge 1"). Sınır dolmadıysa "Ek alan ekle" görünür.
    /// </summary>
    private void BuildAreaTabs()
    {
        var settings = controller.Settings;
        AreaTabs.Children.Clear();
        AreaTabs.Children.Add(AreaTabButton(Localizer.Current["Subtitles"], 0));
        for (var number = 1; number <= settings.ExtraAreas.Count; number++)
            AreaTabs.Children.Add(AreaTabButton(settings.ExtraAreas[number - 1].DisplayName(number), number));
        AddAreaButton.Visibility = settings.CanAddExtraArea ? Visibility.Visible : Visibility.Collapsed;
    }

    private RadioButton AreaTabButton(string title, int number)
    {
        var button = new RadioButton
        {
            Content = title,
            GroupName = "area",
            Style = (Style)FindResource("SegmentButton"),
            Tag = number,
            IsChecked = number == area,
        };
        button.Checked += OnArea;
        return button;
    }

    /// <summary>"Ek alan ekle": hazır köşe seçimleri açılır.</summary>
    private void OnAddArea(object sender, RoutedEventArgs e)
    {
        if (AddAreaButton.ContextMenu is not { } menu) return;
        menu.PlacementTarget = AddAreaButton;
        menu.IsOpen = true;
    }

    /// <summary>Hazır köşe seçimiyle yeni ek alan eklenir (adı seçimin adı) ve onun sekmesi açılır.</summary>
    private void OnAddAreaPreset(object sender, RoutedEventArgs e)
    {
        if (loading || sender is not MenuItem { Tag: string tag } || !controller.Settings.CanAddExtraArea) return;
        var preset = Enum.Parse<ExtraAreaPreset>(tag);
        var name = Localizer.Current[preset switch { ExtraAreaPreset.Quest => "Quest", ExtraAreaPreset.Notification => "Notification", _ => "Phone" }];
        Update(s => s.WithAddedExtraArea(ExtraArea.Create(name, preset.Region())));
        ShowArea(controller.Settings.ExtraAreas.Count);
    }

    /// <summary>Ek alan kaldırılır; arkasındakiler (ve kısayolları) bir sıra öne gelir.</summary>
    private void OnRemoveArea(object sender, RoutedEventArgs e)
    {
        if (loading || SelectedExtraArea() is not { } extra) return;
        Update(s => s.WithoutExtraArea(extra.Id));
        ShowArea(Math.Min(area, controller.Settings.ExtraAreas.Count));
    }

    private void OnAreaName(object sender, TextChangedEventArgs e)
    {
        if (loading || SelectedExtraArea() is not { } extra) return;
        var name = ExtraName.Text;
        Update(s => s.WithExtraArea(extra.Id, a => a with { Name = name }));
        if (AreaTabs.Children.OfType<RadioButton>().FirstOrDefault(tab => tab.Tag is int number && number == area) is { } current)
            current.Content = controller.Settings.ExtraAreaAt(area)?.DisplayName(area) ?? current.Content;
    }

    /// <summary>Seçilen alanın çerçevesini gösterir.</summary>
    private void ShowArea(int slot)
    {
        var wasLoading = loading;
        loading = true;
        var settings = controller.Settings;
        if (slot > settings.ExtraAreas.Count) slot = 0;
        area = slot;
        BuildAreaTabs();
        if (slot == 0)
        {
            ExtraNamePanel.Visibility = Visibility.Collapsed;
            ExtraTargetPanel.Visibility = Visibility.Collapsed;
            ExtraLivePanel.Visibility = Visibility.Collapsed;
            PresetPanel.Visibility = Visibility.Visible;
            ShowPreset();
            Region.IsEnabled = true;
            Region.DefaultRegion = new CropRegion();
            KeepCentered.IsChecked = settings.KeepAreaCentered;
            Region.Centered = settings.KeepAreaCentered;
            Region.ShowRegion(settings.Region);
            ShowSubtitleAreaHint();
        }
        else
        {
            var extra = settings.ExtraAreas[slot - 1];
            ExtraNamePanel.Visibility = Visibility.Visible;
            ExtraName.Text = extra.Name;
            PresetPanel.Visibility = Visibility.Collapsed;
            ExtraTargetPanel.Visibility = Visibility.Visible;
            ExtraLivePanel.Visibility = Visibility.Visible;
            ExtraLive.IsChecked = extra.Enabled;
            ShowExtraFullScreenHint(settings);
            (extra.Target switch { ResultTarget.Pc => ExtraPc, ResultTarget.Both => ExtraBoth, _ => ExtraTv }).IsChecked = true;
            Region.IsEnabled = true;
            Region.DefaultRegion = ExtraAreaPreset.Quest.Region();
            Region.Centered = false;
            Region.ShowRegion(extra.Region);
            ShowAreaHint();
        }
        loading = wasLoading;
    }

    /// <summary>Altyazı alanının ipucu: "ortalı kalır" yalnız Ortada tut açıkken yazılır.</summary>
    private void ShowSubtitleAreaHint() =>
        AreaHint.Text = Localizer.Current[controller.Settings.KeepAreaCentered
            ? "Drag on the picture to draw the area where the game shows its subtitles. Drag an edge or corner to resize it; it stays centered. Drag the inside to move it."
            : "Drag on the picture to draw the area where the game shows its subtitles. Drag an edge or corner to resize it, or the inside to move it."];

    /// <summary>Ortada tut: açıkken altyazı alanı ortadan boyutlanır; kapalıyken yalnız tutulan kenar oynar.</summary>
    private void OnKeepCentered(object sender, RoutedEventArgs e)
    {
        if (loading || area != 0) return;
        var on = KeepCentered.IsChecked == true;
        Update(s => s with { KeepAreaCentered = on });
        Region.Centered = on;
        ShowSubtitleAreaHint();
    }

    private void OnExtraTarget(object sender, RoutedEventArgs e)
    {
        if (loading || sender is not RadioButton { Tag: string tag } || SelectedExtraArea() is not { } extra) return;
        var target = Enum.Parse<ResultTarget>(tag);
        Update(s => s.WithExtraArea(extra.Id, a => a with { Target = target }));
    }

    /// <summary>
    /// Altyazı alanı Tam ekranken sürekli okuma durur (bkz. <see cref="UserSettings.ExtraAreasPausedByFullScreen"/>);
    /// "Sürekli oku" ayarı korunur, kullanıcıya nedeni yazılır.
    /// </summary>
    private void ShowExtraFullScreenHint(UserSettings settings)
    {
        var paused = settings.ExtraAreasPausedByFullScreen;
        ExtraFullScreenHint.Text = paused
            ? Localizer.Current["Extra areas aren't read while the subtitle area is Full screen, because the whole screen is already read. They're read again when you pick another area."]
            : "";
        ExtraFullScreenHint.Visibility = paused ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Ek bölge tuşa basmadan da sürekli okunsun (görev, telefon mesajı, bildirim).</summary>
    private void OnExtraLive(object sender, RoutedEventArgs e)
    {
        if (loading || SelectedExtraArea() is not { } extra) return;
        var live = ExtraLive.IsChecked == true;
        Update(s => s.WithExtraArea(extra.Id, a => a with { Enabled = live }));
    }

    /// <summary>Hazır köşe seçimi: çerçeve o köşeye gelir.</summary>
    private void OnExtraPreset(object sender, RoutedEventArgs e)
    {
        if (loading || sender is not Button { Tag: string tag } || SelectedExtraArea() is not { } extra) return;
        var region = Enum.Parse<ExtraAreaPreset>(tag).Region();
        Region.ShowRegion(region);
        Update(s => s.WithExtraArea(extra.Id, a => a with { Region = region }));
    }

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        controller.SendTestSubtitle();
        // Eşli TV'ye ulaşılamıyorsa deneme altyazısı gitmez; kart bunu söyler (adres değişmiş olabilir).
        await controller.EnsureTvReachableAsync();
    }

    /// <summary>~10 sn'de bir eşli TV'nin adresine bakar (kart görünürken).</summary>
    private readonly System.Windows.Threading.DispatcherTimer tvReachWatch = new() { Interval = TimeSpan.FromSeconds(10) };

    /// <summary>"TV'yi Eşleştir" / "Deneme Altyazısı Gönder" TV'ye ulaşamadıysa hata ve "TV'yi Yeniden Ara", "IP Adresi Gir".</summary>
    private void ShowTvUnreachable()
    {
        TvUnreachableBox.Text = controller.TvUnreachableProblem;
        TvUnreachablePanel.Visibility = controller.HasTvUnreachableProblem ? Visibility.Visible : Visibility.Collapsed;
        if (!controller.HasTvUnreachableProblem) TvAddressPanel.Visibility = Visibility.Collapsed;
    }

    private void OnChangeTv(object sender, RoutedEventArgs e)
    {
        controller.ChangeTv();
        Leave();
    }

    private void OnRemoveTvPairing(object sender, RoutedEventArgs e)
    {
        var text = Localizer.Current;
        var answer = MessageBox.Show(Host, text["The paired TV will be removed. You can choose a TV again with Change the TV."], text["Remove Pairing?"],
            MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.OK) return;
        controller.RemoveTvPairing();
    }

    private async void OnSearchTvAgain(object sender, RoutedEventArgs e) => await controller.SearchTvAgainAsync();

    /// <summary>PS5 "IP Adresi Gir" (konsol kartı): alan açılır/kapanır.</summary>
    private void OnEnterPs5Address(object sender, RoutedEventArgs e)
    {
        var open = Ps5AddressPanel.Visibility != Visibility.Visible;
        Ps5AddressPanel.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        if (open)
        {
            Ps5Address.Text = controller.Console?.Host ?? "";
            Ps5Address.Focus();
            Ps5Address.SelectAll();
        }
    }

    private void OnUsePs5Address(object sender, RoutedEventArgs e)
    {
        if (!controller.UsePs5Address(Ps5Address.Text)) return;
        Ps5AddressPanel.Visibility = Visibility.Collapsed;
        ShowConsole();
    }

    private void OnPs5AddressKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) OnUsePs5Address(sender, e);
    }

    private void ShowPs5AddressProblem()
    {
        Ps5AddressError.Text = controller.Ps5AddressProblem ?? "";
        Ps5AddressError.Visibility = controller.Ps5AddressProblem is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnEnterTvAddress(object sender, RoutedEventArgs e)
    {
        TvAddressPanel.Visibility = Visibility.Visible;
        TvAddress.Focus();
    }

    private async void OnUseTvAddress(object sender, RoutedEventArgs e)
    {
        if (await controller.UseTvAddressAsync(TvAddress.Text)) TvAddress.Text = "";
    }

    private void OnTvAddressKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) OnUseTvAddress(sender, e);
    }

    private void OnAbout(object sender, RoutedEventArgs e) => AboutWindow.Open(Host);

    private void OnReset(object sender, RoutedEventArgs e)
    {
        var text = Localizer.Current;
        var answer = MessageBox.Show(Host, text["The saved PS5, account and TV connection will be removed."], text["Set up again?"],
            MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.OK) return;
        controller.ResetSetup();
        Leave();
    }


    private void OnStreamBackground(object sender, SelectionChangedEventArgs e)
    {
        if (StreamBackgroundChoice.SelectedItem is ComboBoxItem { Tag: string tag } && Enum.TryParse<StreamBackground>(tag, out var background))
            controller.StreamBackground = background;
    }

    /// <summary>Akış penceresi açıkken düğme onu kapatır (Mac'teki "Akış penceresini kapat" ile aynı).</summary>
    private void OnOpenStreamWindow(object sender, RoutedEventArgs e)
    {
        if (StreamWindow.IsOpen) StreamWindow.CloseIfOpen();
        else StreamWindow.Open(controller);
        ShowStreamWindowToggle();
    }

    private void ShowStreamWindowToggle() =>
        StreamWindowToggle.Content = Localizer.Current[StreamWindow.IsOpen ? "Close the stream window" : "Open the stream window"];

    /// <summary>Ek bölgenin ipucu, o bölgenin kısayoluyla.</summary>
    private void ShowAreaHint()
    {
        if (area == 0) return;
        if (area > ExtraArea.ShortcutCount)
        {
            // Dördüncü ve sonraki alanların kısayolu yok: yalnız sürekli okunur.
            AreaHint.Text = Localizer.Current["No Shortcut"] + " · " + Localizer.Current["Also reads small text next to the subtitle, such as objectives, phone messages or notifications. Each area is read once a second and translated again when the text changes; the translation appears on the TV next to that text."];
            return;
        }
        var action = HotkeyTable.AreaActions[Math.Clamp(area, 1, HotkeyTable.AreaActions.Count) - 1];
        AreaHint.Text = HotkeyText.Sentence(controller.Settings, action,
            "Draw the area to translate, for example a quest panel. While you play, press its shortcut (%@) to read and translate it once. Choose where the result shows. It works even when CouchSubs is in the background.");
    }

    /// <summary>Kısayolların geçtiği bütün metinler ve Kısayollar'daki düğmeler kullanıcının seçtiği tuşları gösterir.</summary>
    private void ShowShortcutTexts()
    {
        var settings = controller.Settings;
        RefreshButton.Content = HotkeyText.Title(settings, HotkeyAction.Snapshot, "Refresh picture (%@)");
        ScreenCard.Title = HotkeyText.Title(settings, HotkeyAction.Screen, "Translate the screen (%@)");
        ScreenHint.Text = HotkeyText.Sentence(settings, HotkeyAction.Screen,
            "Press %@ while playing: every text on the screen is translated once and shown on the TV in its own place. Press again to remove the translations.");
        FreeAreaCard.Title = HotkeyText.Title(settings, HotkeyAction.FreeArea, "Free area (%@)");
        FreeAreaHint.Text = HotkeyText.Sentence(settings, HotkeyAction.FreeArea,
            "Press %@ while playing: the picture freezes on the PC, drag over any part of it to translate that part once. Esc closes.");
        PauseHint.Text = HotkeyText.Sentence(settings, HotkeyAction.PauseSubtitles,
            "%@ pauses or resumes the live subtitle translation, which helps when you translate areas.");
        ShowAreaHint();
        foreach (var ((action, slot), button) in shortcutButtons)
            if (recording?.Button != button) button.Content = ShortcutLabel(HotkeyTable.KeyFor(settings.Hotkeys, action, slot));
    }

    private static string ShortcutLabel(HotkeyKey? key) => key?.Label ?? Localizer.Current["Not set"];

    /// <summary>Kısayollar: her iş bir satır, iki düğme (iki tuş).</summary>
    private void BuildShortcuts()
    {
        foreach (var action in HotkeyText.Order)
        {
            var row = ShortcutGrid.RowDefinitions.Count;
            ShortcutGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var name = new TextBlock
            {
                Text = HotkeyText.Name(action),
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                Margin = Sp.T("0", "0", "m", "xs"),
            };
            // Satır adı gövde yazısı rengiyle (tema kaynağı; açık ve koyu temada okunur).
            name.SetResourceReference(TextBlock.ForegroundProperty, "textPrimaryBrush");
            Grid.SetRow(name, row);
            ShortcutGrid.Children.Add(name);
            for (var slot = 0; slot < HotkeyTable.SlotCount; slot++)
            {
                var button = new Button { MinWidth = 160, Margin = new Thickness(slot == 0 ? 0 : Sp.V("xs"), 0, 0, Sp.V("xs")), Tag = (action, slot) };
                button.Click += OnShortcutClick;
                button.LostKeyboardFocus += (_, _) => { if (recording?.Button == button) StopRecording(); };
                Grid.SetRow(button, row);
                Grid.SetColumn(button, 1 + slot);
                ShortcutGrid.Children.Add(button);
                shortcutButtons[(action, slot)] = button;
            }
        }
    }

    private void OnShortcutClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ValueTuple<HotkeyAction, int> tag } button) return;
        if (recording?.Button == button)
        {
            StopRecording();
            return;
        }
        StopRecording();
        ShowShortcutMessage(null, null);
        recording = (tag.Item1, tag.Item2, button);
        button.Content = Localizer.Current["Press the keys…"];
        // Çeviri sürerken basılan tuş kısayol olarak çalışmasın, buraya gelsin.
        controller.HotkeysPaused = true;
        button.Focus();
    }

    /// <summary>Yeni tuşu beklemeyi bırakır; düğme kayıtlı tuşu gösterir, kısayollar yeniden tutulur.</summary>
    private void StopRecording()
    {
        if (recording is not { } current) return;
        recording = null;
        current.Button.Content = ShortcutLabel(HotkeyTable.KeyFor(controller.Settings.Hotkeys, current.Action, current.Slot));
        controller.HotkeysPaused = false;
    }

    private void OnShortcutKey(object sender, KeyEventArgs e)
    {
        if (recording is not { } current) return;
        e.Handled = true;
        var key = e.Key switch { Key.System => e.SystemKey, Key.ImeProcessed => e.ImeProcessedKey, _ => e.Key };
        // Değiştirici tek başına basıldı: asıl tuş bekleniyor.
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin)
            return;
        var held = Keyboard.Modifiers;
        if (held == ModifierKeys.None && key == Key.Escape)
        {
            StopRecording();
            return;
        }
        if (held == ModifierKeys.None && key is Key.Back or Key.Delete)
        {
            AssignShortcut(current, null);
            return;
        }
        var modifiers = HotkeyModifiers.None;
        if (held.HasFlag(ModifierKeys.Control)) modifiers |= HotkeyModifiers.Control;
        if (held.HasFlag(ModifierKeys.Alt)) modifiers |= HotkeyModifiers.Alt;
        if (held.HasFlag(ModifierKeys.Shift)) modifiers |= HotkeyModifiers.Shift;
        var chosen = new HotkeyKey(modifiers, (uint)KeyInterop.VirtualKeyFromKey(key));
        // Win tuşlu birleşimler Windows'a aittir.
        var problem = held.HasFlag(ModifierKeys.Windows) ? HotkeyProblem.Reserved : HotkeyTable.Validate(chosen);
        if (problem != HotkeyProblem.None)
        {
            ShowShortcutMessage(null, ProblemText(problem));
            return;
        }
        AssignShortcut(current, chosen);
    }

    private void AssignShortcut((HotkeyAction Action, int Slot, Button Button) target, HotkeyKey? key)
    {
        var text = Localizer.Current;
        // Kısayollar bırakılmışken denenir: alınamıyorsa tuşu başka bir uygulama tutuyordur.
        var busy = key is not null && !GlobalHotkeys.IsAvailable(new WindowInteropHelper(Host).Handle, key);
        var choices = HotkeyTable.Assign(controller.Settings.Hotkeys, target.Action, target.Slot, key, out var displaced);
        recording = null;
        controller.Settings = controller.Settings with { Hotkeys = choices };
        controller.HotkeysPaused = false;
        ShowShortcutTexts();
        var moved = displaced is { } from && key is not null ? text.Format("%@ moved here from “%@”.", key.Label, HotkeyText.Name(from)) : null;
        var taken = busy && key is not null ? text.Format("Another app is using %@. It may not work while that app is open.", key.Label) : null;
        ShowShortcutMessage(moved, taken);
    }

    private void OnShortcutDefaults(object sender, RoutedEventArgs e)
    {
        StopRecording();
        ShowShortcutMessage(null, null);
        controller.Settings = controller.Settings with { Hotkeys = [] };
    }

    private void ShowShortcutMessage(string? message, string? error)
    {
        ShortcutMessage.Text = message ?? "";
        ShortcutMessage.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
        ShortcutError.Text = error ?? "";
        ShortcutError.Visibility = error is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private static string ProblemText(HotkeyProblem problem) => Localizer.Current[problem switch
    {
        HotkeyProblem.NeedsModifier => "Use this key with Ctrl+Shift, Alt or Alt+Shift, so typing in other apps isn't affected.",
        HotkeyProblem.AltGr => "Ctrl+Alt is AltGr on many keyboards and would block characters like # and {. Use Ctrl+Shift instead.",
        HotkeyProblem.Reserved => "Windows already uses this shortcut.",
        _ => "This key can't be a shortcut.",
    }];
}
