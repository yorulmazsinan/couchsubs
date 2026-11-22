// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using CouchSubs.App.Controls;
using CouchSubs.App.Services;
using CouchSubs.App.Theme;
using CouchSubs.App.Views;
using CouchSubs.Shell;
using CouchSubs.Core;
using Microsoft.Win32;

namespace CouchSubs.App;

/// <summary>Üst çubuktaki sekmeler (Profil sayfası yok; her şey Ayarlar'da).</summary>
public enum ShellTab { Home, History, Settings }

/// <summary>
/// Uygulamanın tek penceresi: kurulum bitmediyse sihirbaz; bittiyse üst çubuk (logo, Ana Ekran / Geçmiş / Ayarlar,
/// durum hapı), seçili sayfa ve reklam bandı. Eskiden Ayarlar ve Geçmiş ayrı pencerede açılıyordu.
/// </summary>
public partial class ShellWindow : Window
{
    private readonly AppController controller;
    private bool showingMain;
    private GlobalHotkeys? hotkeys;
    private ShellTab tab = ShellTab.Home;
    private MainView? home;
    private bool switching;
    private static ShellWindow? current;

    public ShellWindow(AppController controller)
    {
        this.controller = controller;
        current = this;
        InitializeComponent();
        ApplyMinimumSize();
        SourceInitialized += (_, _) => PaintCaption();
        ThemeManager.Changed += PaintCaption;
        controller.PropertyChanged += OnChanged;
        controller.TvPairingRequested += OnTvPairing;
        // Bilgisayar uykudan uyanınca bağlantılar hemen yenilenir.
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        // Kısayollar (varsayılan Num 0, 1, 2, 3, 5, 7, 8, 9 ve Ctrl+Shift+rakam; Ayarlar › Kısayollar'da değişir) yalnız
        // çeviri sürerken tutulur.
        SourceInitialized += (_, _) =>
        {
            hotkeys = new GlobalHotkeys(new WindowInteropHelper(this).Handle, OnHotkey);
            ApplyHotkeys();
        };
        // Bilgisayarda gösterilecek çeviriler küçük, üstte duran bir kutuda çıkar.
        controller.PcResultReady += PcResultWindow.Display;
        // Bilgisayar ekranındaki altyazı penceresi (altyazı yokken gizli). Kurulamazsa uygulama onsuz açılır.
        SubtitleOverlayWindow? overlay = null;
        try
        {
            overlay = SubtitleOverlayWindow.Attach(controller);
        }
        catch (Exception error)
        {
            StartupGuard.Log("Altyazı penceresi kurulamadı", error);
            StartupGuard.Show(Application.Current, StartupGuard.OverlayFailedMessage(error));
        }
        // Sistem tepsisi simgesi ve açılır penceresi (Mac'teki menü çubuğunun karşılığı).
        var tray = TrayPopup.Attach(controller);
        Closed += (_, _) =>
        {
            tray?.Detach();
            ThemeManager.Changed -= PaintCaption;
            if (current == this) current = null;
            controller.PcResultReady -= PcResultWindow.Display;
            overlay?.Detach();
            hotkeys?.Dispose();
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            controller.TvPairingRequested -= OnTvPairing;
            controller.Dispose();
        };
        ShowScreen(force: true);
    }

    private bool pairingShown;

