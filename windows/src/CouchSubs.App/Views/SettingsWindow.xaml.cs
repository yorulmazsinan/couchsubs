// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
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

public partial class SettingsWindow : Window
{
    private static readonly (string Code, string Name)[] Languages =
        [("en", "English"), ("ja", "Japanese"), ("de", "German"), ("fr", "French"), ("es", "Spanish")];

    /// <summary>Ek bölgeler ilk açıldığında (sağ üst köşe, sağ alt köşe, ekranın ortası) bu alanlarla başlar.</summary>
    private static readonly CropRegion[] ExtraDefaults = [new(0.05, 0.28, 0.60, 0.97), new(0.72, 0.95, 0.60, 0.97), new(0.35, 0.65, 0.30, 0.70)];

    private readonly AppController controller;
    private bool loading = true;
    /// <summary>Çerçevesi düzenlenen bölge: 0 altyazı, 1, 2 ve 3 ek bölgeler.</summary>
    private int area;
    /// <summary>Önizlemenin oyun görüntüsüyle son yenilendiği an (ms).</summary>
    private long lastPreview;
    /// <summary>Kısayollar'da yeni tuşu bekleyen yuva; null ise beklenmiyor.</summary>
    private (HotkeyAction Action, int Slot, Button Button)? recording;
    /// <summary>Kısayollar'daki düğmeler: iş ve yuvaya göre.</summary>
    private readonly Dictionary<(HotkeyAction, int), Button> shortcutButtons = [];

