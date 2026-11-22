// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>"Başka bir cihazda göster": adresin QR kodu, adres ve Kopyala. Erişim anahtarı yenilenince kendini yeniler.</summary>
public partial class SecondScreenPanel : UserControl
{
    private AppController? controller;
    private bool subscribed;
    private string? shown;

    public SecondScreenPanel()
    {
        InitializeComponent();
        Loaded += (_, _) => Subscribe();
        Unloaded += (_, _) =>
        {
            if (controller is not null && subscribed) controller.PropertyChanged -= OnChanged;
            subscribed = false;
        };
    }

    internal void Attach(AppController attached)
    {
        controller = attached;
        Subscribe();
    }

    private void Subscribe()
    {
        if (controller is null || subscribed) return;
        controller.PropertyChanged += OnChanged;
        subscribed = true;
        Refresh();
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.SecondScreenAddress) or nameof(AppController.ServerPort)) Refresh();
    }

    /// <summary>Ağ adresi açılışta yokken sonradan gelmiş olabilir; pencerecik her açılışta da yeniler.</summary>
    internal void Refresh()
    {
        if (controller is null) return;
        var address = controller.SecondScreenAddress;
        Ready.Visibility = address is null ? Visibility.Collapsed : Visibility.Visible;
        Offline.Visibility = address is null ? Visibility.Visible : Visibility.Collapsed;
        if (address is null || address == shown) return;
        shown = address;
        Address.Text = address;
        Code.Source = QrBitmap(SecondScreen.QrModules(address));
    }

    /// <summary>Her modül bir piksel; görüntü büyütülürken yumuşatılmaz (NearestNeighbor).</summary>
    private static BitmapSource QrBitmap(bool[][] modules)
    {
        var size = modules.Length;
        var pixels = new byte[size * size];
        for (var y = 0; y < size; y++)
            for (var x = 0; x < size; x++)
                pixels[y * size + x] = modules[y][x] ? (byte)0 : (byte)255;
        var bitmap = BitmapSource.Create(size, size, 96, 96, PixelFormats.Gray8, null, pixels, size);
        bitmap.Freeze();
        return bitmap;
    }
}