    /// <summary>
    /// "Bu TV eşleşsin mi?" penceresi. Pencere açıkken gelen yeni istek (TV'de Tamam ile yeniden denendi, TV uygulaması
    /// yeniden açıldı) ikinci pencere açmaz; pencere kapanınca bekleyen istek yeni koduyla gösterilir. Eskiden eski koddan
    /// verilen onay "süresi doldu" deyip bitiyordu, TV'nin bekleyen yeni isteği bilgisayarda hiç görünmüyordu (Mac ile aynı).
    /// </summary>
    private void OnTvPairing(SubtitlePairing.Ticket ticket)
    {
        // Kurulumun TV adımında kod kartta onaylanır; açılır kart ayrıca sorulmaz.
        if (pairingShown || Views.Steps.TvCodeCard.Showing) return;
        pairingShown = true;
        try
        {
            var text = Localizer.Current;
            for (var current = ticket; ;)
            {
                var message = text.Format("TV code: %@. You don't type this code anywhere: if your TV shows the same code, approve it here.", current.Code);
                // Açılır kart: kod iki ekranda; onay amber ana eylem.
                var approved = DesignDialog.Confirm(this, text["Pair this TV?"], message, text["I See This Code on the TV"], text["Cancel"]);
                var resolved = controller.ResolveTvPairing(current.Id, approved);
                if (controller.PendingTvPairing is { } next && next.Id != current.Id) { current = next; continue; }
                if (!resolved && approved)
                    MessageBox.Show(this, text["The pairing request expired. Try again on the TV."], "CouchSubs");
                break;
            }
        }
        finally { pairingShown = false; }
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.Step) or nameof(AppController.DemoMode))
        {
            // Ana ekrandan kuruluma dönülünce (TV Bağla, Yeniden Kur) erteleme biter, sihirbaz açılır.
            if (e.PropertyName is nameof(AppController.Step) && setupDeferred && controller.Step != OnboardingStep.Done) setupDeferred = false;
            ShowScreen();
        }
        if (e.PropertyName is nameof(AppController.IsRunning) or nameof(AppController.IsStarting) or nameof(AppController.DemoMode)
            or nameof(AppController.Step) or nameof(AppController.Ps5Tone) or nameof(AppController.TvTone) or nameof(AppController.SessionState)
            or nameof(AppController.Settings))
            ShowStatus();
        if (e.PropertyName is nameof(AppController.Settings)) Motion.AnimationsEnabled = controller.Settings.TransitionAnimations;
        if (e.PropertyName is nameof(AppController.IsRunning) && !controller.IsRunning && showingMain)
            PopupAdWindow.Offer(this, controller, PopupAdMoment.TranslationStopped);
        if (e.PropertyName is nameof(AppController.IsRunning) or nameof(AppController.HotkeysPaused) or nameof(AppController.Settings))
            ApplyHotkeys();
    }

    /// <summary>Kısayol tablosu ayarlardan gelir; Ayarlar'da yeni tuş beklenirken kısayollar bırakılır.</summary>
    private void ApplyHotkeys()
    {
        if (hotkeys is null) return;
        hotkeys.Bindings = HotkeyTable.Resolve(controller.Settings.Hotkeys);
        hotkeys.Enabled = controller.IsRunning && !controller.HotkeysPaused;
    }

    private void OnHotkey(HotkeyAction action)
    {
        switch (action)
        {
            case HotkeyAction.ExtraRegion1: _ = controller.TranslateExtraRegionAsync(1); break;
            case HotkeyAction.ExtraRegion2: _ = controller.TranslateExtraRegionAsync(2); break;
            case HotkeyAction.ExtraRegion3: _ = controller.TranslateExtraRegionAsync(3); break;
            case HotkeyAction.PauseSubtitles: controller.ToggleSubtitles(); break;
            case HotkeyAction.Snapshot: controller.RequestSnapshot(); break;
            case HotkeyAction.FreeArea: FreeAreaWindow.Open(controller); break;
            case HotkeyAction.Screen: _ = controller.TranslateScreenAsync(); break;
            case HotkeyAction.ClickThrough: controller.ToggleClickThrough(); break;
        }
    }

    private void ShowScreen(bool force = false)
    {
        // Deneme modunda kurulum bitmemiş olsa da ana ekran gösterilir; çıkınca kalınan adıma dönülür.
        var main = controller.Step == OnboardingStep.Done || controller.DemoMode || setupDeferred;
        ShowStatus();
        if (!force && main == showingMain) return;
        showingMain = main;
        // Kurulumda üst çubuk ve reklam bandı yok (sihirbazın kendi çubuğu var).
        TopBar.Visibility = main ? Visibility.Visible : Visibility.Collapsed;
        Ads.Visibility = main && AdCatalog.Banners.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        home?.Detach();
        if (!main)
        {
            home = null;
            Show(new OnboardingView(controller));
            return;
        }
        home = new MainView(controller);
        // Açılır reklam: yalnız açılışta ya da çeviri durunca, günde en fazla bir kez (PopupAdPolicy).
        Dispatcher.BeginInvoke(() => PopupAdWindow.Offer(this, controller, PopupAdMoment.AppLaunch), System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        tab = ShellTab.Home;
        Show(home);
        SelectTab(ShellTab.Home, null);
    }

    /// <summary>Kurulum "Sonra Ayarlarım" ile bırakıldı (bu oturumda): ana ekran "Kurulum Eksik" durumuyla gösterilir.</summary>
    private bool setupDeferred;

    /// <summary>Kurulum sihirbazındaki "Sonra Ayarlarım".</summary>
    public static void DeferSetup()
    {
        if (current is not { } window) return;
        window.setupDeferred = true;
        window.ShowScreen();
    }

    /// <summary>Başka bir yerden sekme açar (ana ekrandaki "Ayarlar › Çeviri" satırı, menüler, kısayollar).</summary>
    public static void Navigate(ShellTab tab, SettingsSection? section = null)
    {
        if (current is not { } window) return;
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
        if (window.showingMain) window.SelectTab(tab, section);
    }

    private void OnTab(object sender, RoutedEventArgs e)
    {
        if (switching || !showingMain) return;
        var chosen = sender == HistoryTab ? ShellTab.History : sender == SettingsTab ? ShellTab.Settings : ShellTab.Home;
        SelectTab(chosen, null);
    }

    /// <summary>
    /// Sekmeyi açar. Ana ekran bir kez kurulur ve saklanır (canlı altyazı, oyun durumu kaybolmasın); Geçmiş ve Ayarlar her
    /// açılışta yeniden kurulur (eskiden pencere her açıldığında olduğu gibi güncel ayarlarla).
    /// </summary>
    private void SelectTab(ShellTab chosen, SettingsSection? section)
    {
        switching = true;
        (chosen switch { ShellTab.History => HistoryTab, ShellTab.Settings => SettingsTab, _ => HomeTab }).IsChecked = true;
        switching = false;
        if (chosen == tab && Host.Content is FrameworkElement shown && shown is not OnboardingView)
        {
            if (section is { } wanted && shown is SettingsView open) open.Show(wanted);
            return;
        }
        tab = chosen;
        switch (chosen)
        {
            case ShellTab.History:
                Show(new HistoryView(controller));
                break;
            case ShellTab.Settings:
                var settings = new SettingsView(controller);
                Show(settings);
                settings.Show(section);
                break;
            default:
                Show(home ??= new MainView(controller));
                break;
        }
    }

    /// <summary>Sayfa geçişi: yeni sayfa 8 px aşağıdan kayarak ve solarak gelir (hareket azaltılmışsa yalnız solma).</summary>
    private void Show(FrameworkElement page)
    {
        Host.Content = page;
        Motion.EnterFrom(page, 8, Motion.Page);
    }

    /// <summary>
    /// Durum hapı: çeviri sürüyorsa yeşil "Çeviri Açık"; bağlanırken amber "Bağlanıyor…"; sorun varsa kırmızı "Sorun Var";
    /// kurulum bitmediyse gri "Kurulum Eksik"; deneme modunda amber "Deneme Modu"; yoksa gri "Hazır" (Mac ile aynı).
    /// </summary>
    private void ShowStatus()
    {
        var kind = ShellStatus.For(controller.DemoMode, controller.Step == OnboardingStep.Done, controller.IsRunning, controller.IsStarting,
            controller.Ps5Tone, controller.ShowsOnTv ? controller.TvTone : StatusTone.Good);
        var (tone, key) = kind switch
        {
            ShellStatusKind.Demo => (PillTone.Attention, "Demo Mode"),
            ShellStatusKind.SetupIncomplete => (PillTone.Idle, "Setup Incomplete"),
            ShellStatusKind.NeedsAttention => (PillTone.Live, "Needs Attention"),
            ShellStatusKind.Connecting => (PillTone.Attention, "Connecting…"),
            ShellStatusKind.TranslationOn => (PillTone.Success, "Translation On"),
            _ => (PillTone.Idle, "Ready"),
        };
        Status.Tone = tone;
        Status.Text = Localizer.Current[key];
    }

    /// <summary>
    /// "Günlüğü Kopyala": günlükler maskelenip zip olur, zip panoya DOSYA olarak konur (yapıştırınca dosya gelir); altında
    /// kısa onay ve "Gezgin'de Göster". Sürerken "Kopyalanıyor…" yazar, basılamaz.
    /// </summary>
    private async void OnCopyLog(object sender, RoutedEventArgs e)
    {
        LogCopy.IsEnabled = false;
        LogCopyText.Text = Localizer.Current["Copying…"];
        var zip = await LogArchive.CopyAsync();
        LogCopy.IsEnabled = true;
        LogCopyText.Text = Localizer.Current["Copy Log"];
        LogCopiedOk.Visibility = LogShow.Visibility = zip is null ? Visibility.Collapsed : Visibility.Visible;
        LogCopyFailed.Visibility = zip is null ? Visibility.Visible : Visibility.Collapsed;
        LogCopied.IsOpen = true;
    }

    private void OnShowLog(object sender, RoutedEventArgs e)
    {
        LogCopied.IsOpen = false;
        LogArchive.ShowInExplorer();
    }

    /// <summary>
    /// En küçük boy 1200 × 760 (tasarım). Ekranın çalışma alanı bundan küçükse (1366 × 768 dizüstü) pencere ekrana
    /// sığacak kadar küçülebilir; yoksa pencerenin altı görev çubuğunun arkasında kalırdı.
    /// </summary>
    private void ApplyMinimumSize()
    {
        var work = SystemParameters.WorkArea;
        MinWidth = Math.Min(Palette.Size["windowWidth"], work.Width);
        MinHeight = Math.Min(Palette.Size["windowHeight"], work.Height);
        Width = Math.Max(MinWidth, Math.Min(Palette.Size["windowWidth"], work.Width));
        Height = Math.Max(MinHeight, Math.Min(Palette.Size["windowHeight"], work.Height));
    }

    /// <summary>
    /// Windows 11'de başlık çubuğu pencere zemininin rengini alır (koyu temada koyu başlık); üst çubukla bir bütün görünür.
    /// Eski Windows'ta bu öznitelik yoktur, sistem başlığı kalır.
    /// </summary>
    private void PaintCaption()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        try
        {
            var dark = ThemeManager.IsDark ? 1 : 0;
            DwmSetWindowAttribute(handle, DwmUseImmersiveDarkMode, ref dark, sizeof(int));
            if (TryFindResource("backgroundColor") is Color background)
            {
                var colorRef = background.R | background.G << 8 | background.B << 16;
                DwmSetWindowAttribute(handle, DwmCaptionColor, ref colorRef, sizeof(int));
            }
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException) { }
    }

    private const int DwmUseImmersiveDarkMode = 20;
    private const int DwmCaptionColor = 35;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume) Dispatcher.Invoke(controller.SystemResumed);
    }
}
