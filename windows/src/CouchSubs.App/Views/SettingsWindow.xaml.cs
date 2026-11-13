// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Navigation;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

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

    internal SettingsWindow(AppController controller)
    {
        this.controller = controller;
        InitializeComponent();
        var settings = controller.Settings;
        TextSize.Value = Math.Clamp(settings.Style.FontSize, TextSize.Minimum, TextSize.Maximum);
        TextSizeValue.Text = ((int)TextSize.Value).ToString();
        Position.Value = settings.Style.BottomPercent;
        Placement.SelectedItem = Placement.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Style.Placement.ToString());
        ShowPlacement(settings.Style.Placement);
        BackgroundOpacity.Value = settings.Style.Background;
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
        ObsAddress.Text = $"http://localhost:{controller.ServerPort}/obs";
        ShowArea(0);
        // Num 8: oyunun o anki görüntüsü önizlemeye alınır.
        controller.SnapshotRequested += OnSnapshot;
        Closed += (_, _) => controller.SnapshotRequested -= OnSnapshot;
        Dubbing.Attach(controller);
        OutputCard.Attach(controller);
        ShowStyleTitle();
        controller.PropertyChanged += OnControllerChanged;
        Closed += (_, _) => controller.PropertyChanged -= OnControllerChanged;
        Engine.SelectedItem = Engine.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Engine.ToString());
        ShowEngine();
        GamePacks.IsChecked = settings.GamePacks;
        SharePool.IsChecked = settings.SharePool;
        ShowPacks();
        AppearanceChoice.SelectedItem = AppearanceChoice.Items.Cast<ComboBoxItem>().First(item => (string)item.Tag == settings.Appearance.ToString());
        loading = false;
    }

    private void OnAppearance(object sender, SelectionChangedEventArgs e)
    {
        if (AppearanceChoice.SelectedItem is ComboBoxItem { Tag: string tag })
            Update(s => s with { Appearance = Enum.Parse<AppAppearance>(tag) });
    }

    private void OnControllerChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.Settings) or nameof(AppController.ShowsOnTv) or nameof(AppController.ShowsOnComputer))
            ShowStyleTitle();
        if (e.PropertyName == nameof(AppController.LastFrame)) ShowLiveFrame();
    }

    /// <summary>Alan sekmesi açıkken önizleme oyunun görüntüsüyle saniyede bir yenilenir (çerçeve sürüklenirken beklenir).</summary>
    private void ShowLiveFrame()
    {
        if (!AreaTab.IsSelected || Region.IsDragging || controller.LastFrame is not { } frame) return;
        var now = Environment.TickCount64;
        if (now - lastPreview < 1000) return;
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
        foreach (var pack in packs) PackList.Items.Add(PackTile(pack.Title, text.Format("%@ lines", pack.Entries.ToString("N0"))));
    }

    /// <summary>Bir paketin karosu: adın baş harflerinden rozet, ad ve satır sayısı.</summary>
    private FrameworkElement PackTile(string title, string lines)
    {
        var badge = new Border { Style = (Style)FindResource("GameMonogram"), Margin = new Thickness(0, 0, 16, 0) };
        var initials = new TextBlock
        {
            Text = Initials(title), FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap,
        };
        initials.SetResourceReference(TextBlock.FontSizeProperty, "captionFontSize");
        badge.Child = initials;
        var name = new TextBlock { Text = title, Style = (Style)FindResource("HeadlineText") };
        var count = new TextBlock { Text = lines, Style = (Style)FindResource("CaptionText"), Margin = new Thickness(0, 4, 0, 0) };
        var row = new DockPanel();
        DockPanel.SetDock(badge, Dock.Left);
        row.Children.Add(badge);
        row.Children.Add(new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { name, count } });
        return new Controls.Card { Content = row, Margin = new Thickness(8) };
    }

    /// <summary>"Grand Theft Auto V" → "GTA": ilk üç sözcüğün baş harfleri (rakam olduğu gibi).</summary>
    internal static string Initials(string title)
    {
        var words = title.Split([' ', ':', '-', '(', ')'], StringSplitOptions.RemoveEmptyEntries);
        var letters = words.Where(word => char.IsLetterOrDigit(word[0])).Take(3).Select(word => char.ToUpperInvariant(word[0]));
        return string.Concat(letters);
    }

    private void OnGamePacks(object sender, RoutedEventArgs e) => Update(s => s with { GamePacks = GamePacks.IsChecked == true });

    private void OnSharePool(object sender, RoutedEventArgs e) => Update(s => s with { SharePool = SharePool.IsChecked == true });

    /// <summary>Seçili motor (ayarlarda ücretsiz ise Free).</summary>
    private TranslationEngine SelectedEngine =>
        Engine.SelectedItem is ComboBoxItem { Tag: string tag } ? Enum.Parse<TranslationEngine>(tag) : TranslationEngine.Free;

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
        new SettingsWindow(controller) { Owner = owner }.ShowDialog();

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
        var text = Localizer.Current;
        var settings = controller.Settings;
        if (slot == 0)
        {
            UseArea.Visibility = Visibility.Collapsed;
            ExtraTargetPanel.Visibility = Visibility.Collapsed;
            PresetPanel.Visibility = Visibility.Visible;
            ShowPreset();
            Region.IsEnabled = true;
            Region.DefaultRegion = new CropRegion();
            Region.ShowRegion(settings.Region);
            AreaHint.Text = text["Drag on the picture to draw the area where the game shows its subtitles. Drag the edges to resize it, or the inside to move it."];
        }
        else
        {
            var extra = settings.ExtraRegion(slot);
            UseArea.Visibility = Visibility.Visible;
            UseArea.IsChecked = extra is not null;
            PresetPanel.Visibility = Visibility.Collapsed;
            ExtraTargetPanel.Visibility = Visibility.Visible;
            (settings.ExtraTarget(slot) switch { ResultTarget.Pc => ExtraPc, ResultTarget.Both => ExtraBoth, _ => ExtraTv }).IsChecked = true;
            Region.IsEnabled = extra is not null;
            Region.DefaultRegion = ExtraDefaults[slot - 1];
            Region.ShowRegion(extra ?? ExtraDefaults[slot - 1]);
            AreaHint.Text = text["Draw the area to translate, for example a quest panel. While you play, press its key (Num 1, 2 or 3, or Ctrl+Shift+1, 2 or 3) to read and translate it once. Choose where the result shows. It works even when CouchSubs is in the background."];
        }
        loading = wasLoading;
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
        Region.IsEnabled = on;
        var slot = area;
        var region = Region.Region;
        Update(s => s.WithExtraRegion(slot, on ? region : null));
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
}
