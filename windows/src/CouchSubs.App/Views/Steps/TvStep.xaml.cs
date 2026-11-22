// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using CouchSubs.App.Theme;
using System.Windows;
using System.Windows.Controls;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

public partial class TvStep : UserControl
{
    public TvStep()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            ShowDone();
            // Kurulum yarıda kaldıysa (ör. TV uygulaması kurulurken kapatıldı) eşleşmiş TV'deki uygulamaya yeniden bakılır.
            if (Controller.HasTv && Controller.TvApp.Kind == TvAppKind.Unknown) _ = Controller.RefreshTvAppAsync();
            await SearchAsync();
        };
    }

    private AppController Controller => (AppController)DataContext;

    private void ShowDone()
    {
        Done.Text = Controller.Tv?.Name ?? "";
        Done.Visibility = Controller.Tv is null ? Visibility.Collapsed : Visibility.Visible;
        // Uygulamayla TV paketi gelmediyse (geliştirici derlemesi) rehber gösterilir.
        ManualInstall.Visibility = Controller.Tv is null or { Brand: TvBrand.Lg } || Controller.CanInstallTvApp
            ? Visibility.Collapsed : Visibility.Visible;
    }

    private async Task SearchAsync()
    {
        Search.IsEnabled = false;
        Tvs.Children.Clear();
        var found = await Controller.DiscoverTvsAsync();
        foreach (var tv in found) AddRow(tv);
        NotFound.Visibility = found.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Search.IsEnabled = true;
    }

    private void AddRow(LgTv tv)
    {
        var row = new Grid { Margin = Sp.T("0", "xxs", "0", "xxs"), Tag = tv.Host };
        row.Children.Add(new TextBlock { Text = $"{tv.Name} — {tv.Host}", VerticalAlignment = VerticalAlignment.Center });
        var connect = new Button { Content = Localizer.Current["Connect"], Style = (Style)FindResource("PrimaryButton"), HorizontalAlignment = HorizontalAlignment.Right };
        connect.Click += async (_, _) => await PairAsync(tv);
        row.Children.Add(connect);
        Tvs.Children.Add(row);
    }

    /// <summary>Elle yazılan adres: TV'nin türü (LG, Samsung, Android TV) TV'ye sorulur ve listeye eklenir. Android TV'de
    /// "Bağlan" Android TV akışını o adresle başlatır; hiçbir yoklamaya yanıt gelmezse TV LG sayılır ve bu söylenir.</summary>
    private async Task AddManualAsync()
    {
        Error.Text = "";
        if (LgDiscovery.NormalizeHost(ManualHost.Text) is not { } host)
        {
            Error.Text = Localizer.Current["This is not a valid IP address. Type it like 192.168.1.20, without http:// or a port number."];
            return;
        }
        if (Tvs.Children.OfType<Grid>().Any(row => Equals(row.Tag, host))) return;
        AddManual.IsEnabled = false;
        var manual = await LgDiscovery.ManualTvAsync(host);
        AddRow(manual.Tv);
        if (!manual.Recognised) Error.Text = Localizer.Current.Format(ManualTvNotRecognised, host);
        NotFound.Visibility = Visibility.Collapsed;
        ManualHost.Text = "";
        AddManual.IsEnabled = true;
    }

    private const string ManualTvNotRecognised =
        "No TV at %@ answered as an LG, Samsung or Android TV, so it was added as an LG TV. If it is an Android TV / Google TV, press Select under Android TV / Google TV below.";

    private async void OnAddManual(object sender, RoutedEventArgs e) => await AddManualAsync();

    private async void OnManualHostKey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Enter) await AddManualAsync();
    }

    private async Task PairAsync(LgTv tv)
    {
        Tvs.IsEnabled = false;
        // Samsung'da izin kutusu ve bekleme süresi açıkça söylenir.
        Waiting.Text = tv.Brand == TvBrand.Samsung
            ? Localizer.Current["Accept the permission box on the TV with the remote (Allow). CouchSubs waits 60 seconds."]
            : Localizer.Current["Accept the request on the TV…"];
        Waiting.Visibility = Visibility.Visible;
        Error.Text = "";
        try
        {
            await Controller.PairAsync(tv);
            ShowDone();
        }
        catch (Exception error)
        {
            Error.Text = TvAppMessages.PairingProblem(error, tv.Brand, Localizer.Current);
        }
        Waiting.Visibility = Visibility.Collapsed;
        Tvs.IsEnabled = true;
    }

    private async void OnSearch(object sender, RoutedEventArgs e) => await SearchAsync();

    /// <summary>"TV'm yok": TV kurulmaz, altyazı bilgisayar ekranında gösterilir; sonraki adıma geçilir.</summary>
    private void OnNoTv(object sender, RoutedEventArgs e) => Controller.UseComputerScreen();

    private async void OnAndroidTv(object sender, RoutedEventArgs e) => await PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));

    private void OnGuide(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("https://github.com/yorulmazsinan/couchsubs/blob/main/docs/tv-kurulum.md") { UseShellExecute = true });
}
