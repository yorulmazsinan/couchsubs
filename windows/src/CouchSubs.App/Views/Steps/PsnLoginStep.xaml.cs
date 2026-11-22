// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using CouchSubs.App.Controls;
using CouchSubs.Core;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

public partial class PsnLoginStep : UserControl
{
    public PsnLoginStep()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Refresh();
            if (Window.GetWindow(this) is { } window) window.Activated += OnWindowActivated;
        };
        Unloaded += (_, _) =>
        {
            if (Window.GetWindow(this) is { } window) window.Activated -= OnWindowActivated;
        };
    }

    /// <summary>Son denenen yönlendirme adresi: tek kullanımlık kod panodan ikinci kez denenmez.</summary>
    private string? lastBrowserRedirect;

    private AppController Controller => (AppController)DataContext;

    private void Refresh()
    {
        // Hesap kartı girişli/girişsiz görünümü HasAccount bağlamasıyla kendisi değiştirir; burada yalnız yeniden okunur.
        Account.GetBindingExpression(AccountCard.SignedInProperty)?.UpdateTarget();
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
        var (redirect, problem, useBrowser) = PsnLoginWindow.Show(Window.GetWindow(this));
        if (redirect is null && useBrowser)
        {
            // Sony'nin sayfası uygulama içinde sunucusuna bağlanamadı; aynı giriş tarayıcıda çalışıyor.
            Error.Text = "";
            OpenBrowserLogin(automatic: true);
            return;
        }
        if (redirect is null)
        {
            // Pencere giriş bitmeden kapandı: eskiden sessizce dönülüyordu.
            Error.Text = Controller.LoginWindowError(problem).Message;
            return;
        }
        await CompleteAsync(redirect);
    }

    private async Task CompleteAsync(Uri redirect)
    {
        Account.Busy = true;
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
        Account.Busy = false;
        Refresh();
    }

    private void OnShowBrowser(object sender, RoutedEventArgs e) => OpenBrowserLogin(automatic: false);

    private void OnOpenBrowser(object sender, RoutedEventArgs e) => Controller.OpenPsnLoginInBrowser();

    /// <summary>Sony'nin giriş sayfası sistem tarayıcısında açılır, adres yapıştırma alanı görünür.</summary>
    private void OpenBrowserLogin(bool automatic)
    {
        ShowBrowser.Visibility = Visibility.Collapsed;
        BrowserPanel.Visibility = Visibility.Visible;
        Account.Expanded = true;
        BrowserReason.Visibility = automatic ? Visibility.Visible : Visibility.Collapsed;
        BrowserError.Text = "";
        // Tarayıcı açılmadan önce panoda duran (eski girişten kalmış) adres kendiliğinden denenmesin.
        try { lastBrowserRedirect = PsnAccount.RedirectFromPastedText(Clipboard.GetText())?.AbsoluteUri ?? lastBrowserRedirect; }
        catch (Exception) { }
        Controller.OpenPsnLoginInBrowser();
        BrowserUrl.Focus();
    }

    /// <summary>Kullanıcı tarayıcıdan dönünce panoda yönlendirme adresi varsa kendiliğinden alınır.</summary>
    private void OnWindowActivated(object? sender, EventArgs e)
    {
        if (BrowserPanel.Visibility != Visibility.Visible || Account.Busy) return;
        string clipboard;
        try { clipboard = Clipboard.ContainsText() ? Clipboard.GetText() : ""; }
        catch (Exception) { return; }
        if (PsnAccount.RedirectFromPastedText(clipboard) is not { } redirect || redirect.AbsoluteUri == lastBrowserRedirect) return;
        BrowserUrl.Text = redirect.AbsoluteUri;
        _ = SubmitBrowserAsync();
    }

    private void OnBrowserKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is not (Key.Enter or Key.Return)) return;
        e.Handled = true;
        _ = SubmitBrowserAsync();
    }

    private void OnSaveBrowser(object sender, RoutedEventArgs e) => _ = SubmitBrowserAsync();

    private async Task SubmitBrowserAsync()
    {
        if (Account.Busy) return;
        if (PsnAccount.RedirectFromPastedText(BrowserUrl.Text) is not { } redirect)
        {
            BrowserError.Text = Localizer.Current["This address has no sign-in code. It should start with https://remoteplay.dl.playstation.net/remoteplay/redirect?code="];
            return;
        }
        BrowserError.Text = "";
        lastBrowserRedirect = redirect.AbsoluteUri;
        await CompleteAsync(redirect);
        if (Controller.HasAccount && Error.Text.Length == 0)
        {
            BrowserUrl.Text = "";
            BrowserPanel.Visibility = Visibility.Collapsed;
            ShowBrowser.Visibility = Visibility.Visible;
            // Kullanılmış kod panoda kalmasın.
            try { if (PsnAccount.RedirectFromPastedText(Clipboard.GetText()) is not null) Clipboard.Clear(); }
            catch (Exception) { }
        }
    }

    private void OnShowManual(object sender, RoutedEventArgs e)
    {
        ShowManual.Visibility = Visibility.Collapsed;
        Manual.Visibility = Visibility.Visible;
        Account.Expanded = true;
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
