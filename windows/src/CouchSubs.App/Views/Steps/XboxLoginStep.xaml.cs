// SPDX-License-Identifier: AGPL-3.0-only
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Navigation;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

/// <summary>
/// Microsoft girişi (cihaz kodu): kod gösterilir ve panoya kopyalanır, microsoft.com/link tarayıcıda açılır; açılmazsa
/// bağlantıya tıklanır. Telefonlardaki XboxLoginScreen ile aynı adımlar.
/// </summary>
public partial class XboxLoginStep : UserControl
{
    private bool working;
    public XboxLoginStep() => InitializeComponent();
    private AppController Controller => (AppController)DataContext;

    /// <summary>"Bilgisayarda Xbox uygulaması/play.xbox.com ile mi oynuyorsunuz?": Xbox'a bağlanılmaz, kurulum biter (#853).</summary>
    private void OnUseXboxWindow(object sender, RoutedEventArgs e) => Controller.UseXboxWindow();

    private async void OnSignIn(object sender, RoutedEventArgs e)
    {
        if (working) return;
        working = true;
        var text = Localizer.Current;
        SignIn.IsEnabled = false;
        Error.Text = "";
        Status.Text = text["Opening the Microsoft sign-in page…"];
        try
        {
            var challenge = await Controller.BeginXboxLoginAsync();
            Code.Text = challenge.Code;
            CopyCode();
            Link.NavigateUri = challenge.Url;
            LinkText.Text = challenge.Url.Host.Replace("www.", "") + challenge.Url.AbsolutePath.TrimEnd('/');
            Steps.Text = text["1. The code is copied and microsoft.com/link is open in your browser. If it didn't open, click the link above.\n2. Paste the code, sign in with the Microsoft account you use on your Xbox and allow access.\n3. Come back to CouchSubs; sign-in finishes on its own."];
            CodePanel.Visibility = Visibility.Visible;
            Status.Text = text["Waiting for the sign-in to finish…"];
            await Controller.CompleteXboxLoginAsync();
            CodePanel.Visibility = Visibility.Collapsed;
            Status.Text = text["Microsoft sign-in is done. You can continue."];
        }
        catch (Exception error)
        {
            CodePanel.Visibility = Visibility.Collapsed;
            Error.Text = error.Message;
            Status.Text = text["Sign-in did not finish. You can try again."];
        }
        finally
        {
            working = false;
            SignIn.IsEnabled = true;
        }
    }

    private void OnCopyCode(object sender, MouseButtonEventArgs e)
    {
        CopyCode();
        Code.SelectAll();
    }

    private void CopyCode()
    {
        if (string.IsNullOrEmpty(Code.Text)) return;
        try { Clipboard.SetText(Code.Text); }
        catch (System.Runtime.InteropServices.COMException) { } // pano başka bir uygulamada kilitli
    }

    private void OnOpenLink(object sender, RequestNavigateEventArgs e)
    {
        CopyCode();
        try { Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { }
        e.Handled = true;
    }

    private void OnShowLog(object sender, RoutedEventArgs e) => LogFile.Show();
}
