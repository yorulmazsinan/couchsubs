// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>
/// Altyazı geçmişi: bu ve önceki oturumlarda çevrilen satırlar, en yenisi üstte. Pencere açıkken gelen satırlar hemen
/// eklenir. Satır ya da hepsi kopyalanır ("Türkçe\nİngilizce"); geçmiş silinebilir.
/// </summary>
public partial class HistoryWindow : Window
{
    /// <summary>Listedeki bir satır (saat yerel, kaynak etiketi çevrilmiş).</summary>
    public sealed record Row(string Time, string Translation, string Source, string Origin, SubtitleHistory.Entry Entry);

    private readonly AppController controller;

    internal HistoryWindow(AppController controller)
    {
        this.controller = controller;
        InitializeComponent();
        KeptHint.Text = Localizer.Current.Format("The last %lld translated lines are kept on this computer.", SubtitleHistory.DefaultLimit);
        controller.PropertyChanged += OnChanged;
        Closed += (_, _) => controller.PropertyChanged -= OnChanged;
        ShowEntries(controller.History);
    }

    public static void Open(Window? owner, AppController controller) =>
        new HistoryWindow(controller) { Owner = owner }.ShowDialog();

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppController.History)) Dispatcher.Invoke(() => ShowEntries(controller.History));
    }

    private void ShowEntries(IReadOnlyList<SubtitleHistory.Entry> entries)
    {
        var text = Localizer.Current;
        Lines.ItemsSource = entries.Select(entry => new Row(
            entry.Date.ToLocalTime().ToString("HH:mm:ss", CultureInfo.InvariantCulture),
            entry.Translation,
            entry.Source,
            text[entry.Origin == LineOrigin.Pack ? "Pack" : "Translation engine"],
            entry)).ToList();
        var empty = entries.Count == 0;
        EmptyHint.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        Scroller.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        CopyAll.IsEnabled = !empty;
        CopyAll.Content = text["Copy all"];
        ClearAll.IsEnabled = !empty;
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: Row row } button) return;
        if (Copy($"{row.Translation}\n{row.Source}")) button.Content = Localizer.Current["Copied"];
    }

    private void OnCopyAll(object sender, RoutedEventArgs e)
    {
        if (Copy(SubtitleHistory.PlainText(controller.History))) CopyAll.Content = Localizer.Current["Copied"];
    }

    /// <summary>Pano başka bir uygulamada kilitliyse kopyalanamaz; pencere açık kalır.</summary>
    private static bool Copy(string value)
    {
        try
        {
            Clipboard.SetText(value);
            return true;
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return false;
        }
    }

    private void OnClear(object sender, RoutedEventArgs e) => controller.ClearHistory();

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
