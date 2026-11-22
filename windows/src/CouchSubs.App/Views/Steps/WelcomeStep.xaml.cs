// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows.Controls;
using System.Windows;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

public partial class WelcomeStep : UserControl
{
    /// <summary>"Oyun Penceresi" seçili mi (Mac WelcomeChoice.window): Devam'a basılınca uygulanır.</summary>
    public static bool WindowChosen { get; private set; }

    public WelcomeStep()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Ps5.IsChecked = !WindowChosen && !Controller.IsXbox;
            Xbox.IsChecked = !WindowChosen && Controller.IsXbox;
            GameWindow.IsChecked = WindowChosen;
            Ps5.IsEnabled = Xbox.IsEnabled = !Controller.ConsoleKindLocked;
            ShowRequirements();
        };
    }

    private AppController Controller => (AppController)DataContext;

    private void OnSelected(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        WindowChosen = false;
        Controller.SelectConsoleKind(Xbox.IsChecked == true ? GameConsoleKind.Xbox : GameConsoleKind.PlayStation);
        ShowRequirements();
    }

    private void OnWindow(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        WindowChosen = true;
        ShowRequirements();
    }

    /// <summary>"Oyun Penceresi" seçiliyse görüntü seçilen pencereden okunur, kurulum biter (Mac WizardFooter.continueStep).</summary>
    public static bool ApplyWindowChoice(AppController controller)
    {
        if (!WindowChosen) return false;
        WindowChosen = false;
        if (controller.IsXbox) controller.UseXboxWindow();
        else controller.UseCaptureWindow();
        return true;
    }

    private void ShowRequirements()
    {
        var text = Localizer.Current;
        if (WindowChosen)
        {
            Requirements.Text = text["CouchSubs can read only the OBS projector or game window you select in Settings › Picture source. No second PSN account or additional capture app is needed."];
            return;
        }
        if (Controller.IsXbox)
        {
            Requirements.Text = text["You will need: your home Xbox on the same network, a Microsoft account, and a TV or computer to show the subtitles. Remote play must be turned on on the Xbox."];
            return;
        }
        Requirements.Text = text["You will need:"] + "\n• " + text["A PS5 on the same network as this computer"]
            + "\n• " + text["An LG TV with the CouchSubs TV app"] + "\n• " + text["A free second PlayStation Network account"];
    }
}
