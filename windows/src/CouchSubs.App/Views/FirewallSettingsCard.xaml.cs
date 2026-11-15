// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>
/// Ayarlar: Windows Güvenlik Duvarı izni her zaman buradan verilebilir (ana ekrandaki kart yalnız bağlantı sorunluyken çıkar).
/// Ağ "Ortak" ise TV'nin bilgisayarı bulması için ağı "Özel" yapmak önerilir.
/// </summary>
public partial class FirewallSettingsCard : UserControl
{
    private AppController? controller;

    public FirewallSettingsCard() => InitializeComponent();

    internal void Attach(AppController controller)
    {
        this.controller = controller;
        _ = RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        if (controller is null) return;
        var state = await controller.GetFirewallStateAsync();
        if (state is not { } known) return;
        var text = Localizer.Current;
        Visibility = Visibility.Visible;
        Status.Text = known.HasRule
            ? text["Windows Firewall already allows CouchSubs."]
            : text["Windows Firewall does not allow CouchSubs yet. The TV and the PS5 cannot reach this computer until you allow it."];
        Allow.Visibility = known.HasRule ? Visibility.Collapsed : Visibility.Visible;
        PublicHint.Visibility = known.PublicNetwork ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnAllow(object sender, RoutedEventArgs e)
    {
        if (controller is null) return;
        Allow.IsEnabled = false;
        try { await controller.AllowThroughFirewallAsync(); }
        finally { Allow.IsEnabled = true; }
        await RefreshAsync();
    }
}
