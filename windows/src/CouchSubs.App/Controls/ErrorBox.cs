// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using CouchSubs.App.Theme;
using CouchSubs.Core;

namespace CouchSubs.App.Controls;

/// <summary>
/// Hata kutusu (Mac DSErrorBox): başlık (ne oldu), iletinin ilk paragrafı (neden), sonraki paragraflar numaralı (çözüm);
/// altta kutunun düğmeleri (Content; ör. Tekrar Dene) ve her zaman "Günlüğü Kopyala" (maskeli günlük zip'i panoya dosya
/// olarak). Paragraflar iletide boş satırla ("\n\n") ayrılır. İleti boşsa kutu görünmez.
/// </summary>
public class ErrorBox : ContentControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(ErrorBox));
    public static readonly DependencyProperty MessageProperty = DependencyProperty.Register(nameof(Message), typeof(string), typeof(ErrorBox),
        new FrameworkPropertyMetadata(null, (d, _) => ((ErrorBox)d).Fill()));

    private Panel? body;
    private ButtonBase? copyLog;

    static ErrorBox() => DefaultStyleKeyProperty.OverrideMetadata(typeof(ErrorBox), new FrameworkPropertyMetadata(typeof(ErrorBox)));

    public ErrorBox() => Visibility = Visibility.Collapsed;

    public string? Title { get => (string?)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string? Message { get => (string?)GetValue(MessageProperty); set => SetValue(MessageProperty, value); }

    public override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        body = GetTemplateChild("PART_Body") as Panel;
        if (copyLog is not null) copyLog.Click -= OnCopyLog;
        copyLog = GetTemplateChild("PART_CopyLog") as ButtonBase;
        if (copyLog is not null) copyLog.Click += OnCopyLog;
        Fill();
    }

    private void Fill()
    {
        var parts = (Message ?? "").Split("\n\n", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Visibility = parts.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (copyLog is not null) copyLog.Content = Localizer.Current["Copy Log"];
        if (body is null) return;
        body.Children.Clear();
        for (var i = 0; i < parts.Length; i++)
        {
            var text = new TextBlock { Text = parts[i], TextWrapping = TextWrapping.Wrap };
            text.SetResourceReference(TextBlock.FontSizeProperty, "smallFontSize");
            if (i == 0)
            {
                text.SetResourceReference(TextBlock.ForegroundProperty, "textBrush");
                body.Children.Add(text);
                continue;
            }
            text.SetResourceReference(TextBlock.ForegroundProperty, "mutedBrush");
            var number = new TextBlock { Text = $"{i}.", Margin = Sp.T("0", "0", "xs", "0") };
            number.SetResourceReference(TextBlock.FontSizeProperty, "smallFontSize");
            number.SetResourceReference(TextBlock.ForegroundProperty, "mutedBrush");
            var row = new DockPanel();
            DockPanel.SetDock(number, Dock.Left);
            row.Children.Add(number);
            row.Children.Add(text);
            body.Children.Add(row);
        }
    }

    private async void OnCopyLog(object sender, RoutedEventArgs e)
    {
        if (copyLog is null) return;
        copyLog.IsEnabled = false;
        var copied = await Services.LogArchive.CopyToClipboardAsync();
        copyLog.IsEnabled = true;
        copyLog.Content = Localizer.Current[copied ? "Log Copied" : "Copy Log"];
    }
}
