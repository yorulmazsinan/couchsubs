// SPDX-License-Identifier: AGPL-3.0-only
using System.Windows;
using System.Windows.Controls;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

public partial class XboxLoginStep : UserControl
{
    private bool working;
    public XboxLoginStep() => InitializeComponent();
    private AppController Controller => (AppController)DataContext;

    private async void OnSignIn(object sender, RoutedEventArgs e)
    {
        if (working) return;
        working = true;
        var text = Localizer.Current;
        SignIn.IsEnabled = false;
        Error.Text = "";
        Status.Text = text["Opening the Microsoft sign-in page…"];
        try
        {
            var challenge = await Controller.BeginXboxLoginAsync();
            Code.Text = challenge.Code;
            Instruction.Text = text["Enter this code on the Microsoft page in your browser:"];
            Status.Text = text["Waiting for the sign-in to finish…"];
            await Controller.CompleteXboxLoginAsync();
            Status.Text = text["Microsoft sign-in is done. You can continue."];
        }
        catch (Exception error)
        {
            Error.Text = error.Message;
            Status.Text = text["Sign-in did not finish. You can try again."];
        }
        finally
        {
            working = false;
            SignIn.IsEnabled = true;
        }
    }
}
