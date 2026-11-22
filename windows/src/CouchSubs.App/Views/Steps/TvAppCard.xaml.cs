// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

/// <summary>TV uygulamasını geliştirici moduyla kurma adımları (LG, Samsung, Android TV). Yapılacak bir şey yoksa görünmez.</summary>
public partial class TvAppCard : UserControl
{
    // Kullanıcı TV'de geliştirici modunu açınca kendiliğinden devam eder.
    private readonly DispatcherTimer devModeWatch = new() { Interval = TimeSpan.FromSeconds(3) };
    private AppController? controller;

    public TvAppCard()
    {
        InitializeComponent();
        devModeWatch.Tick += async (_, _) =>
        {
            if (controller is not null) await controller.RefreshTvAppAsync();
        };
        Loaded += (_, _) =>
        {
            controller = DataContext as AppController;
            if (controller is null) return;
            controller.PropertyChanged += OnChanged;
            System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged += OnNetworkChanged;
            Show(controller.TvApp);
        };
        Unloaded += (_, _) =>
        {
            devModeWatch.Stop();
            System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
            if (controller is not null) controller.PropertyChanged -= OnChanged;
        };
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        // Tv: TV adresi değişince Samsung adımındaki "Host PC IP" de yeniden seçilir.
        if (e.PropertyName is nameof(AppController.TvApp) or nameof(AppController.DevModeHoursLeft) or nameof(AppController.Tv)
            or nameof(AppController.CanReinstallTvApp))
            Dispatcher.Invoke(() => Show(controller!.TvApp));
    }

    /// <summary>Wi-Fi değişti, VPN açıldı/kapandı: gösterilen "Host PC IP" eski adreste kalmasın.</summary>
    private void OnNetworkChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(() =>
    {
        if (controller is not null) Show(controller.TvApp);
    });

