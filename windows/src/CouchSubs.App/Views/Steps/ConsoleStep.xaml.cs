// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
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

    private void OnShowLog(object sender, RoutedEventArgs e)
    {
        var path = RemotePlayLog.FilePath;
        try
        {
            var folder = Path.GetDirectoryName(path)!;
            Directory.CreateDirectory(folder);
            var arguments = File.Exists(path) ? $"/select,\"{path}\"" : $"\"{folder}\"";
            Process.Start(new ProcessStartInfo("explorer.exe", arguments) { UseShellExecute = true });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            // Dosya Gezgini açılamazsa yol zaten hata iletisinde yazıyor.
        }
    }
}
