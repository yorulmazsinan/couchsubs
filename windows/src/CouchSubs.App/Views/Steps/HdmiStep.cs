// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using CouchSubs.App.Controls;
using CouchSubs.App.Theme;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views.Steps;

/// <summary>
/// Kurulum › TV Girişi (tuval 06; Mac ile aynı): solda HDMI 1–4 kartları, "Bilmiyorum, Sırayla Dene" ve "Nereden
/// Anlarım?"; sağda TV önizlemesi ("HDMI 2 · Deneniyor"), "TV'de Oyun Görüntüsünü Görüyor musunuz?", Evet (onaylanınca yeşil
/// "Onaylandı") ve "Hayır, Sonraki Giriş". Seçilen giriş TV'ye <c>style.hdmiInput</c> ile gider; onaylanınca kaydedilir.
/// </summary>
public sealed class HdmiStep : UserControl
{
    private readonly RadioButton[] inputs = new RadioButton[4];
    private readonly TextBlock badge = new() { Foreground = Brushes.White, FontSize = 11, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border sample = new();
    private readonly Button yes = new();
    private readonly TextBlock note = new();
    private int trying;
    private bool confirmed;

    public HdmiStep()
    {
        var l = Localizer.Current;
        var layout = new StepLayout
        {
            Title = l["Which TV Input Is the PS5 Plugged Into?"],
            Message = l["CouchSubs opens this input on the TV to show subtitles over the game. If the wrong input is chosen, the screen stays black."],
        };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());

        // Sol: girişler
        var left = new StackPanel();
        var tiles = new UniformGrid { Rows = 1 };
        for (var i = 0; i < 4; i++)
        {
            var number = i + 1;
            var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var small = new TextBlock { Text = "HDMI", FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
            small.SetResourceReference(TextBlock.ForegroundProperty, "textSecondaryBrush");
            var big = new TextBlock { Text = number.ToString(), HorizontalAlignment = HorizontalAlignment.Center };
            big.SetResourceReference(StyleProperty, "MonoValue");
            big.FontSize = 28;
            stack.Children.Add(small);
            stack.Children.Add(big);
            var tile = new OptionCard { Content = stack, GroupName = "hdmi", MinHeight = 104, Margin = new Thickness(i == 0 ? 0 : Sp.V("titleBody"), 0, i == 3 ? 0 : Sp.V("titleBody"), 0), Tag = number };
            tile.Checked += (_, _) => Try(number);
            inputs[i] = tile;
            tiles.Children.Add(tile);
        }
        left.Children.Add(tiles);
        var auto = new OptionCard { Content = l["I Don't Know, Try Them in Turn"], Description = l["We open the inputs one by one; you confirm when you see the picture."],
            GroupName = "hdmiAuto", Margin = Sp.T("0", "m", "0", "0") };
        auto.Checked += (_, _) => { inputs[0].IsChecked = true; Try(1); auto.IsChecked = false; };
        left.Children.Add(auto);
        var how = new Border { Padding = Sp.T("m"), CornerRadius = new CornerRadius(16), Margin = Sp.T("0", "m", "0", "0") };
        how.SetResourceReference(Border.BackgroundProperty, "surface2Brush");
        var howStack = new StackPanel();
        var howTitle = new TextBlock { Text = l["How Do I Tell?"] };
        howTitle.SetResourceReference(StyleProperty, "RowTitle");
        var howText = new TextBlock { Text = l["The number is printed on the back of the TV next to the port the PS5 cable is plugged into. If the PS5 is plugged into a sound system (soundbar, amplifier), choose the input the sound system is connected to."], Margin = Sp.T("0", "xxs", "0", "0") };
        howText.SetResourceReference(StyleProperty, "HintText");
        howStack.Children.Add(howTitle);
        howStack.Children.Add(howText);
        how.Child = howStack;
        left.Children.Add(how);
        grid.Children.Add(left);

        // Sağ: TV önizlemesi ve onay
        var right = new StackPanel();
        var chip = new Border { Child = badge, VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left, Margin = Sp.T("s") };
        chip.SetResourceReference(StyleProperty, "SceneChip");
        var line = new TextBlock { FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White };
        var name = new System.Windows.Documents.Run("Jason: ");
        name.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "accentBrush");
        line.Inlines.Add(name);
        line.Inlines.Add(new System.Windows.Documents.Run(l.Language == "tr" ? "Tamam. Gidelim." : "Okay. Let's go."));
        sample.Child = line;
        sample.Background = new SolidColorBrush(Color.FromArgb(0xD9, 0x10, 0x10, 0x14));
        sample.CornerRadius = new CornerRadius(12);
        sample.Padding = Sp.T("s", "xs", "s", "xs");
        sample.HorizontalAlignment = HorizontalAlignment.Center;
        sample.VerticalAlignment = VerticalAlignment.Bottom;
        sample.Margin = Sp.T("m");
        var screen = new Grid { Children = { sample, chip } };
        var frame = new Border { Child = screen };
        frame.SetResourceReference(StyleProperty, "DeviceFrame");
        right.Children.Add(new Views.AspectBox { Child = frame });
        var question = new TextBlock { Text = l["Do You See the Game Picture on the TV?"], Margin = Sp.T("0", "m", "0", "0") };
        question.SetResourceReference(StyleProperty, "HeadlineText");
        right.Children.Add(question);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = Sp.T("0", "m", "0", "0") };
        yes.Content = l["Yes"];
        yes.SetResourceReference(StyleProperty, "PrimaryButton");
        yes.Click += (_, _) => Confirm();
        var next = new Button { Content = l["No, Next Input"], Margin = Sp.T("s", "0", "0", "0") };
        next.Click += (_, _) => Next();
        buttons.Children.Add(yes);
        buttons.Children.Add(next);
        right.Children.Add(buttons);
        var remember = new TextBlock { Text = l["The choice is remembered. You can change it later in Settings › Consoles."], Margin = Sp.T("0", "m", "0", "0") };
        remember.SetResourceReference(StyleProperty, "HintText");
        right.Children.Add(remember);
        note.SetResourceReference(StyleProperty, "HintText");
        note.Margin = Sp.T("0", "xs", "0", "0");
        right.Children.Add(note);
        var card = new Border { Child = right };
        card.SetResourceReference(StyleProperty, "CardBorder");
        Grid.SetColumn(card, 2);
        grid.Children.Add(card);