    private static Visibility Visible(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;

    private void Show(TvAppState state)
    {
        var text = Localizer.Current;
        var brand = controller?.Tv?.Brand ?? TvBrand.Lg;
        var devModeOff = state.Kind == TvAppKind.DevModeOff;
        Visibility = Visible(state.Kind != TvAppKind.Unknown);
        LgSteps.Visibility = Visible(devModeOff && brand == TvBrand.Lg);
        // TV bu bilgisayarı kabul etmediyse de adımlar (Host PC IP satırı bu bilgisayarın adresiyle) görünür (#343).
        var hostPcProblem = state.Kind == TvAppKind.Failed && state.Error is DevModeError.Unreachable or DevModeError.HostPcMismatch;
        SamsungSteps.Visibility = Visible((devModeOff || hostPcProblem) && brand == TvBrand.Samsung);
        AndroidSteps.Visibility = Visible(devModeOff && brand == TvBrand.AndroidTv);
        AndroidChoice.Visibility = Visible(state.Kind == TvAppKind.ChooseAndroidTv);
        AndroidHosts.Children.Clear();
        var choices = state.Kind == TvAppKind.ChooseAndroidTv && state.Hosts is { } found ? found : Array.Empty<string>();
        foreach (var host in choices)
        {
            var choose = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(0, 4, 0, 0),
                Content = text["Install on the TV at %@"].Replace("%@", host),
            };
            choose.Click += async (_, _) =>
            {
                if (controller is not null) await controller.ChooseAndroidTvAsync(host);
            };
            AndroidHosts.Children.Add(choose);
        }
        // Parola alanı LG'nin geliştirici modu adımlarında da görünür: CouchSubs geliştirici modunu göremese de TV'de Key
        // Server ve parola açıksa kullanıcı takılmaz (#94). Anahtar ancak "TV'ye kur"a basılınca istenir.
        PassphraseArea.Visibility = Visible(state.Kind == TvAppKind.NeedsPassphrase || (devModeOff && brand == TvBrand.Lg));
        OpenAgain.Visibility = Visible(state.Kind == TvAppKind.SignIn);
        if (state.Kind != TvAppKind.SignIn) CopyLink.Content = text["Copy the link"];
        Retry.Visibility = Visible(state.Kind == TvAppKind.Failed);
        // Hata varken (LG'nin parola adımındaki hata dahil) günlük gösterilip kopyalanabilir.
        LogActions.Visibility = Visible(state.Error is not null);
        if (state.Error is null) CopyLog.Content = text["Copy the log"];
        // Uygulama "hazır" görünüp TV'de yoksa ya da açılmıyorsa (TV uygulaması bağlı değil) yeniden kurulabilir.
        Reinstall.Visibility = Visible(state.Kind == TvAppKind.UpToDate && controller?.CanReinstallTvApp == true);
        SamsungHostStep.Text = text["3. Turn Developer mode On, type this computer's address as Host PC IP: %@ and press OK."]
            .Replace("%@", controller?.ComputerAddress ?? "?");
        // Wi-Fi ve Ethernet ikisi de bağlıysa ya da birden çok ağ varsa diğer adresler de yazılır.
        if (brand == TvBrand.Samsung && controller?.OtherComputerAddresses is { Length: > 0 } others)
            SamsungHostStep.Text += "\n" + text.Format(TvAppMessages.OtherAddressesLine, string.Join(", ", others));

        Status.Text = state.Kind switch
        {
            TvAppKind.Working => text["Installing the TV app…"],
            TvAppKind.UpToDate => string.Format(text["The TV app is ready (version %@)."].Replace("%@", "{0}"), state.Version),
            TvAppKind.DevModeOff => brand switch
            {
                TvBrand.Lg => text["The TV app is not installed. CouchSubs can install it once Developer Mode is on."],
                TvBrand.Samsung => text["The TV app is not installed. CouchSubs installs it once Developer Mode is on."],
                _ => text["The TV app is not installed. CouchSubs installs it over the network once debugging is on."],
            },
            TvAppKind.NeedsPassphrase => text["Developer Mode is on. One last step to install the TV app:"],
            TvAppKind.SignIn => text["The Samsung account page opened in your browser. Finish signing in there. If you do not see it, switch to the browser or press Open the page again."],
            TvAppKind.ApproveOnTv => text["Look at the TV: it asks whether to allow debugging from this computer."],
            TvAppKind.PressInstallOnTv => text["The Google Play page opened on the TV: press Install (or Update) with the TV remote. The app opens by itself once it is installed."],
            TvAppKind.ChooseAndroidTv => text["More than one Android TV with debugging on was found on the network. Which one is yours?"],
            _ => "",
        };
        Detail.Text = state.Kind switch
        {
            TvAppKind.SignIn => text["Samsung signs the app for your TV with your free Samsung account."] + " " +
                                text["No account? You can create a free one on the same page. If the browser asks to allow access to devices on your network, allow it."],
            TvAppKind.ApproveOnTv => text["Tick “Always allow from this computer” and choose Allow. The app then installs by itself."],
            TvAppKind.UpToDate when brand == TvBrand.Lg => controller?.DevModeHoursLeft is { } hours
                ? text["Developer Mode: %lld hours left. CouchSubs extends it by itself each time you use it."].Replace("%lld", hours.ToString())
                : text["CouchSubs extends Developer Mode by itself each time you use it."],
            TvAppKind.UpToDate when brand == TvBrand.Samsung => text[TvAppMessages.SourceSwitchTip],
            _ => "",
        };
        Detail.Visibility = Visible(Detail.Text.Length > 0);
        Problem.Text = TvAppMessages.Problem(state, brand, text, Services.LiveServices.TvInstallLogPath, controller?.ComputerAddress);
        // Host PC IP düzeltilip TV yeniden başlayınca da kendiliğinden devam eder.
        if (devModeOff || (brand == TvBrand.Samsung && state.Error == DevModeError.HostPcMismatch)) devModeWatch.Start();
        else devModeWatch.Stop();
        if (state.Error == DevModeError.ForeignApp) Dispatcher.BeginInvoke(() => AskToReplaceForeign(state));
    }

    /// <summary>Son sorulan ForeignApp durumu: kart her yenilendiğinde (ve iki kart birden açıksa) pencere bir kez çıkar.</summary>
    private static TvAppState? askedForeign;

