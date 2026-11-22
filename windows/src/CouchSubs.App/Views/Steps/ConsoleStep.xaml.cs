// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using CouchSubs.App.Theme;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using CouchSubs.Core;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

public partial class ConsoleStep : UserControl
{
    private string? selected;

    public ConsoleStep()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            ShowDone();
            await SearchAsync();
        };
    }

    private AppController Controller => (AppController)DataContext;

    private string Host => selected ?? ManualHost.Text.Trim();

    private void ShowDone()
    {
        var name = Controller.Console?.Name;
        Done.Text = string.IsNullOrEmpty(name) ? "PS5" : name;
        Done.Visibility = Controller.Console is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private async Task SearchAsync()
    {
        Search.IsEnabled = false;
        Consoles.Children.Clear();
        var found = await Controller.DiscoverConsolesAsync();
        selected ??= found.FirstOrDefault()?.Host;
        foreach (var console in found)
        {
            var option = new RadioButton { Content = $"{console.Name} — {console.Host}", IsChecked = console.Host == selected, GroupName = "ps5" };
            option.Checked += (_, _) => selected = console.Host;
            Consoles.Children.Add(option);
        }
        var none = found.Count == 0;
        NotFound.Visibility = ManualHost.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
        Search.IsEnabled = true;
        if (none) await ShowChecksAsync(found.Count > 0);
        else ChecksCard.Visibility = Visibility.Collapsed;
    }

    /// <summary>"Neyin Eksik Olduğuna Baktık": aynı ağ, PS5'in yanıtı, Uzaktan Oynama, dinlenme modunda internet, 5 GHz, VPN.</summary>
    private async Task ShowChecksAsync(bool found)
    {
        var text = Localizer.Current;
        ChecksCard.Visibility = Visibility.Visible;
        TryAgain.IsEnabled = false;
        TryAgain.Content = text["Checking…"];
        var results = await Services.NetworkChecks.RunAsync(found);
        ChecksRows.Children.Clear();
        Row(text["Same Network"], results.SameNetwork, "This Mac and the PS5 appear to be on the same network.",
            "This Mac isn't connected to a local network. Connect it to the same Wi-Fi as the PS5.");
        Row(text["PS5 Responds"], results.Ps5Responds, "The PS5 was found.", "The PS5 didn't answer the search. The PS5 must be on or in rest mode.");
        Row(text["Remote Play On"], results.RemotePlay, null, "On the second user, Settings › System › Remote Play › Enable Remote Play must be on.");
        Row(text["Internet in Rest Mode"], results.RestModeInternet, null,
            "Staying connected to the internet in rest mode must be on; otherwise the PS5 can't be woken up.");
        Row(text["Wi-Fi 5 GHz"], results.Wifi5Ghz, "You're on a 5 GHz network.", "This Mac is on a 2.4 GHz network. A 5 GHz network works more smoothly and reliably.",
            "This Mac is connected by cable or the Wi-Fi band couldn't be read.");
        Row(text["VPN Off"], results.VpnOff, "No active VPN was found.", "A VPN is on. Turn it off while playing; it can hide the PS5.");
        TryAgain.IsEnabled = true;
        TryAgain.Content = text["Try Again"];
    }

    /// <summary>Denetim satırı: solda rozet (Geçti / Sorunlu / Bilinmiyor), başlık ve duruma göre açıklama.</summary>
    private void Row(string title, Services.CheckResult result, string? passed, string problem, string? unknown = null)
    {
        var text = Localizer.Current;
        var badge = new Controls.Badge
        {
            Content = text[result switch { Services.CheckResult.Passed => "Passed", Services.CheckResult.Problem => "Problem", _ => "Unknown" }],
            Tone = result switch { Services.CheckResult.Passed => Controls.PillTone.Success, Services.CheckResult.Problem => Controls.PillTone.Live, _ => Controls.PillTone.Idle },
            MinWidth = 88, Margin = Sp.T("0", "0", "m", "0"),
        };
        var detail = result switch
        {
            Services.CheckResult.Passed => passed,
            Services.CheckResult.Problem => problem,
            _ => unknown ?? problem,
        };
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var heading = new TextBlock { Text = title };
        heading.SetResourceReference(StyleProperty, "RowTitle");
        texts.Children.Add(heading);
        if (detail is not null)
        {
            // Mac metni "Bu Mac" der; Windows'ta "bu bilgisayar".
            var hint = new TextBlock { Text = text[detail].Replace("Mac", text.Language == "tr" ? "bilgisayar" : "computer"), Margin = Sp.T("0", "xxs", "0", "0") };
            hint.SetResourceReference(StyleProperty, "HintText");
            texts.Children.Add(hint);
        }
        var line = new DockPanel();
        DockPanel.SetDock(badge, Dock.Left);
        line.Children.Add(badge);
        line.Children.Add(texts);
        var row = new Border { Child = line, Padding = Sp.T("0", "s", "0", "s") };
        row.SetResourceReference(StyleProperty, "SettingRow");
        ChecksRows.Children.Add(row);
        Theme.Motion.EnterFrom(row, 8, Theme.Motion.Medium, TimeSpan.FromMilliseconds(60 * ChecksRows.Children.Count));
    }

    private async void OnSearch(object sender, RoutedEventArgs e) => await SearchAsync();

    /// <summary>Kod ya da adres alanında Enter bağlanır. Olay işlendi sayılır; yoksa Enter, adımın kapalı "Devam"
    /// düğmesine (IsDefault) gidip sessizce hiçbir şey yapmıyordu.</summary>
    private void OnFieldKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is not (Key.Enter or Key.Return)) return;
        e.Handled = true;
        if (!working && Connect.IsEnabled) OnConnect(sender, e);
    }

    private bool working;

    /// <summary>Eşleşme sonrası Bağlan kapalı kalır; yeni kod yazılınca yeniden açılır.</summary>
    private void OnPinChanged(object sender, TextChangedEventArgs e)
    {
        if (!working && Pin.Text.Length > 0) Connect.IsEnabled = true;
    }

    /// <summary>
    /// Düğme çalışırken ve eşleşmeden sonra (kod değişene dek) kapalı; eksik kod ya da adres tıklanınca açıkça söylenir,
    /// hiçbir sonuç sessiz kalmaz. Eşleşince düğmenin altında yeşil ileti çıkar ve ~1 sn sonra sonraki adıma geçilir.
    /// </summary>
    private async void OnConnect(object sender, RoutedEventArgs e)
    {
        if (working) return;
        working = true;
        Connect.IsEnabled = false;
        Working.Visibility = Visibility.Visible;
        Error.Text = "";
        Paired.Visibility = Visibility.Collapsed;
        var paired = false;
        try
        {
            await Controller.RegisterAsync(Host, Pin.Text);
            ShowDone();
            paired = true;
        }
        catch (AppException error)
        {
            Error.Text = error.Message;
        }
        catch (Exception error)
        {
            RemotePlayLog.Note($"PS5 eşleştirme ekranında beklenmedik hata: {error}");
            Error.Text = $"{AppException.Describe(AppError.RegistrationFailed, Localizer.Current)} ({error.Message}) "
                         + Localizer.Current.Format("If this keeps happening, send us this file: %@", RemotePlayLog.DisplayPath);
        }
        finally
        {
            working = false;
            Working.Visibility = Visibility.Collapsed;
            Connect.IsEnabled = !paired;
            ShowLog.Visibility = Error.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        if (paired) await ShowPairedAsync();
    }

    /// <summary>Başarı iletisi görünür kılınır (kaydırılmış olsa da), kod alanı temizlenir, kısa süre sonra sonraki adım açılır.</summary>
    private async Task ShowPairedAsync()
    {
        Paired.Text = $"✓ {Controller.PairedText}";
        Paired.Visibility = Visibility.Visible;
        Pin.Text = "";
        // Kod silinince TextChanged düğmeyi açmaz (boş kod); yine de açıkça kapalı tutulur.
        Connect.IsEnabled = false;
        Paired.UpdateLayout();
        Paired.BringIntoView();
        await Task.Delay(TimeSpan.FromSeconds(1));
        // Adım bu arada kapandıysa (Geri) denetleyici zaten ilerlemez; yalnız PS5 adımındayken geçer.
        if (IsLoaded) Controller.ContinueAfterPairing();
    }

    private void OnShowLog(object sender, RoutedEventArgs e) => LogFile.Show();
}
