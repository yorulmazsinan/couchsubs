// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

public partial class PsnLoginStep : UserControl
{
    public PsnLoginStep()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
    }

    private AppController Controller => (AppController)DataContext;

    private void Refresh()
    {
        SignIn.Content = Localizer.Current[Controller.HasAccount ? "Sign in again" : "Sign in"];
        SignIn.Style = (Style)FindResource(Controller.HasAccount ? "SecondaryButton" : "PrimaryButton");
    }

    private async void OnSignIn(object sender, RoutedEventArgs e)
    {
        // Giriş penceresi WebView2 ile açılır; kurulum normalde onu da kurar, yine de eksikse çökmek yerine yol gösterilir.
        if (!PsnLoginWindow.IsBrowserAvailable())
        {
            CouchSubs.RemotePlay.RemotePlayLog.Note("PSN girişi: WebView2 kurulu değil");
            Error.Text = Localizer.Current["The sign-in window needs Microsoft's WebView2 component, which is missing on this computer. Install it from the page that just opened, then press Sign in again."];
            try { Process.Start(new ProcessStartInfo(PsnLoginWindow.BrowserDownloadUrl) { UseShellExecute = true }); }
            catch (Exception) { }
            return;
        }
        var (redirect, problem) = PsnLoginWindow.Show(Window.GetWindow(this));
        if (redirect is null)
        {
            // Pencere giriş bitmeden kapandı: eskiden sessizce dönülüyordu.
            Error.Text = Controller.LoginWindowError(problem).Message;
            return;
        }
        SignIn.IsEnabled = false;
        Error.Text = "";
        try
        {
            await Controller.CompletePsnLoginAsync(redirect);
        }
        catch (AppException error)
        {
            Error.Text = error.Message;
        }
        catch (Exception error)
        {
            // Son çare: denetleyici her hatayı AppException'a çevirir; buraya düşen yine de ayrıntısıyla gösterilir.
            Error.Text = $"{AppException.Describe(AppError.InvalidLogin, Localizer.Current)} ({error.Message})";
        }
        SignIn.IsEnabled = true;
        Refresh();
    }

    private void OnShowManual(object sender, RoutedEventArgs e)
    {
        ShowManual.Visibility = Visibility.Collapsed;
        Manual.Visibility = Visibility.Visible;
        ManualId.Focus();
    }

    /// <summary>Kimlik alanında Enter kaydeder; adımın "Devam" düğmesine gitmez.</summary>
    private void OnManualKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is not (Key.Enter or Key.Return)) return;
        e.Handled = true;
        OnSaveManual(sender, e);
    }

    private void OnSaveManual(object sender, RoutedEventArgs e)
    {
        if (Controller.UseManualAccountId(ManualId.Text))
        {
            ManualError.Text = "";
            Error.Text = "";
            Refresh();
        }
        else
        {
            ManualError.Text = Localizer.Current["This is not a valid account ID. It is 12 characters in base64, e.g. AbCdEfGhIjk=."];
        }
    }
}