    /// <summary>
    /// TV'de CouchSubs'ın kimliğiyle başka uygulama var: kaldırıp CouchSubs'ı kurmak için onay ister. "Vazgeç"te hiçbir şey
    /// silinmez; kartta aynı metin ve "Yeniden dene" kalır.
    /// </summary>
    private async void AskToReplaceForeign(TvAppState state)
    {
        if (ReferenceEquals(askedForeign, state) || controller is null || !ReferenceEquals(controller.TvApp, state)) return;
        askedForeign = state;
        var text = Localizer.Current;
        var replace = false;
        var dialog = new Window
        {
            Title = text[TvAppMessages.ForeignAppTitle],
            Owner = Window.GetWindow(this),
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            SizeToContent = SizeToContent.WidthAndHeight,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
        };
        var confirm = new Button { Content = text[TvAppMessages.ForeignAppConfirm], IsDefault = true, Style = TryFindResource("PrimaryButton") as Style };
        var cancel = new Button { Content = text[TvAppMessages.ForeignAppCancel], IsCancel = true, Margin = new Thickness(8, 0, 0, 0) };
        confirm.Click += (_, _) => { replace = true; dialog.Close(); };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        buttons.Children.Add(confirm);
        buttons.Children.Add(cancel);
        var body = new StackPanel { Margin = new Thickness(20), MaxWidth = 420 };
        body.Children.Add(new TextBlock { Text = text[TvAppMessages.ForeignAppMessage], TextWrapping = TextWrapping.Wrap });
        body.Children.Add(buttons);
        dialog.Content = body;
        dialog.SetResourceReference(Control.BackgroundProperty, "windowBackgroundBrush");
        dialog.SetResourceReference(Control.ForegroundProperty, "textPrimaryBrush");
        dialog.ShowDialog();
        if (replace && controller is not null) await controller.ReplaceForeignTvAppAsync();
    }

    private async void OnInstall(object sender, RoutedEventArgs e)
    {
        if (controller is not null && !string.IsNullOrWhiteSpace(Passphrase.Text))
            await controller.InstallTvAppAsync(Passphrase.Text);
    }

    private async void OnRetry(object sender, RoutedEventArgs e)
    {
        if (controller is not null) await controller.RefreshTvAppAsync();
    }

    private async void OnReinstall(object sender, RoutedEventArgs e)
    {
        if (controller is not null) await controller.ReinstallTvAppAsync();
    }

    private void OnOpenAgain(object sender, RoutedEventArgs e)
    {
        if (controller?.TvApp.Url is { } url) controller.OpenInBrowser(url);
    }

    /// <summary>Tarayıcı açılmazsa bağlantı başka bir tarayıcıya yapıştırılabilir.</summary>
    private void OnCopyLink(object sender, RoutedEventArgs e)
    {
        if (controller?.TvApp.Url is not { } url) return;
        try { Clipboard.SetText(url.AbsoluteUri); }
        catch (System.Runtime.InteropServices.COMException) { return; } // pano başka bir uygulamada kilitli
        CopyLink.Content = Localizer.Current["Copied"];
    }

    /// <summary>Kurulum günlüğünü Explorer'da seçili gösterir; dosya henüz yoksa klasörünü açar.</summary>
    private void OnShowLog(object sender, RoutedEventArgs e)
    {
        var path = Services.LiveServices.TvInstallLogPath;
        try
        {
            if (System.IO.File.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
            else Process.Start(new ProcessStartInfo(System.IO.Path.GetDirectoryName(path)!) { UseShellExecute = true });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { }
    }

    /// <summary>Günlüğün sonunu panoya kopyalar (GitHub'a ya da iletiye yapıştırmak için).</summary>
    private void OnCopyLog(object sender, RoutedEventArgs e)
    {
        var log = TvInstall.InstallLog.ReadTail(Services.LiveServices.TvInstallLogPath);
        if (log.Length == 0) return;
        try { Clipboard.SetText(log); }
        catch (System.Runtime.InteropServices.COMException) { return; } // pano başka bir uygulamada kilitli
        CopyLog.Content = Localizer.Current["Copied"];
    }

    private void OnGuide(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("https://github.com/yorulmazsinan/couchsubs/blob/main/docs/tv-kurulum.md#android-tv--google-tv") { UseShellExecute = true });
}
