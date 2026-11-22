// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CouchSubs.App.Controls;
using CouchSubs.App.Theme;
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
        ShowIntro();
    }

    /// <summary>Açılış bu oturumda gösterildi (yalnız ilk kurulumun karşılama adımında, bir kez).</summary>
    private static bool introShown;

    /// <summary>İlk kurulumun karşılama adımında açılış sihirbazın üstünde oynar; "Hadi Başlayalım" ya da "Atla" ile söner.</summary>
    private void ShowIntro()
    {
        if (introShown || controller.Step != OnboardingStep.Welcome || controller.DemoMode) return;
        introShown = true;
        var wizard = (UIElement)Content;
        Content = null;
        var stage = new Grid();
        stage.Children.Add(wizard);
        IntroView? intro = null;
        intro = new IntroView(() =>
        {
            var fade = Theme.Motion.To(0, Theme.Motion.Page, exit: true);
            fade.Completed += (_, _) => stage.Children.Remove(intro);
            intro!.BeginAnimation(OpacityProperty, fade);
        }, controller.Settings.StartupSound);
        stage.Children.Add(intro);
        Content = stage;
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppController.Step)) ShowStep();
        else if (e.PropertyName == nameof(AppController.ConsoleKind))
        {
            ShowSteps();
        }
        else if (e.PropertyName == nameof(AppController.UsesFreeGemini)) ShowContinue();
    }

    /// <summary>
    /// "Daha iyi çeviri" isteğe bağlıdır: anahtar yokken alttaki düğme ikincil "Şimdilik geç" (birincil düğme adımdaki
    /// "Ücretsiz anahtar al"), anahtar kaydedilince birincil "Devam".
    /// </summary>
    private void ShowContinue()
    {
        var skip = controller.Step == OnboardingStep.BetterTranslation && !controller.UsesFreeGemini;
        ContinueButton.Content = Localizer.Current[skip ? "Skip for Now" : "Continue"];
        ContinueButton.Style = (Style)FindResource(skip ? "SecondaryButton" : "WidePrimaryButton");
        // Anahtar alanında Enter adımı geçmesin.
        ContinueButton.IsDefault = !skip;
    }

    private void ShowStep()
    {
        StepHost.Content = controller.Step switch
        {
            OnboardingStep.Welcome => new WelcomeStep(),
            OnboardingStep.SecondAccount => new SecondAccountStep(),
            OnboardingStep.PsnLogin => controller.IsXbox ? new XboxLoginStep() : new PsnLoginStep(),
            OnboardingStep.Console => controller.IsXbox ? new XboxConsoleStep() : new ConsoleStep(),
            OnboardingStep.Tv => new TvStep(),
            OnboardingStep.Hdmi => new HdmiStep(),
            OnboardingStep.Translation => new TranslationStep(),
            OnboardingStep.Test => new TestStep(),
            _ => new BetterTranslationStep(),
        };
        ShowSteps();
        // Adım 8 px aşağıdan kayarak gelir (hareket azaltılmışsa yalnız solma).
        if (StepHost.Content is FrameworkElement page) Theme.Motion.EnterFrom(page, 12, Theme.Motion.Page);
        BackButton.Visibility = controller.Step == OnboardingStep.Welcome ? Visibility.Collapsed : Visibility.Visible;
        ContinueButton.Visibility = controller.Step == OnboardingStep.Test ? Visibility.Hidden : Visibility.Visible;
        ShowContinue();
    }

    /// <summary>
    /// Adım etiketi ("ADIM 2 / 8") ve üstteki ilerleme noktaları: şimdiki adım 24 genişlikte amber hap, geçilenler amber,
    /// sıradakiler çerçeve renginde nokta.
    /// </summary>
    private void ShowSteps()
    {
        var text = Localizer.Current;
        // Dört nokta (Mac ile aynı): 1 Konsol, 2 Hesap + PS5, 3 TV + Giriş, 4 Çeviri + Deneme.
        var group = controller.Step switch
        {
            OnboardingStep.Welcome => 1,
            OnboardingStep.SecondAccount or OnboardingStep.PsnLogin or OnboardingStep.Console => 2,
            OnboardingStep.Tv or OnboardingStep.Hdmi => 3,
            _ => 4,
        };
        Counter.Text = text.Format("STEP %lld / %lld", group, 4);
        Dots.Children.Clear();
        for (var number = 1; number <= 4; number++)
        {
            var dot = new Border
            {
                Width = number == group ? 24 : 8, Height = 8, CornerRadius = new CornerRadius(4),
                Margin = new Thickness(number == 1 ? 0 : Sp.V("xs"), 0, 0, 0),
            };
            dot.SetResourceReference(Border.BackgroundProperty, number <= group ? "accentBrush" : "borderBrush");
            Dots.Children.Add(dot);
        }
        System.Windows.Automation.AutomationProperties.SetName(Dots, Counter.Text);
    }

    /// <summary>"Sonra Ayarlarım": kurulum yarıda bırakılır, ana ekran "Kurulum Eksik" durumuyla açılır.</summary>
    private void OnLater(object sender, RoutedEventArgs e) => ShellWindow.DeferSetup();

    private void OnBack(object sender, RoutedEventArgs e) => controller.Back();

    private void OnReset(object sender, RoutedEventArgs e)
    {
        controller.ResetSetup();
        ShowStep();
    }

    private void OnContinue(object sender, RoutedEventArgs e) => controller.Advance();
}
