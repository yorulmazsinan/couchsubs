// SPDX-License-Identifier: AGPL-3.0-only
using System.Windows;
using CouchSubs.App.Theme;
using System.Windows.Controls;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

public partial class XboxConsoleStep : UserControl
{
    public XboxConsoleStep()
    {
        InitializeComponent();
        Loaded += async (_, _) => await SearchAsync();
    }

    private AppController Controller => (AppController)DataContext;
    private async void OnRefresh(object sender, RoutedEventArgs e) => await SearchAsync();

    private async Task SearchAsync()
    {
        Refresh.IsEnabled = false;
        Error.Text = "";
        var text = Localizer.Current;
        Status.Text = text["Searching for Xbox consoles…"];
        Consoles.Children.Clear();
        try
        {
            var found = await Controller.DiscoverXboxConsolesAsync();
            Status.Text = found.Count == 0 ? text["No home console found for this Microsoft account."] : text["Choose the console to use:"];
            foreach (var console in found)
            {
                var option = new RadioButton
                {
                    Content = $"{console.Name} ({console.Model})" + (console.StreamingEnabled ? "" : " — " + text["Remote play is off"]),
                    GroupName = "xbox", IsEnabled = console.StreamingEnabled,
                    IsChecked = Controller.SelectedXboxConsole?.Id == console.Id,
                    Margin = Sp.T("0", "0", "0", "s"),
                };
                option.Checked += (_, _) => Controller.SelectXboxConsole(console);
                Consoles.Children.Add(option);
            }
        }
        catch (Exception error) { Error.Text = error.Message; Status.Text = text["Couldn't get the consoles."]; }
        finally { Refresh.IsEnabled = true; }
    }

    private void OnShowLog(object sender, RoutedEventArgs e) => LogFile.Show();
}
