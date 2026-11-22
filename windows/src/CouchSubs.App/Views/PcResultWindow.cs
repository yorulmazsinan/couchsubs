// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using CouchSubs.App.Theme;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using CouchSubs.App.Services;

namespace CouchSubs.App.Views;

/// <summary>
/// Ek bölgenin çevirisini bilgisayarda gösteren küçük kutu: ekranın altında ortada, her pencerenin üstünde durur,
/// odağı almaz. Süre dolunca ya da tıklanınca kapanır.
/// </summary>
public sealed class PcResultWindow : Window
{
    private static PcResultWindow? current;
    private readonly DispatcherTimer timer;

    /// <summary>Çeviriyi gösterir; önceki kutu varsa yerine geçer.</summary>
    public static void Display(string text, int milliseconds)
    {
        current?.Close();
        current = new PcResultWindow(text, milliseconds);
        current.Show();
    }

    private PcResultWindow(string text, int milliseconds)
    {
        var work = SystemParameters.WorkArea;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        MaxWidth = work.Width * 0.7;
        Cursor = Cursors.Hand;
        // Başka bir üstte duran pencere öne gelirse kutu yeniden en üste konur (kapanınca kanca kalkar).
        _ = new TopmostKeeper(this);

        Content = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xEE, 0, 0, 0)),
            CornerRadius = new CornerRadius(12),
            Padding = Sp.T("m", "s", "m", "s"),
            Child = new TextBlock
            {
                Text = text,
                Foreground = Brushes.White,
                FontSize = 24,
                TextWrapping = TextWrapping.Wrap,
            },
        };

        // Boyut ölçüldükten sonra altta ortaya yerleştirilir.
        Loaded += (_, _) =>
        {
            Left = work.Left + ((work.Width - ActualWidth) / 2);
            Top = work.Bottom - ActualHeight - 40;
        };
        MouseLeftButtonDown += (_, _) => Close();

        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(Math.Max(1500, milliseconds)) };
        timer.Tick += (_, _) => Close();
        timer.Start();
        Closed += (_, _) =>
        {
            timer.Stop();
            if (ReferenceEquals(current, this)) current = null;
        };
    }
}
