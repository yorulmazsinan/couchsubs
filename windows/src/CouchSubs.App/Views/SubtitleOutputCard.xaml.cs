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
        SecondScreenView.Attach(attached);
        Subscribe();
    }

    private void OnSecondScreen(object sender, RoutedEventArgs e)
    {
        SecondScreenView.Refresh();
        SecondScreenPopup.IsOpen = true;
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.Settings) or nameof(AppController.OverlayAdjusting)
            or nameof(AppController.ObsAddress) or nameof(AppController.NetworkObsAddress)) Refresh();
    }

    private void Refresh()
    {
        if (controller is null) return;
        loading = true;
        var settings = controller.Settings;
        (settings.Output switch
        {
            SubtitleOutput.Computer => OutputComputer, SubtitleOutput.Both => OutputBoth, SubtitleOutput.Obs => OutputObs, _ => OutputTv,
        }).IsChecked = true;
        ComputerPanel.Visibility = controller.ShowsOnComputer ? Visibility.Visible : Visibility.Collapsed;
        // Kısa etiketlerin anlamı seçicinin altındaki cümlede (Mac outputHint); bilgisayar ekranında açıklamayı alttaki birim verir.
        OutputHint.Text = settings.Output switch
        {
            SubtitleOutput.Tv => CouchSubs.Core.Localizer.Current["Subtitles are shown on the TV."],
            SubtitleOutput.Obs => CouchSubs.Core.Localizer.Current["Only for streaming: subtitles go to the OBS overlay."],
            _ => "",
        };
        OutputHint.Visibility = OutputHint.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ObsPanel.Visibility = settings.Output == SubtitleOutput.Obs ? Visibility.Visible : Visibility.Collapsed;
        OutputObsAddress.Text = controller.ObsAddress;
        OutputNetworkObsAddress.Text = controller.NetworkObsAddress ?? "";
        OutputNetworkObsPanel.Visibility = controller.NetworkObsAddress is null ? Visibility.Collapsed : Visibility.Visible;
        WindowHint.Visibility = Detailed ? Visibility.Visible : Visibility.Collapsed;
        SecondScreenEntry.Visibility = Detailed ? Visibility.Collapsed : Visibility.Visible;
        ClickThrough.IsChecked = settings.OverlayClickThrough;
        ClickThroughHint.Visibility = Detailed || settings.OverlayClickThrough ? Visibility.Visible : Visibility.Collapsed;
        ClickThroughHint.Text = HotkeyText.Sentence(settings, HotkeyAction.ClickThrough,
            "When on, clicks go through to the window below. Press %@ to turn it off.");
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
