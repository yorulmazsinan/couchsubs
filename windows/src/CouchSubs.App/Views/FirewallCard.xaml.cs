// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>
/// Windows Güvenlik Duvarı izni: PS5 eşleştirmesi başarısız olunca ya da çeviri sürerken PS5 ve TV bağlanamayınca,
/// kural eksikse görünür. Ana ekranda ve PS5 adımında aynı kart kullanılır.
/// </summary>
public partial class FirewallCard : UserControl
{
    private AppController? controller;

    public FirewallCard()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            controller = DataContext as AppController;
            if (controller is null) return;
            controller.PropertyChanged += OnChanged;
            Show();
        };
        Unloaded += (_, _) =>
        {
            if (controller is not null) controller.PropertyChanged -= OnChanged;
        };
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppController.FirewallPrompt)) Dispatcher.Invoke(Show);
    }

    private void Show()
    {
        if (controller is null) return;
        var text = Localizer.Current;
        var prompt = controller.FirewallPrompt;
        // Çeviri sürmüyorsa kart PS5 eşleştirmesi içindir.
        var running = controller.IsRunning;
        Visibility = prompt == FirewallPrompt.None ? Visibility.Collapsed : Visibility.Visible;
        Allow.Visibility = prompt is FirewallPrompt.Offer or FirewallPrompt.Failed or FirewallPrompt.Working ? Visibility.Visible : Visibility.Collapsed;
        Allow.IsEnabled = prompt != FirewallPrompt.Working;
        Headline.Text = prompt == FirewallPrompt.Allowed
            ? text["Local-network permission is ready for Private networks."]
            : text["Windows Firewall may be blocking the connection."];
        Hint.Text = prompt switch
        {
            FirewallPrompt.PublicNetwork => text["Permission applies only to Private networks. If this is your trusted home network, set it to Private in Windows Settings."],
            FirewallPrompt.Working => text["Waiting for Windows…"],
            FirewallPrompt.Failed => text["Local-network permission could not be verified. Approve the Windows prompt, or review existing blocking rules in Windows Firewall."],
            FirewallPrompt.Allowed when running => text["Reconnecting…"],
            FirewallPrompt.Allowed => text["Open Pair Device again on the PS5 and enter the new code."],
            _ when running && controller.IsXbox => text["CouchSubs needs Windows Firewall permission for incoming connections from the TV."],
            _ when running => text["CouchSubs needs incoming connections from the PS5 and the TV. Windows asks for permission once."],
            _ => text["Allow CouchSubs, then open Pair Device again on the PS5 and enter the new code."],
        };
    }

    private async void OnAllow(object sender, RoutedEventArgs e)
    {
        if (controller is not null) await controller.AllowThroughFirewallAsync();
    }
}
