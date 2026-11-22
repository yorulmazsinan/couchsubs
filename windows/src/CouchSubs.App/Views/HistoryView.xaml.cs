// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using CouchSubs.App.Controls;
using CouchSubs.Core;
using CouchSubs.Shell;
using Microsoft.Win32;

namespace CouchSubs.App.Views;

/// <summary>
/// Altyazı geçmişi (yeni arayüz): bu ve önceki oturumlarda çevrilen satırlar, en yenisi üstte; sayfa açıkken gelen
/// satırlar hemen eklenir. Arama Türkçe ve İngilizce metinde, seçici kaynağa göre süzer. Satır ya da hepsi kopyalanır
/// ("Türkçe\nİngilizce"), görünen satırlar dosyaya aktarılır, hatalı çeviri GitHub'da bildirilir, geçmiş silinebilir.
/// </summary>
public partial class HistoryView : UserControl
{
    /// <summary>Tablodaki bir satır (saat yerel, kaynak etiketi çevrilmiş).</summary>
    public sealed record Row(string Time, string Translation, string Source, string Origin, PillTone Tone, SubtitleHistory.Entry Entry);

    private const string IssuePage = "https://github.com/yorulmazsinan/couchsubs/issues/new";

    private readonly AppController controller;
    private IReadOnlyList<SubtitleHistory.Entry> shown = [];

    internal HistoryView(AppController controller)
    {
        this.controller = controller;
        controller.NoteScreen("history");
        InitializeComponent();
        FilterEngine.Content = EngineName();
        controller.PropertyChanged += OnChanged;
        Unloaded += (_, _) => controller.PropertyChanged -= OnChanged;
        ShowEntries();
    }

    /// <summary>Geçmiş sekmesini açar.</summary>
    public static void Open(Window? owner, AppController controller) => ShellWindow.Navigate(ShellTab.History);

    private string EngineName() =>
        controller.Settings.Engine == TranslationEngine.Free ? Localizer.Current["Free"] : controller.Settings.Engine.DisplayName();

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppController.History)) Dispatcher.Invoke(ShowEntries);
    }

    private void OnSearch(object sender, TextChangedEventArgs e)
    {
        SearchHint.Visibility = Search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowEntries();
    }

    private void OnFilter(object sender, RoutedEventArgs e)
    {
        if (IsInitialized) ShowEntries();
    }

    private void ShowEntries()
    {
        if (Lines is null) return;
        var text = Localizer.Current;
        var culture = text.Language == "tr" ? new CultureInfo("tr-TR") : CultureInfo.InvariantCulture;
        var query = Search.Text.Trim();
        var origin = FilterPack.IsChecked == true ? LineOrigin.Pack : FilterEngine.IsChecked == true ? LineOrigin.Engine : (LineOrigin?)null;
        var all = controller.History;
        shown = [.. all.Where(entry => (origin is null || entry.Origin == origin)
            && (query.Length == 0 || culture.CompareInfo.IndexOf(entry.Translation + "\n" + entry.Source, query, CompareOptions.IgnoreCase) >= 0))];
        var engine = EngineName();
        Lines.ItemsSource = shown.Select(entry => new Row(
            entry.Date.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture),
            entry.Translation,
            entry.Source,
            entry.Origin == LineOrigin.Pack ? text["Pack"] : engine,
            entry.Origin == LineOrigin.Pack ? PillTone.Attention : PillTone.Idle,
            entry)).ToList();
        var empty = shown.Count == 0;
        EmptyHint.Text = all.Count == 0 ? text["No subtitles yet. Lines translated while you play appear here."] : text["No lines match this search."];
        EmptyHint.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        Lines.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        var today = shown.Count(entry => entry.Date.ToLocalTime().Date == DateTime.Now.Date);
        Summary.Text = controller.PlayedGame is { } game ? text.Format("%@ · Today · %lld Lines", game, today) : text.Format("Today · %lld Lines", today);
        ExportButton.IsEnabled = !empty;
        CopyAllButton.IsEnabled = !empty;
        ReportButton.IsEnabled = !empty;
        ClearAll.IsEnabled = all.Count > 0;
        CopyAll.IsEnabled = !empty;
    }

    private Row? Selected => Lines.SelectedItem as Row ?? Lines.Items.OfType<Row>().FirstOrDefault();

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (Selected is { } row) Copy($"{row.Translation}\n{row.Source}");
    }

    private void OnCopyAll(object sender, RoutedEventArgs e) => Copy(SubtitleHistory.PlainText(shown));

    private void OnLinesKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.C || (Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
        OnCopy(sender, e);
        e.Handled = true;
    }

    /// <summary>Görünen satırlar (arama ve seçiciye göre) metin dosyasına yazılır.</summary>
    private void OnExport(object sender, RoutedEventArgs e)
    {
        var picker = new SaveFileDialog
        {
            FileName = $"CouchSubs-{DateTime.Now:yyyy-MM-dd}.txt",
            Filter = "Text (*.txt)|*.txt",
            Title = Localizer.Current["Export"],
        };
        if (picker.ShowDialog(Window.GetWindow(this)) != true) return;
        try
        {
            File.WriteAllText(picker.FileName, SubtitleHistory.PlainText(shown));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(Window.GetWindow(this) ?? Application.Current.MainWindow, error.Message, "CouchSubs");
        }
    }

    /// <summary>Seçili (yoksa en yeni) satır GitHub'da yeni sorun sayfasında, İngilizce ve Türkçesiyle açılır.</summary>
    private void OnReport(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } row) return;
        var title = Uri.EscapeDataString("Hatalı çeviri / Wrong translation");
        var body = Uri.EscapeDataString($"EN: {row.Source}\nTR: {row.Translation}\n{(controller.PlayedGame is { } game ? $"Oyun / Game: {game}\n" : "")}\n");
        controller.OpenInBrowser(new Uri($"{IssuePage}?title={title}&body={body}"));
    }

    /// <summary>Pano başka bir uygulamada kilitliyse kopyalanamaz; sayfa açık kalır.</summary>
    private static void Copy(string value)
    {
        try { Clipboard.SetText(value); }
        catch (System.Runtime.InteropServices.COMException) { }
    }

    /// <summary>Geçmiş sorulmadan silinmez (Mac ve telefonlarla aynı onay).</summary>
    private void OnClear(object sender, RoutedEventArgs e)
    {
        var text = Localizer.Current;
        if (MessageBox.Show(Window.GetWindow(this) ?? Application.Current.MainWindow, text["All saved lines are removed from this computer."], text["Clear the history?"],
                            MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            controller.ClearHistory();
    }
}
