// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>Altyazının yeri (TV, bilgisayar ekranı, ikisi) ve bilgisayar ekranındaki pencerenin seçenekleri.</summary>
public partial class SubtitleOutputCard : UserControl
{
    private AppController? controller;
    private bool loading;
    private bool subscribed;

    public SubtitleOutputCard()
    {
        InitializeComponent();
        // Ayarlardaki bölümler değişince kart görsel ağaçtan çıkıp yeniden girer; abonelik buna göre açılıp kapanır.
        Loaded += (_, _) => Subscribe();
        Unloaded += (_, _) =>
        {
            if (controller is not null && subscribed) controller.PropertyChanged -= OnChanged;
            subscribed = false;
        };
    }

    private void Subscribe()
    {
        if (controller is null || subscribed) return;
        controller.PropertyChanged += OnChanged;
        subscribed = true;
        Refresh();
    }

    /// <summary>Ayarlarda açıklamalar da gösterilir; ana ekranda kart kısa kalır.</summary>
    public bool Detailed { get; set; }

    internal void Attach(AppController attached)
    {
        controller = attached;
        Subscribe();
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.Settings) or nameof(AppController.OverlayAdjusting)) Refresh();
    }

    private void Refresh()
    {
        if (controller is null) return;
        loading = true;
        var settings = controller.Settings;
        (settings.Output switch { SubtitleOutput.Computer => OutputComputer, SubtitleOutput.Both => OutputBoth, _ => OutputTv }).IsChecked = true;
        ComputerPanel.Visibility = controller.ShowsOnComputer ? Visibility.Visible : Visibility.Collapsed;
        WindowHint.Visibility = Detailed ? Visibility.Visible : Visibility.Collapsed;
        ClickThrough.IsChecked = settings.OverlayClickThrough;
        ClickThroughHint.Visibility = Detailed || settings.OverlayClickThrough ? Visibility.Visible : Visibility.Collapsed;
        Adjust.IsEnabled = !controller.OverlayAdjusting;
        loading = false;
    }

    private void OnOutput(object sender, RoutedEventArgs e)
    {
        if (loading || controller is null || sender is not RadioButton { Tag: string tag }) return;
        controller.Settings = controller.Settings with { Output = Enum.Parse<SubtitleOutput>(tag) };
    }

    private void OnClickThrough(object sender, RoutedEventArgs e)
    {
        if (loading || controller is null) return;
        controller.Settings = controller.Settings with { OverlayClickThrough = ClickThrough.IsChecked == true };
    }

    private void OnAdjust(object sender, RoutedEventArgs e)
    {
        if (controller is not null) controller.OverlayAdjusting = true;
    }
}
