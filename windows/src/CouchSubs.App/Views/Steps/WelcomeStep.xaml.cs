// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows.Controls;
using System.Windows;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

public partial class WelcomeStep : UserControl
{
    public WelcomeStep()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Ps5.IsChecked = !Controller.IsXbox;
            Xbox.IsChecked = Controller.IsXbox;
            Ps5.IsEnabled = Xbox.IsEnabled = !Controller.ConsoleKindLocked;
            ShowRequirements();
        };
    }

    private AppController Controller => (AppController)DataContext;

    private void OnSelected(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        Controller.SelectConsoleKind(Xbox.IsChecked == true ? GameConsoleKind.Xbox : GameConsoleKind.PlayStation);
        ShowRequirements();
    }

    private void ShowRequirements()
    {
        if (Controller.IsXbox)
        {
            Layout.Message = Localizer.Current["Xbox support is in beta. CouchSubs reads the subtitles in the game picture and shows the translation on your TV or computer. You keep playing with your own controller."];
            Requirements.Text = Localizer.Current["You will need: your home Xbox on the same network, a Microsoft account, and a TV or computer to show the subtitles. Remote play must be turned on on the Xbox."];
            return;
        }
        // PS5 seçiliyken metinler önceki karşılama ekranıyla aynı: ortak katalogdan, her dilde.
        var text = Localizer.Current;
        Layout.Message = text["CouchSubs reads the English subtitles of your PS5 games and shows a Turkish translation on your TV, on top of the game. You keep playing on the TV with your own controller."];
        Requirements.Text = text["You will need:"] + "\n• " + text["A PS5 on the same network as this computer"]
            + "\n• " + text["An LG TV with the CouchSubs TV app"] + "\n• " + text["A free second PlayStation Network account"];
    }
}
