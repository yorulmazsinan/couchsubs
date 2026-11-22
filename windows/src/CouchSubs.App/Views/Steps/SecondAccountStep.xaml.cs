// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

public partial class SecondAccountStep : UserControl
{
    public SecondAccountStep()
    {
        InitializeComponent();
        SignUpCode.Source = Qr(CouchSubs.Core.SecondScreen.QrModules(SignUpPage));
        MainAccountWarning.Content = StepText.Rich(CouchSubs.Core.Localizer.Current[
            "When you turn on the controller to play, choose your **main** account on the PS5. Don't play with the second account CouchSubs signs in with, or the controller will turn off by itself or won't work in the game."]);
        // PS Remote Play ya da chiaki-ng kurulu değilse indirme düğmeleri görünür.
        Loaded += (_, _) => DownloadPanel.Visibility =
            Controller.RemotePlayInstalled(RemotePlayApp.Automatic) ? Visibility.Collapsed : Visibility.Visible;
    }

    private AppController Controller => (AppController)DataContext;

    /// <summary>"İkinci hesap yok mu?": görüntü bu bilgisayardaki Remote Play penceresinden okunur, kurulum biter.</summary>
    private void OnUseRemotePlayWindow(object sender, RoutedEventArgs e) => Controller.UseRemotePlayWindow();

    private void OnUseCaptureWindow(object sender, RoutedEventArgs e) => Controller.UseCaptureWindow();

    private void OnDownloadSony(object sender, RoutedEventArgs e) => Open(AppController.SonyRemotePlayDownload);
    private void OnDownloadChiaki(object sender, RoutedEventArgs e) => Open(AppController.ChiakiDownload);

    private static void Open(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();

    /// <summary>Sony'nin ücretsiz PlayStation hesabı açma sayfası (QR ve düğme aynı adrese gider).</summary>
    private const string SignUpPage = "https://www.playstation.com/acct/create-account";

    private void OnOpenSignUp(object sender, RoutedEventArgs e) =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(SignUpPage) { UseShellExecute = true });

    private static System.Windows.Media.Imaging.BitmapSource Qr(bool[][] modules)
    {
        var size = modules.Length;
        var pixels = new byte[size * size];
        for (var y = 0; y < size; y++)
            for (var x = 0; x < size; x++)
                pixels[y * size + x] = modules[y][x] ? (byte)0 : (byte)255;
        var bitmap = System.Windows.Media.Imaging.BitmapSource.Create(size, size, 96, 96, System.Windows.Media.PixelFormats.Gray8, null, pixels, size);
        bitmap.Freeze();
        return bitmap;
    }
}