        layout.Content = grid;
        Content = layout;
        Loaded += (_, _) =>
        {
            if (Controller?.Settings.Style.HdmiInput is { } saved)
            {
                trying = saved;
                inputs[saved - 1].IsChecked = true;
                confirmed = true;
            }
            Show();
        };
    }

    private AppController? Controller => DataContext as AppController;

    /// <summary>Girişi TV'de açar (kaydetmeden); görüntü onaylanınca kaydedilir.</summary>
    private void Try(int number)
    {
        if (trying == number && confirmed) return;
        trying = number;
        confirmed = false;
        Controller?.TryHdmiInput(number, confirmed: false);
        Show();
    }

    private void Next()
    {
        var number = trying >= 4 || trying < 1 ? 1 : trying + 1;
        inputs[number - 1].IsChecked = true;
        Try(number);
    }

    private void Confirm()
    {
        if (trying < 1 || Controller is not { } controller) return;
        confirmed = true;
        controller.TryHdmiInput(trying, confirmed: true);
        Show();
        Motion.Settle(yes);
    }

    private void Show()
    {
        var l = Localizer.Current;
        badge.Text = trying < 1 ? "HDMI" : confirmed ? $"HDMI {trying}" : l.Format("HDMI %lld · Trying", trying);
        sample.Visibility = trying < 1 ? Visibility.Collapsed : Visibility.Visible;
        yes.IsEnabled = trying >= 1;
        yes.Content = l[confirmed ? "Confirmed" : "Yes"];
        yes.SetResourceReference(StyleProperty, confirmed ? "SuccessButton" : "PrimaryButton");
        note.Text = confirmed ? l.Format("HDMI %lld saved.", trying) : l["Confirm the picture to continue."];
    }
}
