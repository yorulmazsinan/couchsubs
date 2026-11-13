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
        if (e.PropertyName is nameof(AppController.TvApp) or nameof(AppController.DevModeHoursLeft) or nameof(AppController.Tv))
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
        SamsungSteps.Visibility = Visible(devModeOff && brand == TvBrand.Samsung);
        AndroidSteps.Visibility = Visible(devModeOff && brand == TvBrand.AndroidTv);
        PassphraseArea.Visibility = Visible(state.Kind == TvAppKind.NeedsPassphrase);
        OpenAgain.Visibility = Visible(state.Kind == TvAppKind.SignIn);
        if (state.Kind != TvAppKind.SignIn) CopyLink.Content = text["Copy the link"];
        Retry.Visibility = Visible(state.Kind == TvAppKind.Failed);
        SamsungHostStep.Text = text["3. Turn Developer mode On, type this computer's address as Host PC IP: %@ and press OK."]
            .Replace("%@", controller?.ComputerAddress ?? "?");

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
        Problem.Text = TvAppMessages.Problem(state, brand, text, Services.LiveServices.TvInstallLogPath);
        if (devModeOff) devModeWatch.Start();
        else devModeWatch.Stop();
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

    private void OnGuide(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("https://github.com/yorulmazsinan/couchsubs/blob/main/docs/tv-kurulum.md#android-tv--google-tv") { UseShellExecute = true });
}