    internal SettingsWindow(AppController controller)
    {
        this.controller = controller;
        InitializeComponent();
        InstalledVersion.Text = Localizer.Current.Format("Installed version: %@", AppVersion.Current(typeof(SettingsWindow).Assembly));
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
        // Num 8: oyunun o anki görüntüsü önizlemeye alınır.
        controller.SnapshotRequested += OnSnapshot;
        Closed += (_, _) => controller.SnapshotRequested -= OnSnapshot;
        Dubbing.Attach(controller);
        FirewallSettings.Attach(controller);
        OutputCard.Attach(controller);
        ShowStyleTitle();
        controller.PropertyChanged += OnControllerChanged;
        Closed += (_, _) => controller.PropertyChanged -= OnControllerChanged;
        Engine.SelectedItem = Engine.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Engine.ToString());
        TranslationDeviceChoice.SelectedItem = TranslationDeviceChoice.Items.Cast<ComboBoxItem>()
            .First(item => (string)item.Tag == settings.TranslationDevice.ToString());
        foreach (var count in CpuThreadOptions.Available(Environment.ProcessorCount))
            CpuThreadChoice.Items.Add(new ComboBoxItem { Content = count.ToString(), Tag = count });
        CpuThreadChoice.SelectedItem = CpuThreadChoice.Items.Cast<ComboBoxItem>()
            .First(item => (int)item.Tag == CpuThreadOptions.Normalize(settings.CpuTranslationThreads, Environment.ProcessorCount));
        FastSubtitleDetection.IsChecked = settings.FastSubtitleDetection;
        WatchSubtitleBackground.IsChecked = settings.WatchSubtitleBackground;
        AutoReadGamePhone.IsChecked = settings.AutoReadGamePhone;
        OcrEngineChoice.SelectedItem = OcrEngineChoice.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.OcrEngine.ToString());
        ShowAdvancedOcr();
        ShowCpuThreads();
        ShowEngine();
        GamePacks.IsChecked = settings.GamePacks;
        SharePool.IsChecked = settings.SharePool;
        AskGame.IsChecked = settings.AskGame;
        SpeakerNames.IsChecked = settings.ShowSpeakerNames;
        SpeakerColors.IsChecked = settings.SpeakerColors;
        AutoScreenText.IsChecked = settings.AutoScreenText;
        GameAreaPresets.IsChecked = settings.GameAreaPresets;
        ShowPacks();
        AppearanceChoice.SelectedItem = AppearanceChoice.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Appearance.ToString());
        FrameSourceChoice.SelectedItem = FrameSourceChoice.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.FrameSource.ToString());
        RemotePlayAppChoice.SelectedItem = RemotePlayAppChoice.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.RemotePlayApp.ToString());
        XboxAudioOnComputer.IsChecked = settings.XboxAudioOnComputer;
        XboxLegacyFrameRate.IsChecked = settings.XboxLegacyFrameRate;
        PlayStationPictureSourceCard.Visibility = controller.IsXbox ? Visibility.Collapsed : Visibility.Visible;
        XboxPictureSourceCard.Visibility = controller.IsXbox ? Visibility.Visible : Visibility.Collapsed;
        ShowFrameSource();
        PasscodeTab.Visibility = controller.IsXbox ? Visibility.Collapsed : Visibility.Visible;
        ShowPasscode();
        BuildShortcuts();
        ShowShortcutTexts();
        PreviewKeyDown += OnShortcutKey;
        Closed += (_, _) => StopRecording();
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
        if (controller.IsXbox) return;
        var window = controller.Settings.FrameSource == FrameSource.RemotePlayWindow;
        var capture = controller.Settings.FrameSource == FrameSource.CaptureWindow;
        RemotePlayAppPanel.Visibility = window ? Visibility.Visible : Visibility.Collapsed;
        WindowSourceHint.Visibility = window ? Visibility.Visible : Visibility.Collapsed;
        CaptureWindowPanel.Visibility = capture ? Visibility.Visible : Visibility.Collapsed;
        if (capture) RefreshCaptureWindows();
        Ps5SourceHint.Visibility = window || capture ? Visibility.Collapsed : Visibility.Visible;
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
    private void OnLinkPs5(object sender, RoutedEventArgs e)
    {
        controller.LinkPs5Account();
        Close();
    }

    private void OnFrameSource(object sender, SelectionChangedEventArgs e)
    {
        if (FrameSourceChoice.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        Update(s => s with { FrameSource = Enum.Parse<FrameSource>(tag) });
        ShowFrameSource();
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
            CaptureWindowEmpty.Visibility = windows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        finally { refreshingCaptureWindows = false; }
    }

    private void OnRefreshCaptureWindows(object sender, RoutedEventArgs e) => RefreshCaptureWindows();

    private void OnCaptureWindowChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || refreshingCaptureWindows) return;
        if (CaptureWindowChoice.SelectedItem is ComboBoxItem { Tag: WindowCaptureTarget target })
            Update(s => s with { CaptureWindow = target });
    }

    private void OnAppearance(object sender, SelectionChangedEventArgs e)
    {
        if (AppearanceChoice.SelectedItem is ComboBoxItem { Tag: string tag })
            Update(s => s with { Appearance = Enum.Parse<AppAppearance>(tag) });
    }

    private void OnControllerChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
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
            or nameof(AppController.AreaProfileTarget))
            ShowAreaProfile();
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
        AreaProfileSave.Content = active is not null ? text["Save to profile"] : target is not null ? text.Format("Save for %@", target) : "";
        AreaProfileSave.Visibility = target is not null && (active is null || unsaved) ? Visibility.Visible : Visibility.Collapsed;
        AreaProfileDelete.Visibility = active is not null ? Visibility.Visible : Visibility.Collapsed;
        AreaProfileButtons.Visibility = AreaProfileSave.Visibility == Visibility.Visible || active is not null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnSaveAreaProfile(object sender, RoutedEventArgs e) => controller.SaveAreaProfile();

    private void OnDeleteAreaProfile(object sender, RoutedEventArgs e)
    {
        if (controller.AreaProfileGame is not { } game) return;
        var text = Localizer.Current;
        if (MessageBox.Show(this, text.Format("Delete the saved areas for %@?", game), text["Delete profile"], MessageBoxButton.YesNo,
                            MessageBoxImage.Question) == MessageBoxResult.Yes)
            controller.DeleteAreaProfile();
    }

    private async void OnOpenTvPairing(object sender, RoutedEventArgs e)
    {
        try { await controller.OpenTvPairingAsync(); }
        catch (Exception error) { MessageBox.Show(this, error.Message, "CouchSubs"); }
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
        StyleCard.Title = Localizer.Current[controller.Settings.Output == SubtitleOutput.Tv ? "On the TV" : "Subtitle appearance"];
        // Görüntü modu yalnız Android TV uygulamasında var.
        DisplayModePanel.Visibility = controller.ShowsOnTv && controller.Tv?.Brand == TvBrand.AndroidTv
            ? Visibility.Visible : Visibility.Collapsed;
        // Yer ayarları TV içindir; bilgisayar ekranında "ekrandaki konum ayarı işlemiyor" sanılıyordu (Genzo, 2026-11-13).
        TvPlacementPanel.Visibility = controller.ShowsOnTv ? Visibility.Visible : Visibility.Collapsed;
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
        var packs = controller.InstalledPacks;
        PacksPill.Visibility = packs.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        PacksPillText.Text = text.Format("Free · %lld games", packs.Count);
        if (packs.Count == 0)
        {
            PackList.Items.Add(new TextBlock
            {
                Text = text["No game pack is installed."], Style = (Style)FindResource("HintText"), TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(8),
            });
            return;
        }
        foreach (var pack in packs) PackList.Items.Add(PackTile(pack, text.Format("%@ lines", pack.Entries.ToString("N0"))));
    }

    /// <summary>Square, user-selected cover art when available; otherwise the existing three-letter badge.</summary>
    private FrameworkElement PackTile(GamePackLibrary.Info pack, string lines)
    {
        var text = Localizer.Current;
        var badge = new Border { Style = (Style)FindResource("GameMonogram") };
        var coverPath = GameCoverStore.PathFor(pack.Id);
        if (coverPath is not null && File.Exists(coverPath))
        {
            try
            {
                // OnLoad releases the file before the image is displayed, so replacing a cover works immediately.
                using var stream = File.OpenRead(coverPath);
                var cover = new BitmapImage();
                cover.BeginInit();
                cover.CacheOption = BitmapCacheOption.OnLoad;
                cover.DecodePixelWidth = 128;
                cover.StreamSource = stream;
                cover.EndInit();
                cover.Freeze();
                badge.Child = new Image
                {
                    Source = cover, Width = 52, Height = 52, Stretch = Stretch.UniformToFill,
                    Clip = new RectangleGeometry(new Rect(0, 0, 52, 52), 8, 8),
                };
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or FormatException or NotSupportedException)
            {
                // A corrupted optional cover must never hide the pack or prevent opening Settings.
            }
        }
        if (badge.Child is null)
        {
            var initials = new TextBlock
            {
                Text = Initials(pack.Title), FontWeight = FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.NoWrap,
            };
            initials.SetResourceReference(TextBlock.FontSizeProperty, "captionFontSize");
            badge.Child = initials;
        }

        // Local artwork is chosen by the user, never downloaded automatically or bundled in the public repository.
        var coverButton = new Button
        {
            Style = (Style)FindResource("IconButton"), Width = 52, Height = 52, Padding = new Thickness(0),
            BorderThickness = new Thickness(0), Background = Brushes.Transparent,
            Content = badge, Margin = new Thickness(0, 0, 16, 0), ToolTip = CoverText("Choose game cover…", "Oyun kapağı seç…"),
        };
        System.Windows.Automation.AutomationProperties.SetName(coverButton,
            CoverText("Choose game cover…", "Oyun kapağı seç…") + " " + pack.Title);
        coverButton.Click += (_, _) => ChoosePackCover(pack.Id);
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
                MessageBox.Show(this, CoverText("The game cover could not be saved.", "Oyun kapağı kaydedilemedi."), text["Game packs"],
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
        coverButton.ContextMenu = new ContextMenu { Items = { choose, remove } };

        var name = new TextBlock { Text = pack.Title, Style = (Style)FindResource("HeadlineText") };
        var count = new TextBlock { Text = lines, Style = (Style)FindResource("CaptionText"),
            Margin = new Thickness(0, 4, 0, 0) };
        var row = new DockPanel();
        DockPanel.SetDock(coverButton, Dock.Left);
        row.Children.Add(coverButton);
        row.Children.Add(new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { name, count } });
        return new Controls.Card { Content = row, Margin = new Thickness(8) };
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
        if (picker.ShowDialog(this) != true) return;
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
            MessageBox.Show(this, CoverText("The game cover could not be saved.", "Oyun kapağı kaydedilemedi."), text["Game packs"],
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    // Cover-picker labels are Windows-only; avoid changing the shared Mac/iOS localization catalog.
    private static string CoverText(string english, string turkish) =>
        Localizer.Current.Language == "tr" ? turkish : english;

    /// <summary>"Grand Theft Auto V" → "GTA": ilk üç sözcüğün baş harfleri (rakam olduğu gibi).</summary>
    internal static string Initials(string title)
    {
        var words = title.Split([' ', ':', '-', '(', ')'], StringSplitOptions.RemoveEmptyEntries);
        var letters = words.Where(word => char.IsLetterOrDigit(word[0])).Take(3).Select(word => char.ToUpperInvariant(word[0]));
        return string.Concat(letters);
    }

    private async void OnImportPack(object sender, RoutedEventArgs e)
    {
        var text = Localizer.Current;
        var picker = new OpenFileDialog
        {
            Title = text["Import game pack"],
            Filter = $"{text["Translation files"]} (*.json, *.txt, *.srt)|*.json;*.txt;*.srt",
        };
        if (picker.ShowDialog(this) != true) return;

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
        catch (InvalidDataException)
        {
            if (IsLoaded)
                MessageBox.Show(this, text["The translation file could not be imported. Check its format and encoding."],
                    picker.Title, MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            if (IsLoaded)
                MessageBox.Show(this, text["The translation file could not be read."], picker.Title,
                    MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }
        finally
        {
            ImportPack.IsEnabled = true;
        }

        if (IsLoaded && new GamePackImportWindow(preview, sourcePath) { Owner = this }.ShowDialog() == true)
            controller.ReloadGamePacks();
    }

    private void OnGamePacks(object sender, RoutedEventArgs e) => Update(s => s with { GamePacks = GamePacks.IsChecked == true });

    private void OnSharePool(object sender, RoutedEventArgs e) => Update(s => s with { SharePool = SharePool.IsChecked == true });

    private void OnAskGame(object sender, RoutedEventArgs e) => Update(s => s with { AskGame = AskGame.IsChecked == true });

    private void OnSpeakerNames(object sender, RoutedEventArgs e) => Update(s => s with { ShowSpeakerNames = SpeakerNames.IsChecked == true });

    private void OnSpeakerColors(object sender, RoutedEventArgs e) => Update(s => s with { SpeakerColors = SpeakerColors.IsChecked == true });

    private void OnAutoScreenText(object sender, RoutedEventArgs e) => Update(s => s with { AutoScreenText = AutoScreenText.IsChecked == true });

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

    private void ShowEngine()
    {
        var text = Localizer.Current;
        var engine = SelectedEngine;
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
        ShowStatus(check.State switch
        {
            OnlineKeyState.Valid => text.Format("This month: %1$@ of %2$@ characters used.", check.Used.ToString("N0"), check.Limit.ToString("N0")),
            OnlineKeyState.QuotaExceeded => text["This month's DeepL limit is used up. Until it renews, the translation model on this computer translates."],
            OnlineKeyState.Invalid => text["DeepL did not accept this key. Copy it again from your DeepL account page."],
            _ => text["DeepL could not be reached. Check your internet connection."],
        }, check.State is not (OnlineKeyState.Valid or OnlineKeyState.QuotaExceeded));
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

    private void OnWatchSubtitleBackground(object sender, RoutedEventArgs e) =>
        Update(s => s with { WatchSubtitleBackground = WatchSubtitleBackground.IsChecked == true });

    private void OnAutoReadGamePhone(object sender, RoutedEventArgs e) =>
        Update(s => s with { AutoReadGamePhone = AutoReadGamePhone.IsChecked == true });

    private async void OnKeySave(object sender, RoutedEventArgs e)
    {
        var engine = SelectedEngine;
        KeySave.IsEnabled = false;
        try
        {
            if (engine == TranslationEngine.Local)
            {
                CommitLocal();
                KeySave.IsEnabled = false;
                KeySave.Content = Localizer.Current["Testing…"];
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
            if (engine == TranslationEngine.Local) KeySave.Content = Localizer.Current["Test connection"];
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

    public static void Open(Window? owner, AppController controller) =>
        OwnedWindow.Show(owner, () => new SettingsWindow(controller));

    /// <summary>Ayarları belli bir bölümde açar (ana ekrandaki bilgi karosunun "Çeviri" satırı).</summary>
    public static void Open(Window? owner, AppController controller, SettingsSection section)
    {
        var window = OwnedWindow.Show(owner, () => new SettingsWindow(controller));
        window.Sections.SelectedItem = section switch
        {
            SettingsSection.Translation => window.TranslationSection,
            SettingsSection.PictureSource => window.PictureSourceSection,
            _ => window.Sections.SelectedItem,
        };
    }

    private void Update(Func<UserSettings, UserSettings> change)
    {
        if (!loading) controller.Settings = change(controller.Settings);
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
        var slot = area;
        Update(s => slot == 0 ? s with { Region = region, AreaPreset = AreaPresets.Matching(region) } : s.WithExtraRegion(slot, region));
        if (slot == 0) ShowPreset();
        // Kapalı ek bölgeyi çizmek onu açar: eskiden çerçeve "Bu alanı kullan" işaretlenene dek kilitliydi, ipucu "alanı çiz"
        // derken sürükleme hiçbir şey yapmıyordu ve bölgenin yeri değiştirilemiyor sanılıyordu.
        else if (UseArea.IsChecked != true)
        {
            var wasLoading = loading;
            loading = true;
            UseArea.IsChecked = true;
            loading = wasLoading;
        }
    }

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
        if (!loading && sender is RadioButton { Tag: string tag }) ShowArea(int.Parse(tag));
    }

    /// <summary>Seçilen bölgenin çerçevesini gösterir; ek bölge kapalıysa çerçeve düzenlenemez.</summary>
    private void ShowArea(int slot)
    {
        area = slot;
        var wasLoading = loading;
        loading = true;
        var settings = controller.Settings;
        if (slot == 0)
        {
            UseArea.Visibility = Visibility.Collapsed;
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
            var extra = settings.ExtraRegion(slot);
            UseArea.Visibility = Visibility.Visible;
            UseArea.IsChecked = extra is not null;
            PresetPanel.Visibility = Visibility.Collapsed;
            ExtraTargetPanel.Visibility = Visibility.Visible;
            ExtraLivePanel.Visibility = Visibility.Visible;
            ExtraLive.IsChecked = settings.ExtraLive(slot);
            ShowExtraFullScreenHint(settings);
            (settings.ExtraTarget(slot) switch { ResultTarget.Pc => ExtraPc, ResultTarget.Both => ExtraBoth, _ => ExtraTv }).IsChecked = true;
            // Kapalı ek bölge de çizilebilir; çizince açılır (bkz. OnRegion).
            Region.IsEnabled = true;
            Region.DefaultRegion = ExtraDefaults[slot - 1];
            Region.Centered = false;
            Region.ShowRegion(extra ?? ExtraDefaults[slot - 1]);
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
        if (loading || area == 0 || sender is not RadioButton { Tag: string tag }) return;
        var slot = area;
        var target = Enum.Parse<ResultTarget>(tag);
        Update(s => s.WithExtraTarget(slot, target));
    }

    private void OnUseArea(object sender, RoutedEventArgs e)
    {
        if (loading || area == 0) return;
        var on = UseArea.IsChecked == true;
        var slot = area;
        var region = Region.Region;
        Update(s => s.WithExtraRegion(slot, on ? region : null));
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
        if (loading || area == 0) return;
        var slot = area;
        var live = ExtraLive.IsChecked == true;
        Update(s => s.WithExtraLive(slot, live));
    }

    /// <summary>Hazır köşe seçimi: bölge açılır ve çerçeve o köşeye gelir.</summary>
    private void OnExtraPreset(object sender, RoutedEventArgs e)
    {
        if (loading || area == 0 || sender is not Button { Tag: string tag }) return;
        var slot = area;
        var region = Enum.Parse<ExtraAreaPreset>(tag).Region();
        loading = true;
        UseArea.IsChecked = true;
        loading = false;
        Region.ShowRegion(region);
        Update(s => s.WithExtraRegion(slot, region));
    }

    private void OnTest(object sender, RoutedEventArgs e) => controller.SendTestSubtitle();

    private void OnAbout(object sender, RoutedEventArgs e) => AboutWindow.Open(this);

    private void OnReset(object sender, RoutedEventArgs e)
    {
        var text = Localizer.Current;
        var answer = MessageBox.Show(this, text["The saved PS5, account and TV connection will be removed."], text["Set up again?"],
            MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.OK) return;
        controller.ResetSetup();
        Close();
    }

    private void OnDone(object sender, RoutedEventArgs e) => Close();

    private void OnObsCopy(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(ObsAddress.Text);
            ObsCopy.Content = Localizer.Current["Copied"];
        }
        catch (System.Runtime.InteropServices.COMException) { }
    }

    private void OnNetworkObsCopy(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(NetworkObsAddress.Text);
            NetworkObsCopy.Content = Localizer.Current["Copied"];
        }
        catch (System.Runtime.InteropServices.COMException) { }
    }

    private void OnStreamBackground(object sender, SelectionChangedEventArgs e)
    {
        if (StreamBackgroundChoice.SelectedItem is ComboBoxItem { Tag: string tag } && Enum.TryParse<StreamBackground>(tag, out var background))
            controller.StreamBackground = background;
    }

    private void OnOpenStreamWindow(object sender, RoutedEventArgs e) => StreamWindow.Open(controller);

    /// <summary>Ek bölgenin ipucu, o bölgenin kısayoluyla.</summary>
    private void ShowAreaHint()
    {
        if (area == 0) return;
        var action = area switch { 1 => HotkeyAction.ExtraRegion1, 2 => HotkeyAction.ExtraRegion2, _ => HotkeyAction.ExtraRegion3 };
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
                Margin = new Thickness(0, 0, 16, 8),
            };
            Grid.SetRow(name, row);
            ShortcutGrid.Children.Add(name);
            for (var slot = 0; slot < HotkeyTable.SlotCount; slot++)
            {
                var button = new Button { MinWidth = 160, Margin = new Thickness(slot == 0 ? 0 : 8, 0, 0, 8), Tag = (action, slot) };
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
        var busy = key is not null && !GlobalHotkeys.IsAvailable(new WindowInteropHelper(this).Handle, key);
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
