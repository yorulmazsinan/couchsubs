// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CouchSubs.App.Controls;
using CouchSubs.App.Views.Steps;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>Kurulum sihirbazı: üstte adım sayacı ve ilerleme, ortada adım, altta Geri / Devam.</summary>
public partial class OnboardingView : UserControl
{
    private readonly AppController controller;

    public OnboardingView(AppController controller)
    {
        this.controller = controller;
        DataContext = controller;
        InitializeComponent();
        controller.PropertyChanged += OnChanged;
        Unloaded += (_, _) => controller.PropertyChanged -= OnChanged;
        ShowStep();
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppController.Step)) ShowStep();
        else if (e.PropertyName == nameof(AppController.UsesFreeGemini)) ShowContinue();
    }

    /// <summary>
    /// "Daha iyi çeviri" isteğe bağlıdır: anahtar yokken alttaki düğme ikincil "Şimdilik geç" (birincil düğme adımdaki
    /// "Ücretsiz anahtar al"), anahtar kaydedilince birincil "Devam".
    /// </summary>
    private void ShowContinue()
    {
        var skip = controller.Step == OnboardingStep.BetterTranslation && !controller.UsesFreeGemini;
        ContinueButton.Content = Localizer.Current[skip ? "Skip for now" : "Continue"];
        ContinueButton.Style = (Style)FindResource(skip ? "SecondaryButton" : "PrimaryButton");
        // Anahtar alanında Enter adımı geçmesin.
        ContinueButton.IsDefault = !skip;
    }

    private void ShowStep()
    {
        StepHost.Content = controller.Step switch
        {
            OnboardingStep.Welcome => new WelcomeStep(),
            OnboardingStep.SecondAccount => new SecondAccountStep(),
            OnboardingStep.PsnLogin => new PsnLoginStep(),
            OnboardingStep.Console => new ConsoleStep(),
            OnboardingStep.Tv => new TvStep(),
            OnboardingStep.Translation => new TranslationStep(),
            OnboardingStep.Test => new TestStep(),
            _ => new BetterTranslationStep(),
        };
        Counter.Text = Localizer.Current.Format("Step %lld of %lld", controller.StepNumber, AppController.StepCount);
        Progress.Value = (double)controller.StepNumber / AppController.StepCount;
        ShowSteps();
        BackButton.Visibility = controller.Step == OnboardingStep.Welcome ? Visibility.Hidden : Visibility.Visible;
        ContinueButton.Visibility = controller.Step == OnboardingStep.Test ? Visibility.Hidden : Visibility.Visible;
        ShowContinue();
    }

    /// <summary>Adımların adları: her adımın kendi başlığı.</summary>
    private static string StepTitle(OnboardingStep step) => step switch
    {
        OnboardingStep.Welcome => "Welcome to CouchSubs",
        OnboardingStep.SecondAccount => "A second PSN account",
        OnboardingStep.PsnLogin => "Sign in with the second account",
        OnboardingStep.Console => "Connect your PS5",
        OnboardingStep.Tv => "Connect your TV",
        OnboardingStep.Translation => "Download the translation model",
        OnboardingStep.Test => "Let's test it",
        _ => "Better translation (free)",
    };

    /// <summary>Soldaki adım listesi: tamamlananlar yeşil ✓, şimdiki sarı daire ve nötr zemin, sıradakiler numaralı ve soluk.</summary>
    private void ShowSteps()
    {
        StepList.Children.Clear();
        var current = (int)controller.Step;
        foreach (var step in Enum.GetValues<OnboardingStep>().Where(s => s != OnboardingStep.Done))
        {
            var index = (int)step;
            var (done, now) = (index < current, index == current);
            var mark = new TextBlock
            {
                Text = done ? Glyphs.Check : (index + 1).ToString(), FontWeight = FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap,
            };
            if (done) mark.Style = (Style)FindResource("GlyphText");
            mark.SetResourceReference(TextBlock.FontSizeProperty, "captionFontSize");
            mark.SetResourceReference(TextBlock.ForegroundProperty, done || now ? "onAccentBrush" : "textSecondaryBrush");
            var dot = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Child = mark, VerticalAlignment = VerticalAlignment.Center };
            dot.SetResourceReference(Border.BackgroundProperty, done ? "successBrush" : now ? "accentBrush" : "borderBrush");
            var label = new TextBlock { Text = Localizer.Current[StepTitle(step)], Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            label.SetResourceReference(TextBlock.ForegroundProperty, done || now ? "textPrimaryBrush" : "textSecondaryBrush");
            if (now) label.FontWeight = FontWeights.SemiBold;
            var content = new DockPanel();
            DockPanel.SetDock(dot, Dock.Left);
            content.Children.Add(dot);
            content.Children.Add(label);
            var row = new Border
            {
                Child = content, Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 0, 0, 4), MinHeight = 44,
            };
            row.SetResourceReference(Border.CornerRadiusProperty, "radius.control");
            if (now) row.SetResourceReference(Border.BackgroundProperty, "surface2Brush");
            System.Windows.Automation.AutomationProperties.SetName(row, $"{index + 1}. {label.Text}");
            StepList.Children.Add(row);
        }
    }

    private void OnBack(object sender, RoutedEventArgs e) => controller.Back();

    private void OnContinue(object sender, RoutedEventArgs e) => controller.Advance();
}
