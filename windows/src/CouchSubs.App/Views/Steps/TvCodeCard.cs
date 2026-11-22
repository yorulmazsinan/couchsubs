// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using CouchSubs.App.Controls;
using CouchSubs.App.Theme;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

/// <summary>
/// Kurulumun TV adımında eşleşme kodu iki ekranda (tuval 05): "TV'DE GÖRÜNEN KOD", kodun her hanesi ayrı kutuda, "Bu Kod
/// TV'nizde de Görünüyor mu?" ve amber "TV'de Bu Kodu Görüyorum"; onaylanınca yeşil "Eşleşti". Kod yokken "TV'de
/// CouchSubs'ı açın" ipucu. Bu kart görünürken kabuğun açılır onay kartı açılmaz (aynı soru iki kez sorulmaz).
/// </summary>
public sealed class TvCodeCard : Border
{
    /// <summary>Kart ekrandayken açılır onay kartı gösterilmez.</summary>
    public static bool Showing { get; private set; }

    private readonly StackPanel digits = new() { Orientation = Orientation.Horizontal, Margin = Sp.T("0", "m", "0", "0") };
    private readonly TextBlock waiting = new();
    private readonly StackPanel question = new() { Margin = Sp.T("0", "l", "0", "0") };
    private readonly Button confirm = new();
    private readonly Button paired = new();
    private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(1) };
    private string? shownId;

    public TvCodeCard()
    {
        var l = Localizer.Current;
        SetResourceReference(StyleProperty, "CardBorder");
        Margin = Sp.T("0", "0", "0", "l");
        var stack = new StackPanel();
        var label = new TextBlock { Text = l["CODE SHOWN ON THE TV"] };
        label.SetResourceReference(StyleProperty, "SectionLabel");
        stack.Children.Add(label);
        waiting.Text = l["Open CouchSubs on the TV. When it shows a code, it appears here too."];
        waiting.SetResourceReference(StyleProperty, "HintText");
        waiting.Margin = Sp.T("0", "m", "0", "0");
        stack.Children.Add(waiting);
        stack.Children.Add(digits);
        var title = new TextBlock { Text = l["Do You See This Code on Your TV Too?"] };
        title.SetResourceReference(StyleProperty, "HeadlineText");
        var hint = new TextBlock { Text = l["If you see the same code, you're on the right TV. Approving completes the pairing."], Margin = Sp.T("0", "xxs", "0", "m") };
        hint.SetResourceReference(StyleProperty, "HintText");
        confirm.Content = l["I See This Code on the TV"];
        confirm.SetResourceReference(StyleProperty, "PrimaryButton");
        confirm.Click += (_, _) => Approve();
        paired.Content = l["Paired"];
        paired.SetResourceReference(StyleProperty, "SuccessButton");
        paired.Visibility = Visibility.Collapsed;
        question.Children.Add(title);
        question.Children.Add(hint);
        question.Children.Add(confirm);
        question.Children.Add(paired);
        stack.Children.Add(question);
        Child = stack;
        poll.Tick += (_, _) => Refresh();
        Loaded += (_, _) => { Showing = true; poll.Start(); Refresh(); };
        Unloaded += (_, _) => { Showing = false; poll.Stop(); };
    }

    private AppController? Controller => DataContext as AppController;

    private void Refresh()
    {
        var ticket = Controller?.PendingTvPairing;
        if (ticket is null)
        {
            if (paired.Visibility == Visibility.Visible) return;
            shownId = null;
            digits.Children.Clear();
            waiting.Visibility = Visibility.Visible;
            question.Visibility = Visibility.Collapsed;
            return;
        }
        if (ticket.Id == shownId) return;
        shownId = ticket.Id;
        waiting.Visibility = Visibility.Collapsed;
        question.Visibility = Visibility.Visible;
        confirm.Visibility = Visibility.Visible;
        paired.Visibility = Visibility.Collapsed;
        digits.Children.Clear();
        foreach (var digit in ticket.Code.Where(char.IsLetterOrDigit))
        {
            var box = new Border { Width = 64, Height = 80, CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(1), Margin = Sp.T("0", "0", "s", "0") };
            box.SetResourceReference(Border.BackgroundProperty, "surface2Brush");
            box.SetResourceReference(Border.BorderBrushProperty, "borderBrush");
            var text = new TextBlock { Text = digit.ToString(), FontSize = 36, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            text.SetResourceReference(StyleProperty, "MonoValue");
            text.FontSize = 36;
            box.Child = text;
            digits.Children.Add(box);
            Motion.EnterFrom(box, 8, Motion.Short, TimeSpan.FromMilliseconds(60 * digits.Children.Count));
        }
    }

    private void Approve()
    {
        if (Controller is not { } controller || controller.PendingTvPairing is not { } ticket) return;
        var resolved = controller.ResolveTvPairing(ticket.Id, true);
        if (!resolved)
        {
            waiting.Text = Localizer.Current["The pairing request expired. Try again on the TV."];
            shownId = null;
            Refresh();
            return;
        }
        confirm.Visibility = Visibility.Collapsed;
        paired.Visibility = Visibility.Visible;
        Motion.Settle(paired);
    }
}
